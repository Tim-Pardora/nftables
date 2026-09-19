#!/bin/sh
# Alpine Linux / OpenRC. Manage IPv4 TCP/UDP port forwarding.
set -eu
umask 077

STATE=/etc/nft-port-forward
DB=$STATE/rules.tsv
INSTALLED=/usr/local/sbin/nft-port-forward
TABLE=codex_port_forward
TAG=codex-port-forward-managed

die() { printf '\n错误：%s\n' "$*" >&2; exit 1; }

valid_port() {
    printf '%s\n' "$1" | awk '
      /^[1-9][0-9]*$/ && length($0) <= 5 && $0 <= 65535 { ok=1 }
      END { exit !ok }'
}

valid_ip() {
    printf '%s\n' "$1" | awk -F. '
      NF != 4 { exit 1 }
      { for (i=1;i<=4;i++)
          if ($i !~ /^[0-9]+$/ || length($i)>3 || $i>255 ||
              (length($i)>1 && substr($i,1,1)=="0")) exit 1
      }'
}

validate_db() {
    awk -F '\t' '
      NF != 4 { exit 1 }
      $1 !~ /^[1-9][0-9]*$/ || length($1)>5 || $1>65535 { exit 1 }
      $3 !~ /^[1-9][0-9]*$/ || length($3)>5 || $3>65535 { exit 1 }
      $4 != "tcp" && $4 != "udp" && $4 != "both" { exit 1 }
      {
        if (split($2,a,".") != 4) exit 1
        for (i=1;i<=4;i++)
          if (a[i] !~ /^[0-9]+$/ || length(a[i])>3 || a[i]>255 ||
              (length(a[i])>1 && substr(a[i],1,1)=="0")) exit 1
        if ($4=="tcp" || $4=="both") { if (seen[$1,"tcp"]++) exit 1 }
        if ($4=="udp" || $4=="both") { if (seen[$1,"udp"]++) exit 1 }
      }' "$1"
}

# Generate one atomic nft transaction. Remove only our own rules/table.
apply_db() (
    set -eu
    candidate=$1
    validate_db "$candidate" || die '规则文件无效或存在端口冲突。'
    task_tmp=$(mktemp -d) || exit 1
    trap 'rm -rf "$task_tmp"' EXIT
    nft -j list ruleset > "$task_tmp/current.json" || exit 1
    jq -r --arg tag "$TAG" '
      .nftables[] | .rule? // empty | select(.comment == $tag) |
      "delete rule \(.family) \(.table|tojson) \(.chain|tojson) handle \(.handle)"
    ' "$task_tmp/current.json" > "$task_tmp/change.nft" || exit 1
    if nft list table ip "$TABLE" >/dev/null 2>&1; then
        printf 'delete table ip %s\n' "$TABLE" >> "$task_tmp/change.nft" || exit 1
    fi

    if [ -s "$candidate" ]; then
        {
            printf 'table ip %s {\n' "$TABLE"
            printf ' chain prerouting {\n'
            printf '  type nat hook prerouting priority dstnat; policy accept;\n'
            while read -r listen target dest proto; do
                protocols=$proto
                [ "$proto" != both ] || protocols='tcp udp'
                for protocol in $protocols; do
                    printf '  fib daddr type local %s dport %s counter dnat to %s:%s\n' \
                        "$protocol" "$listen" "$target" "$dest"
                done
            done < "$candidate"
            printf ' }\n chain postrouting {\n'
            printf '  type nat hook postrouting priority srcnat; policy accept;\n'
            while read -r listen target dest proto; do
                protocols=$proto
                [ "$proto" != both ] || protocols='tcp udp'
                for protocol in $protocols; do
                    printf '  ct status dnat ct original proto-dst %s ip daddr %s %s dport %s counter masquerade\n' \
                        "$listen" "$target" "$protocol" "$dest"
                done
            done < "$candidate"
            printf ' }\n}\n'
        } >> "$task_tmp/change.nft" || exit 1

        # An accept in a separate base chain cannot override an existing drop.
        # Insert narrowly scoped exceptions into each existing forward chain.
        jq -r --arg tag "$TAG" --rawfile db "$candidate" '
          ($db | split("\n") | map(select(length>0) | split("\t"))) as $rows |
          .nftables[] | .chain? // empty |
          select(.hook=="forward" and (.family=="ip" or .family=="inet")) |
          . as $c | $rows[] as $r |
          (if $r[3]=="both" then ["tcp","udp"] else [$r[3]] end)[] as $p |
          "insert rule \($c.family) \($c.table|tojson) \($c.name|tojson) ct status dnat ct original proto-dst \($r[0]) ip daddr \($r[1]) \($p) dport \($r[2]) counter accept comment \($tag|tojson)",
          "insert rule \($c.family) \($c.table|tojson) \($c.name|tojson) ct status dnat ct state established ct original proto-dst \($r[0]) ip saddr \($r[1]) \($p) sport \($r[2]) counter accept comment \($tag|tojson)"
        ' "$task_tmp/current.json" >> "$task_tmp/change.nft" || exit 1
    fi

    if [ -s "$task_tmp/change.nft" ]; then
        nft -c -f "$task_tmp/change.nft" || exit 1
        # Enable routing before installing forwarding rules.
        if [ -s "$candidate" ]; then
            sysctl -w net.ipv4.ip_forward=1 >/dev/null || exit 1
        fi
        nft -f "$task_tmp/change.nft" || exit 1
    fi
)

show_rules() {
    printf '\n编号  监听端口  目标 IPv4         目标端口  协议\n'
    if [ ! -s "$DB" ]; then
        printf '（尚未添加规则）\n'
    else
        awk -F '\t' '{ printf "%-5d %-9s %-17s %-9s %s\n",NR,$1,$2,$3,$4 }' "$DB"
    fi
}

commit_rules() {
    # Apply first; preserve the saved database if nft rejects the change.
    if (set -e; apply_db "$STATE/pending.tsv"); then
        cp -p "$DB" "$STATE/rules.previous.tsv"
        mv "$STATE/pending.tsv" "$DB"
        printf '\n规则已生效并保存，重启后会自动恢复。\n'
    else
        rm -f "$STATE/pending.tsv"
        printf '\n应用失败，已保留原有规则文件。请检查上方错误。\n' >&2
    fi
}

add_rule() {
    printf '\n本机监听端口（例如 60001）：'
    read -r listen || exit 0
    valid_port "$listen" || { printf '端口必须为 1–65535，不带前导零。\n'; return; }
    printf '目标 IPv4（例如 104.234.167.176）：'
    read -r target || exit 0
    valid_ip "$target" || { printf 'IPv4 地址格式错误。\n'; return; }
    printf '目标端口（例如 33004）：'
    read -r dest || exit 0
    valid_port "$dest" || { printf '端口必须为 1–65535，不带前导零。\n'; return; }
    printf '协议：1 TCP，2 UDP，3 两者 [默认 3]：'
    read -r choice || exit 0
    case "$choice" in
        1|tcp|TCP) proto=tcp ;;
        2|udp|UDP) proto=udp ;;
        ''|3|both) proto=both ;;
        *) printf '协议选项无效。\n'; return ;;
    esac
    if ! awk -F '\t' -v p="$listen" -v proto="$proto" '
        $1==p && ($4==proto || $4=="both" || proto=="both") { clash=1 }
        END { exit clash }' "$DB"; then
        printf '该监听端口的协议已被占用，请先删除对应规则。\n'
        return
    fi
    cp "$DB" "$STATE/pending.tsv"
    printf '%s\t%s\t%s\t%s\n' "$listen" "$target" "$dest" "$proto" >> "$STATE/pending.tsv"
    commit_rules
}

delete_rule() {
    show_rules
    [ -s "$DB" ] || return 0
    printf '\n要删除的编号（直接回车取消）：'
    read -r number || exit 0
    [ -n "$number" ] || return 0
    count=$(awk 'END {print NR}' "$DB")
    case "$number" in *[!0-9]*|0*|'') printf '编号无效。\n'; return ;; esac
    if [ "${#number}" -gt 6 ] || [ "$number" -gt "$count" ]; then
        printf '编号不存在。\n'; return
    fi
    awk -v n="$number" 'NR!=n' "$DB" > "$STATE/pending.tsv"
    commit_rules
}

install_service() {
    mkdir -p /usr/local/sbin
    if [ "$0" != "$INSTALLED" ]; then
        [ -f "$0" ] || die '请先将脚本保存为文件，再用 sh 文件名运行。'
        cp "$0" "$INSTALLED"
    fi
    chmod 700 "$INSTALLED"
    cat > /etc/init.d/nft-port-forward <<'SERVICE'
#!/sbin/openrc-run
description="Restore managed IPv4 port forwarding"
depend() {
    need net
    after firewall nftables
}
start() {
    ebegin "Applying port forwarding"
    /usr/local/sbin/nft-port-forward --apply
    eend $?
}
stop() {
    ebegin "Removing managed port forwarding"
    /usr/local/sbin/nft-port-forward --stop
    eend $?
}
SERVICE
    chmod 755 /etc/init.d/nft-port-forward
    rc-update add nft-port-forward default
}

[ "$(id -u)" -eq 0 ] || die '请以 root 身份运行。'
[ -f /etc/alpine-release ] || die '本脚本适用于 Alpine Linux。'
mode=${1:-menu}
case "$mode" in menu|--apply|--stop) ;; *) die '用法：nft-port-forward [--apply|--stop]' ;; esac
if ! command -v nft >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
    [ "$mode" = menu ] || die '缺少 nftables 或 jq，请重新运行交互安装。'
    apk add --no-cache nftables jq
fi
mkdir -p "$STATE"
chmod 700 "$STATE"
[ -f "$DB" ] || : > "$DB"

# Prevent concurrent edits or overlap with OpenRC startup/shutdown.
LOCK=/run/nft-port-forward.lock
if ! mkdir "$LOCK" 2>/dev/null; then
    die '另一个脚本实例正在运行；如曾被强制终止，请确认无实例后删除 /run/nft-port-forward.lock。'
fi
cleanup() { rm -f "$STATE/pending.tsv"; rmdir "$LOCK" 2>/dev/null || :; }
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

case "$mode" in
    --apply) apply_db "$DB"; exit 0 ;;
    --stop) : > "$STATE/pending.tsv"; apply_db "$STATE/pending.tsv"; exit 0 ;;
esac

install_service
printf '\nIPv4 端口转发管理\n'
printf '适用于外部设备连接本机；目标服务器看到的是本机出口 IP。\n'
printf '脚本不会修改 /etc/nftables.nft，规则单独保存并开机恢复。\n'
while :; do
    printf '\n1) 添加规则\n2) 查看规则\n3) 删除规则\n4) 重新应用所有规则\n0) 退出\n请选择：'
    read -r action || exit 0
    case "$action" in
        1) add_rule ;;
        2) show_rules ;;
        3) delete_rule ;;
        4) cp "$DB" "$STATE/pending.tsv"; commit_rules ;;
        0) exit 0 ;;
        *) printf '请选择 0–4。\n' ;;
    esac
done
