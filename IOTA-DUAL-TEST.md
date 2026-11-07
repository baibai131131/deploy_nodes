# IOTA 双协议 VPS 测试版：HTTPS 订阅与温和维护

文件：`deploy_iota_dual_test.sh`，版本 1.2.0。

独立运行 Hysteria2 2.13.0（UDP 443）和 VLESS + REALITY / Xray 26.10.31（TCP 443）。TCP 和 UDP 可以使用相同端口号。VLESS 故意不启用 Vision，避开当前版本报告的 Vision + 并发 XUDP 问题；它仍由 REALITY 加密。两种协议均支持转发客户端 UDP。

## 一键安装

适用全新 Ubuntu 22.04/24.04 VPS（amd64/arm64），或已安装本文件旧版的 VPS。用 root 登录后执行：

```bash
curl -fLsS --retry 3 "https://raw.githubusercontent.com/baibai131131/deploy_nodes/main/deploy_iota_dual_test.sh?$(date +%s)" -o /root/install-iota-dual.sh && bash /root/install-iota-dual.sh
```

脚本必须先下载为普通文件再执行；它会保留一份本地副本供离线查看状态和卸载。检测到其他旧 HY2、Xray、面板配置或端口占用时停止，绝不自动停止或覆盖其他服务。

已经安装本文件 1.0/1.1 版时，升级订阅和维护模块，不强制重启代理、不改变节点密码。旧 HTTP 下载服务会停止；每次生成新链接会撤销旧链接，但不改变节点凭据。

VPS 厂商安全组需同时放行 **TCP 443、UDP 443、TCP 18080（HTTPS 订阅）、TCP 80（证书验证/续期）**。脚本只在现有 UFW 已启用时添加对应允许规则，不关闭防火墙、不修改 SSH。NAT VPS 还需服务商端口映射。

**TCP 80 必须空闲且可从公网访问。** 它只在 Certbot 验证时临时监听，不提供订阅或节点密码。如果已有网站占用，不会强制停止网站。厂商端口限制、CA 限额、共享 IP 或外部网络问题也可能使证书验证失败；此时不会退回明文 HTTP，也不会停止已经运行的两个代理，可以改用 SSH/SFTP 导入 YAML。

可选环境变量：`HY2_PORT`、`VLESS_PORT`、`VPS_IP`（公网 IPv4）、`REALITY_SNI`、`SUB_PORT`（默认 18080）、`SUB_TTL_MINUTES`（默认 30，允许 5–60）。例如使用备用端口：

```bash
HY2_PORT=8443 VLESS_PORT=8443 bash /root/install-iota-dual.sh
```

## 在 Mac 上使用

安装结束会打印 `COPY THIS CLASH SUBSCRIPTION URL`，下方是一条可以复制的链接，形式为：

```text
https://你的VPS-IP:18080/随机64位令牌/clash.yaml
```

在 Clash Verge Rev 的“配置/订阅”页粘贴链接并导入。订阅已包含两个节点和手动选择组。复制真实输出，不要复制上面的示例占位文字。

**这是受信任 HTTPS 临时导入链接，不是长期公开订阅。** 默认 30 分钟后失效，下载服务退出；HY2/TCP 服务和已导入的节点不受影响。需要再次下载时执行 `iota-dual subscribe`，只重启下载服务，不重启训练代理，也不轮换节点凭据。

现在 Let's Encrypt 已支持公网 IP 证书，不必购买域名。脚本使用独立环境中的官方 Certbot 5.9.0，申请约 6 天有效的 `shortlived` IP 证书，并每 12 小时检查续期；会注册 ACME 账户并接受 Let's Encrypt 订户协议。IP 和证书会公开，节点密码不会提交给 CA。Certbot 不修改系统已有的证书安装。

HTTPS 至少使用 TLS 1.2；安装自检必须通过系统 CA 信任、IP 匹配和下载内容比对，不使用 `curl -k`，也不要求关闭 Clash 证书校验。证书续期只会在下载服务活跃时重启该下载服务以加载新证书，不影响训练代理。

仍可通过 SSH/SFTP 下载 `/root/IOTA-DUAL.yaml` 并导入本地配置。

也可以只将 `proxies` 中的两个节点合并到自己的配置，保留当前已验证的 DNS/TUN。

- `IOTA-HY2-UDP`：HY2，无 `up/down` 带宽声明，服务器忽略客户端带宽提示，保守 BBR。
- `IOTA-REALITY-TCP`：TCP 备用，启用 UDP 转发 / XUDP，不启用 Vision 和额外 smux。
- `IOTA-SELECT`：手动选择节点，不做自动测速切换或负载均衡。

保留自己已验证可用的 DNS、TUN 和路由配置。脚本不操作任何 Mac，也不配置系统 DNS/TUN。只有系统 HTTP 代理不能保证 IOTA P2P/UDP 进入代理；应检查现有 TUN/UDP 路由是否实际承载客户端流量。

HY2 使用自签证书配合 SHA256 叶证书指纹固定校验，YAML 中不是关闭证书校验。请使用较新的 Mihomo 内核。分享 URI 的证书 pin 支持因客户端而异，Clash 优先使用 YAML。

**链接仍是下载凭据，持有者可取得节点密码，不要公开分享、提交到 GitHub 或发完整截图。** 下载服务只接受精确令牌路径、不列目录、不提供任意文件、没有请求路径访问日志；使用与代理不同的低权限账户，不能读取代理私钥目录。升级 HTTPS 不会撤销过去已经泄露的节点密码；如果旧链接曾公开或怀疑被截获，需要另行轮换节点凭据。

## 缓存和日志维护

HY2 断网不能仅凭现象归因于缓存。Linux 会自动回收文件缓存，应该看 `available` 内存，而不是看到 cache 多就强清。磁盘满、OOM、UDP 路径受限、连接表满等要分别检查。

本版维护范围：

- 安装结束清理自己的下载临时目录。
- Certbot 安装使用 `pip --no-cache-dir`；其日志最多保留 7 份备份。
- 本脚本日志使用独立 `iota-dual` 命名空间，目标约 100 MB、保留最多 7 天；journald 配额不是严格的字节硬上限。
- 每日轮转和清理该命名空间的旧归档，不清理系统其他服务的日志。
- 旧版升级不强制重启代理，日志隔离在代理下次计划启动时生效；旧默认命名空间日志不会被本脚本清除。
- 不定时强清内存缓存、不清空 conntrack、不清空防火墙、不重启网络、不每日重启 VPS/代理，也不删除用户备份。

以上旨在控制磁盘占用，不能修复运营商丢包、UDP 封锁或 IOTA 调度问题。

## 管理

```bash
iota-dual status
iota-dual show
iota-dual subscribe
iota-dual diagnose
iota-dual maintain
journalctl --namespace='*' -u iota-dual-hy2 -f
journalctl --namespace='*' -u iota-dual-reality -f
iota-dual uninstall
```

`diagnose` 只读查看内存、磁盘和 inode、socket、连接表计数/上限、累计 UDP 错误、近期 OOM/连接表满事件及维护任务。累计 UDP 错误不是丢包率，要对比两次采样；单次快照不能证明原因。

`maintain` 只清理本脚本命名空间的过期/超额归档日志，删除的旧日志不能恢复，不影响活跃训练连接。

卸载需输入 `REMOVE`，先将配置、凭据、证书和二进制备份至 root 专用备份目录，再移除本脚本管理的服务、定时器、规则和账户。备份包含敏感私钥，不删除 IOTA 客户端或钱包，不全局清理系统日志。

## 如何判断是否有效

先用一两台 Mac 测试，不要迁移整批设备。观察 24–48 小时：实际有效训练、P2P 连接、activation 超时、权重同步和断线重排次数。切换节点会使原连接失效，可能重新排队。

TCP 可在 VPS 的 UDP 路径出问题时提供另一种传输方式，但不能保证比 HY2 的 IOTA P2P 更好。服务器进程正常、网页能打开、HTTP 测速快，都不能单独证明 IOTA P2P 稳定。若 VPS/IP 被封、服务器停机或共同上游故障，两种协议可能一起失败。

## 实现与验证范围

- 直接下载官方 release 二进制并核对固定 SHA256，不执行第三方安装器。
- 独立非 root 服务、开机自启、异常退出后重启；没有每日重启或 conntrack 强制清理。
- 只适量提高 UDP 收发缓冲最大值，不修改宿主 DNS、IPv6 或全局 TCP 拥塞控制。
- 在生成配置后执行 Xray 自带配置检查，启动时检查两种本地监听。
- 通过回环 HTTPS 验证受信任证书与 IP 匹配，实际下载并比对配置；只验证本机服务，不代表厂商安全组或中国到 VPS 的连通性。
- 已通过 Bash 语法和 22 项测试，包括可信测试证书、拒绝不受信任证书/IP 不匹配/明文 HTTP、错误路径、并发、过期退出及维护范围。尚未在用户 VPS 完成真实 CA 签发或中国到 VPS 的长期实测，不作 P2P、训练或收益保证。

离线测试（开发环境安装 PyYAML 后）：

```bash
python3 test_iota_dual.py
```

参考：

- https://letsencrypt.org/2026/03/11/shorter-certs-certbot
- https://eff-certbot.readthedocs.io/en/stable/using.html
- https://docs.kernel.org/admin-guide/sysctl/vm.html#drop-caches
- https://github.com/HyNetworks/hysteria/releases/tag/app/v2.13.0
- https://github.com/XTLS/Xray-core/releases/tag/v26.10.31
- https://github.com/XTLS/Xray-core/issues/7336
- https://v2.hysteria.network/docs/advanced/Full-Server-Config/
- https://wiki.metacubex.one/en/config/proxies/vless/
- https://wiki.metacubex.one/en/config/proxies/hysteria2/
