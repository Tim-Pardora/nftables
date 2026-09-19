# Alpine nftables 端口转发管理

在 Alpine Linux 上交互式管理 IPv4 端口转发。支持 TCP、UDP，以及同一端口同时转发两种协议。

## 功能

- 自由输入本机监听端口、目标 IPv4 地址、目标端口和协议。
- 添加、查看、删除多条规则，检查输入格式和脚本内的监听端口冲突。
- 自动安装 `nftables` 和 `jq`，开启 IPv4 转发。
- 单独保存转发规则，通过 OpenRC 在开机时恢复。
- 保留已有防火墙配置，向现有 IPv4 转发过滤链添加对应放行规则。
- 应用前检查 nftables 配置；使用一次事务更新规则。

## 运行环境

Alpine Linux、OpenRC、root 权限，以及支持 nftables、连接跟踪和 NAT 的内核。首次运行需要访问 Alpine 软件仓库。

本脚本用于外部设备连接 Alpine 本机地址的端口，不处理本机发起的连接，也不支持 IPv6、域名或端口范围。容器环境需要宿主机授予管理网络规则的权限。

## 安装与使用

将 `nft-port-forward.sh` 下载或上传到 Alpine，以 root 执行：

```sh
sh nft-port-forward.sh
```

首次运行会安装依赖和管理命令，并注册开机恢复服务。之后可以直接运行：

```sh
nft-port-forward
```

菜单选项：

```text
1) 添加规则
2) 查看规则
3) 删除规则
4) 重新应用所有规则
0) 退出
```

例如，输入监听端口 `60001`、目标 IPv4 `192.0.2.10`、目标端口 `33004`，再选择 TCP、UDP 或两者。`192.0.2.10` 是文档示例地址，请替换为实际目标。

如果 GitHub 仓库为私有，下载文件需要登录或使用已有的 GitHub 授权；匿名下载链接无法直接读取私有脚本。

## 保存位置

| 路径 | 用途 |
| --- | --- |
| `/usr/local/sbin/nft-port-forward` | 管理脚本 |
| `/etc/nft-port-forward/rules.tsv` | 当前保存的规则 |
| `/etc/nft-port-forward/rules.previous.tsv` | 上一次修改前的规则备份 |
| `/etc/init.d/nft-port-forward` | OpenRC 开机恢复服务 |

脚本不会修改 `/etc/nftables.nft`，不会执行全局 `flush ruleset`。它使用专属表 `ip codex_port_forward` 和规则注释 `codex-port-forward-managed` 标识自己管理的内容，请不要将这些名称用于其他规则。

## 网络行为与已有规则

- 监听匹配所有本机 IPv4 地址上的指定端口；未限制来源 IP。
- 使用 DNAT 和 masquerade。目标服务器看到的是 Alpine 的出口 IP。
- 云安全组、上游防火墙和目标服务器防火墙仍需允许相关流量。
- 脚本会在已有的 `ip` / `inet` forward 链前添加对应放行规则；其他位置的丢弃规则仍可能影响连接。
- 其他工具或旧版本脚本创建的规则不会自动导入或删除。同一监听端口若已有其他 DNAT 规则，应先解决冲突。
- 如果其他防火墙服务重新加载并清空规则，退出管理菜单后执行 `nft-port-forward --apply` 恢复本脚本规则。
- 删除规则后，已经建立的连接可能继续存在，直到连接跟踪记录过期；请用新连接验证修改。

## 常用维护命令

退出交互菜单后执行：

```sh
# 重新应用保存的规则
nft-port-forward --apply

# 查看本脚本的 NAT 表（没有规则时表可能不存在）
nft list table ip codex_port_forward

# 停用开机恢复，并移除当前由脚本管理的规则
rc-update del nft-port-forward default
nft-port-forward --stop
```

`--stop` 保留已保存的规则文件，也不会关闭全局 IPv4 转发，以免影响其他网络服务。重新启用：

```sh
rc-update add nft-port-forward default
nft-port-forward --apply
```

## 验证状态

已检查 POSIX shell 语法和输入校验的边界情况。尚未在 Alpine 实机验证内核规则加载、实际网络转发和 OpenRC 重启恢复。
