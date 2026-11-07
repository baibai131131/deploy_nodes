# IOTA 双协议 VPS 测试版

文件：`deploy_iota_dual_test.sh`，版本 1.0.0。

独立运行 Hysteria2 2.13.0（UDP 443）和 VLESS + REALITY / Xray 26.10.31（TCP 443）。TCP 和 UDP 可以使用相同端口号。VLESS 故意不启用 Vision，避开当前版本报告的 Vision + 并发 XUDP 问题；它仍由 REALITY 加密。两种协议均支持转发客户端 UDP。

## 一键安装

只用于全新 Ubuntu 22.04/24.04 VPS（amd64/arm64），用 root 登录后执行：

```bash
curl -fLsS --retry 3 https://raw.githubusercontent.com/baibai131131/deploy_nodes/main/deploy_iota_dual_test.sh -o /root/install-iota-dual.sh && bash /root/install-iota-dual.sh
```

脚本必须先下载为普通文件再执行；它会保留一份本地副本供离线查看状态和卸载。检测到旧 HY2、Xray、面板配置或端口占用时停止，绝不自动停止或覆盖其他服务。重复运行已完成的本脚本只显示原配置，不轮换密码。

VPS 厂商安全组需同时放行 **TCP 443 和 UDP 443**。脚本只在现有 UFW 已启用时添加对应允许规则，不关闭防火墙、不修改 SSH。NAT VPS 还需服务商端口映射。

可选环境变量：`HY2_PORT`、`VLESS_PORT`、`VPS_IP`（公网 IPv4）、`REALITY_SNI`。例如使用备用端口：

```bash
HY2_PORT=8443 VLESS_PORT=8443 bash /root/install-iota-dual.sh
```

## 在 Mac 上使用

安装结束会打印两个节点。通过 SSH/SFTP 下载 VPS 上的 `/root/IOTA-DUAL.yaml`，在 Clash Verge Rev 中导入为本地配置；也可只将 `proxies` 中两个节点合并到自己的配置。

- `IOTA-HY2-UDP`：HY2，无 `up/down` 带宽声明，服务器忽略客户端带宽提示，保守 BBR。
- `IOTA-REALITY-TCP`：TCP 备用，启用 UDP 转发 / XUDP，不启用 Vision 和额外 smux。
- `IOTA-SELECT`：手动选择节点，不做自动测速切换或负载均衡。

保留自己已验证可用的 DNS、TUN 和路由配置。脚本不操作任何 Mac，也不配置系统 DNS/TUN。只有系统 HTTP 代理不能保证 IOTA P2P/UDP 进入代理；应检查现有 TUN/UDP 路由是否实际承载客户端流量。

HY2 使用自签证书配合 SHA256 叶证书指纹固定校验，YAML 中不是关闭证书校验。请使用较新的 Mihomo 内核。分享 URI 的证书 pin 支持因客户端而异，Clash 优先使用 YAML。

**配置文件包含私密节点密码，不要提交到公共 GitHub、公开订阅或发截图。** 本脚本不开放任何公共订阅下载端口。

## 管理

```bash
iota-dual status
iota-dual show
journalctl -u iota-dual-hy2 -f
journalctl -u iota-dual-reality -f
iota-dual uninstall
```

卸载需输入 `REMOVE` 确认，只移除本脚本管理的文件和服务，先将配置、凭据和二进制备份至 `/root/iota-dual-backup.*`。该备份包含私密凭据。安装中断时先看 `status`，也可以用本命令卸载残留后重装。不会删除 IOTA 客户端或钱包。

## 如何判断是否有效

先用一两台 Mac 测试，不要迁移整批设备。观察 24–48 小时：实际有效训练、P2P 连接、activation 超时、权重同步和断线重排次数。切换节点会使原连接失效，可能重新排队。

TCP 可在 VPS 的 UDP 路径出问题时提供另一种传输方式，但不能保证比 HY2 的 IOTA P2P 更好。服务器进程正常、网页能打开、HTTP 测速快，都不能单独证明 IOTA P2P 稳定。若 VPS/IP 被封、服务器停机或共同上游故障，两种协议可能一起失败。

## 实现与验证范围

- 直接下载官方 release 二进制并核对固定 SHA256，不执行第三方安装器。
- 独立非 root 服务、开机自启、异常退出后重启；没有每日重启或 conntrack 强制清理。
- 只适量提高 UDP 收发缓冲最大值，不修改宿主 DNS、IPv6 或全局 TCP 拥塞控制。
- 在生成配置后执行 Xray 自带配置检查，启动时检查两种本地监听。
- 已做 Bash 语法与离线配置/防覆盖测试；不代表已在用户 VPS 或中国到 VPS 的实际链路上通过长时间实测。

离线测试（开发环境安装 PyYAML 后）：

```bash
python3 test_iota_dual.py
```

参考：

- https://github.com/HyNetworks/hysteria/releases/tag/app/v2.13.0
- https://github.com/XTLS/Xray-core/releases/tag/v26.10.31
- https://github.com/XTLS/Xray-core/issues/7336
- https://v2.hysteria.network/docs/advanced/Full-Server-Config/
- https://wiki.metacubex.one/en/config/proxies/vless/
- https://wiki.metacubex.one/en/config/proxies/hysteria2/
