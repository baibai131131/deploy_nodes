# VPS 双入口脚本：TCP REALITY + Hysteria2

这是一份重新设计的、可审计的 VPS 部署脚本。它不复制 `argosbx` 的代码，只参考了其“多入口共存”的思路。

## 一键安装

先用 SSH 登录 VPS 并切换到 `root`，然后执行：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/baibai131131/deploy_nodes/main/vps-dual.sh)
```

脚本会同时部署 TCP REALITY 与 Hysteria2，并在完成后输出三条 Clash/Mihomo 订阅链接。安装前请确认 VPS 厂商安全组允许脚本使用的 TCP、UDP 和订阅端口。

## 结论先说

- **默认主用：VLESS + TCP + REALITY + Vision**。TCP 在机场 Wi‑Fi、公司网、移动网、校园网等环境里的可达性通常更好，也较少被直接丢弃。
- **备用/高丢包线路：Hysteria2**。HY2 基于 QUIC/UDP，在长距离、抖动、丢包明显的链路上常有更好的吞吐和恢复表现；但部分运营商、路由器、公共 Wi‑Fi 会限速或阻断 UDP。
- 所以“哪个更稳定”没有脱离网络环境的唯一答案。实用方案是两个入口同时部署，客户端优先 TCP，HY2 做手动或自动备用。

## 与参考脚本相比的取舍

本脚本使用两个职责清晰的官方核心：Xray 只承载 TCP REALITY，官方 Hysteria 核心承载 HY2。HY2 使用与你提供的参考脚本相同的 Salamander 混淆和默认 BBR 拥塞控制；不默认安装 WARP、Cloudflared、系统 BBR、端口跳跃或十余种协议。

功能包括：

- XTLS 官方安装器获取 Xray-core，并从 Hysteria 官方下载地址获取 HY2 核心；
- 安装前配置校验，失败不覆盖现有配置；
- UUID、密码、REALITY 密钥持久化，重复运行不会无故换节点；
- systemd 自动启动与有限度的服务加固；
- 自动放行活动的 UFW/firewalld 规则；
- `show`、`status`、`diagnose`、`restart`、`update`、`uninstall`；
- HY2 默认使用包含 VPS IP SAN 的自签证书，并在链接中固定证书指纹；也可传入域名正式证书。
- 生成三份 Clash/Mihomo 订阅：仅 TCP、仅 HY2、自动测速并故障切换。
- 为兼容 Mihomo REALITY，Xray 默认固定为 `v26.6.27`，不会盲目升级到 Mihomo 文档明确警告的不兼容版本线。

## 使用

上传脚本到一台 Debian、Ubuntu、RHEL 系 VPS 后：

```bash
chmod +x vps-dual.sh
sudo ./vps-dual.sh install
```

指定端口与公网地址：

```bash
sudo REALITY_PORT=443 HY2_PORT=8443 SERVER_ADDR=203.0.113.10 ./vps-dual.sh install
```

安装完成会输出三条订阅 URL：

- `clash-tcp.yaml`：只包含 TCP REALITY；
- `clash-hy2.yaml`：只包含 HY2；
- `clash-all.yaml`：包含 `AUTO` 测速组和 `FAILOVER` 故障切换组。

无正式域名证书时，订阅使用随机长路径的 HTTP，仅作为兼容方案；URL 本身包含访问令牌，且返回内容包含节点密码，请勿公开。传入正式证书后会自动改用 HTTPS。默认订阅端口为 `18080`，可设置 `SUB_PORT` 修改，或用 `SUB_ENABLED=0` 关闭网络订阅、只保留本地 YAML 文件。

使用已有的正式证书（HY2 客户端链接将关闭 `insecure`）：

```bash
sudo HY2_SNI=hy2.example.com \
  HY2_CERT_FILE=/etc/letsencrypt/live/hy2.example.com/fullchain.pem \
  HY2_KEY_FILE=/etc/letsencrypt/live/hy2.example.com/privkey.pem \
  ./vps-dual.sh install
```

脚本会链接到你提供的证书路径，而不是复制一份；例如 Certbot 更新 `live/` 下的证书后，Hysteria 会在新的 TLS 握手中读取新证书。

常用维护命令：

```bash
sudo ./vps-dual.sh show
sudo ./vps-dual.sh diagnose
sudo ./vps-dual.sh update
sudo ./vps-dual.sh restart
sudo ./vps-dual.sh uninstall
```

安装后还需要在 VPS 厂商的安全组中放行：

- `TCP/443`（或你设置的 `REALITY_PORT`）
- `UDP/8443`（或你设置的 `HY2_PORT`）
- `TCP/18080`（或你设置的 `SUB_PORT`，仅在启用网络订阅时）

## 参数

| 变量 | 默认值 | 说明 |
|---|---:|---|
| `REALITY_PORT` | `443` | TCP REALITY 入口端口 |
| `HY2_PORT` | `8443` | HY2 UDP 入口端口 |
| `REALITY_SNI` | `www.microsoft.com` | VPS 本机可直连的 TLS 1.3 伪装目标 |
| `HY2_SNI` | `SERVER_ADDR` | HY2 证书 SNI；有正式证书时填写你自己的域名 |
| `SERVER_ADDR` | 自动检测 | 客户端连接 VPS 使用的公网 IP 或域名 |
| `HY2_CERT_FILE` | 空 | 可选的正式证书链文件 |
| `HY2_KEY_FILE` | 空 | 可选的正式证书私钥文件 |
| `SUB_PORT` | `18080` | Clash 订阅服务 TCP 端口 |
| `SUB_ENABLED` | `1` | `0` 表示不对外提供订阅 URL |

## 稳定性建议

1. 先用默认 TCP REALITY 连续跑几天，观察晚高峰丢包、延迟和断流。
2. 同时测试 HY2。若 UDP 可达且晚高峰吞吐明显更好，把它设为流媒体/大文件入口；否则只保留备用。
3. 不要一上来加入 WARP、CDN、端口跳跃和多层转发。每多一层就多一个故障点。
4. REALITY 目标应从 VPS 本机可直连、支持 TLS 1.3、与服务器网络位置合理；脚本会做一次基本连通性检查。
5. HY2 的“快”不等于全场景“稳”。UDP 被 QoS 时，继续调拥塞参数通常不如直接切回 TCP。

## 域名怎么选

- **TCP REALITY 不需要你的域名或证书。** `REALITY_SNI` 是伪装目标，应选择 VPS 本机可稳定访问、支持 TLS 1.3 的站点；这不是把你的域名解析到 VPS。
- **HY2 有自己的域名更规范，但不是速度条件。** 域名直接解析到 VPS（不要开启 CDN 代理），配合受信任证书，客户端兼容性和后续换 IP 更好。
- **没有域名也能稳定使用。** 默认方案直接连接 VPS IP，使用自签证书和 `pinSHA256` 固定证书身份；少一个 DNS 依赖，速度与域名方案基本相同。
- 域名方案的主要优势是证书信任和换 IP，不会凭空提高线路速度。线路质量、UDP QoS、VPS 带宽和客户端的拥塞参数才是主要因素。

你提供的参考脚本同样是“IP + 自签证书 + 指纹固定”，域名只作为可选的证书 CN/SAN。它的多端口是多个独立 Hysteria 实例，并不会自动提高单连接速度；本脚本先保留单端口，减少资源占用和防火墙暴露面。

参考脚本中没有纳入本版本的部分：每天 03:00 清缓存并强制重启、systemd 失败后再用 `nohup` 启动第二份进程、从非官方镜像回退下载二进制，以及通过未加密 HTTP 暴露包含密码的 Clash 订阅。这些行为对速度帮助有限，却会增加固定断线、重复进程、供应链和凭据泄漏风险。

## 安全与恢复

- `/etc/vps-dual/` 包含节点密钥，权限为 root-only，请不要公开。
- `uninstall` 只删除本脚本的服务、配置和对应防火墙规则，不删除可能被其他服务复用的 Xray 二进制。
- 如果安装失败，运行 `sudo ./vps-dual.sh diagnose` 查看配置校验、监听端口和最近日志。
- `diagnose` 还会输出网卡丢包、TCP 重传/超时、UDP 缓冲区错误、MTU、路由及短时外网探测结果。
