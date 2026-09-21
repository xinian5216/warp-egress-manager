# WARP Egress Manager（安全、可选出口的 Local Proxy 管理器）

为 IPv4-only、IPv6-only、双栈 VPS 安装和管理 Cloudflare 官方 WARP 客户端，并只在本机
`127.0.0.1:40000` 提供 SOCKS5 出站。它可以直接给 `curl`、支持 `ALL_PROXY` 的程序或
ProxyChains 使用；3x-ui/Xray 只是可选集成，不是运行前提。

核心原则：**不让 WARP 接管系统 IPv4/IPv6 默认路由**。SSH、管理面板和未显式使用本地
SOCKS5 的流量继续走 VPS 原生网络。

## 为什么选择 Local Proxy

Cloudflare 官方把 Local Proxy 定义为“只有显式配置代理的应用才通过 WARP”。本项目在
连接前强制执行 `warp-cli mode proxy`，并在验收时检查：

- WARP trace 必须为 `warp=on` 或 `warp=plus`；
- SOCKS5 必须只监听 loopback；
- IPv4、IPv6 默认路由均不能指向 WARP；
- Google 必须经该 SOCKS5 返回 HTTP 204；
- 尝试从 YouTube 页面提取地区码，若为 `CN` 明确报警。

> Cloudflare 的 `loc` 是 Cloudflare 看到的出口地区，Google/YouTube 地区码是另一套判断。
> 页面结构可能变化，因此地区码检查属于启发式检测，不能提取时脚本会明确写“无法断言”，
> 不会伪报成功。

Local Proxy 使用 **MASQUE**。Cloudflare Linux WARP 自 2025.8.779.0 起，Proxy 模式只支持
MASQUE，不再支持 WireGuard。旧安装里的 `AUTO` / `WireGuard` 会在读取配置时自动迁移。

## 支持范围

- Debian 12/13
- Ubuntu 22.04/24.04/26.04
- RHEL/CentOS Stream/Rocky/AlmaLinux 9/10（官方 RPM 在 9+ 可能需要 EPEL）
- Fedora 43/44
- systemd
- Cloudflare 官方仓库实际提供软件包的 CPU 架构

网络可以是 IPv4-only、IPv6-only 或双栈。安装时会分别探测原生公网 IPv4/IPv6，并让用户
选择 WARP 出口能力：

| 模式 | 生成的 Xray 出站 | 典型用途 |
|---|---|---|
| `ipv4` | 验证 WARP IPv4；`warpm curl` 默认 `-4` | IPv6-only 补 IPv4；替换“送中”IPv4 |
| `ipv6` | 验证 WARP IPv6；`warpm curl` 默认 `-6` | IPv4-only 补 IPv6 |
| `dual` | `warp-ipv4`、`warp-ipv6`、`warp-auto` | 按规则自由选择两种 WARP 地址族 |
| `auto` | 单栈补另一族；双栈等同 `dual` | 不确定时使用 |

这些是本地代理能力与 **可选的 Xray 出站**，不是给 VPS 网卡新增地址。普通 SOCKS5 应用
通常自行选择目标地址族；严格限定地址族需要应用自身的 `-4/-6`，或使用 Xray 的
`targetStrategy`。脚本不修改默认路由，也不会把整机流量切到 WARP。

## 快速安装

1. 获取 `warp-egress-manager`
2. 安装 Cloudflare 官方 WARP
3. 启用 Local Proxy
4. 验证
5. 可选 Xray / ProxyChains 集成
6. 可选 GitHub Proxy（仅当 GitHub 不可达时）

仓库已经公开。`main` 是开发基线，随时可下载最新代码：

```bash
curl -fsSL \
  https://raw.githubusercontent.com/xinian5216/warp-egress-manager/main/warp-3xui.sh \
  -o /tmp/warp-3xui.sh
sudo bash /tmp/warp-3xui.sh
```

正式环境建议从 [Releases](https://github.com/xinian5216/warp-egress-manager/releases)
页面对应的版本 tag 安装（把 `<tag>` 换成例如 `v1.4.0`）：

```bash
curl -fsSL \
  https://raw.githubusercontent.com/xinian5216/warp-egress-manager/<tag>/warp-3xui.sh \
  -o /tmp/warp-3xui.sh
sudo bash /tmp/warp-3xui.sh
```

> `main` 是开发基线；正式 Release 才是生产更新通道。安装后的 `warpm self-update`
> 也只会更新到最新正式 Release。

不要把 GitHub Token 写进命令历史。非交互安装示例：

```bash
sudo bash warp-3xui.sh install \
  --port 40000 \
  --protocol masque \
  --egress auto \
  --repo xinian5216/warp-egress-manager \
  --non-interactive
```

`--protocol` 现只接受 MASQUE（`auto` / `wireguard` 会静默迁移）。`--egress` 决定 Xray
把目标解析为 IPv4、IPv6 还是两者。两组选项互不替代。

安装 Cloudflare WARP 客户端时，**唯一在线来源**是官方软件源
`pkg.cloudflareclient.com`。官方源失败时脚本会明确退出，而不会改走第三方镜像。

## IPv6-only / GitHub 不可达 VPS

GitHub 不可达时，可以通过 [vps-gateway-manager](https://github.com/xinian5216/vps-gateway-manager)
或其他标准 GitHub HTTPS 代理访问 GitHub。Gateway **只代理 GitHub 下载**，不能也不应
把 Cloudflare 官方软件源或普通网站送进 GitHub-only 代理。

```bash
export WARPM_GITHUB_PROXY='https://gh.example.com:8443'
curl --proxy "${WARPM_GITHUB_PROXY}" -fsSL \
  https://raw.githubusercontent.com/xinian5216/warp-egress-manager/main/warp-3xui.sh \
  -o /tmp/warp-3xui.sh
sudo -E bash /tmp/warp-3xui.sh
```

本机已安装 vps-gateway-manager 客户端时：

```bash
export WARPM_GITHUB_PROXY='http://127.0.0.1:3129'
```

或写入配置（由脚本保存，不写系统代理）：

```bash
sudo warpm self-update --github-proxy 'https://gh.example.com:8443'
```

`warpm self-update` 默认查询最新**正式 GitHub Release**，并从对应不可变 tag 下载主脚本；
不需要 `gh` 或 PAT。`main` 是开发基线，不是生产更新通道；只有显式 `warpm self-update --main`
才会读取 `main`，且仅用于测试。

这个代理**只负责 GitHub**。以下请求仍然直连：

- `pkg.cloudflareclient.com`
- Cloudflare WARP 网络请求
- Google / YouTube 验收
- Cloudflare trace

脚本不会设置 `HTTP_PROXY` / `HTTPS_PROXY`，也不会写入 `/etc/environment`。

WARP 客户端本身仍需要能访问 `pkg.cloudflareclient.com`。若官方软件源不可达：

```text
Cloudflare 官方软件源当前不可达。
可检查网络、DNS、IPv6/NAT64，或者手工提供官方离线安装包。
```

## 不安装 3x-ui 也能直接使用

安装后先查看本地代理信息：

```bash
warpm proxy-info
sudo warpm status
```

### 用 WARP 执行 curl

```bash
warpm curl https://www.cloudflare.com/cdn-cgi/trace
warpm curl -4 https://www.cloudflare.com/cdn-cgi/trace
warpm curl -6 https://www.cloudflare.com/cdn-cgi/trace
```

未显式写 `-4/-6` 时，`ipv4`、`ipv6` 模式会采用相应默认值，`dual` 模式由 curl 和 DNS
结果选择。该命令直接把目标交给本机 WARP SOCKS5，不修改当前 Shell 或系统代理。

### 让单条命令使用 WARP

```bash
warpm run -- curl https://www.cloudflare.com/cdn-cgi/trace
warpm run -- git ls-remote https://github.com/example/example.git
```

`warpm run` 只给子进程设置 `ALL_PROXY=socks5h://127.0.0.1:40000`。程序如果不支持
`ALL_PROXY`，不会自动经 WARP；这时使用该程序自己的 SOCKS5 设置或 ProxyChains。

### 当前 Shell 临时启用

```bash
eval "$(warpm env)"
```

只对当前 Shell 及之后启动的子进程生效。关闭终端即可恢复，不会写入 `/etc/environment`、
`.bashrc` 或系统代理。

### ProxyChains

脚本生成：

```text
/etc/warp-manager/proxychains.conf
```

系统已安装 `proxychains4` 时可运行：

```bash
proxychains4 -f /etc/warp-manager/proxychains.conf COMMAND
```

ProxyChains 主要代理 TCP；它也不能让一个完全不支持代理的 UDP 程序自动获得 WARP。

## 可选：接入 3x-ui/Xray

安装完成后运行：

```bash
sudo warpm status
sudo warpm integrations
```

### 1. 添加所需地址族的 SOCKS 出站

脚本会生成三种模板；实际把所选模式对应的出站加入 3x-ui：

| Tag | `targetStrategy` | 行为 |
|---|---|---|
| `warp-ipv4` | `ForceIPv4` | 只允许 WARP IPv4，目标没有 A 记录就失败，不暗中回落 IPv6 |
| `warp-ipv6` | `ForceIPv6` | 只允许 WARP IPv6，目标没有 AAAA 记录就失败，不暗中回落 IPv4 |
| `warp-auto` | `UseIP` | 允许 Xray 在 WARP 内使用 IPv4/IPv6 |

例如 IPv6-only VPS 补 WARP IPv4：

```json
{
  "tag": "warp-ipv4",
  "protocol": "socks",
  "settings": {
    "address": "127.0.0.1",
    "port": 40000
  },
  "targetStrategy": "ForceIPv4"
}
```

这里的 `targetStrategy` 是 Xray 出站对象顶层字段。不要把 `ForceIPv4` 写进 `settings`。

### 2. 添加按域名分流规则

把规则放在兜底规则之前。下面让 Google TCP 只走 WARP IPv4：

```json
{
  "type": "field",
  "domain": ["geosite:google"],
  "network": "tcp",
  "outboundTag": "warp-ipv4",
  "ruleTag": "Google via WARP IPv4"
}
```

双栈模式可按需求把其他规则指向 `warp-ipv6`，或指向 `warp-auto`。建议路由
`domainStrategy` 保持 `AsIs`，并确保相关入站已开启域名嗅探，否则客户端只传入目标 IP
时，`geosite:google` 无法识别域名。

### 3. 防止 QUIC 从原生 IP 泄漏

本项目的模板只把 TCP 送入 Local Proxy。Google UDP/QUIC 若继续直连，会泄漏原生出口并
可能继续触发“送中”。建议把下面的规则放在 Google TCP 规则之后、其他兜底规则之前，让
应用自动回退 HTTPS/TCP：

```json
{
  "type": "field",
  "domain": ["geosite:google"],
  "network": "udp",
  "outboundTag": "blocked",
  "ruleTag": "Block Google QUIC leak"
}
```

这里假设 3x-ui 已有标签为 `blocked` 的 Blackhole 出站；没有时先创建一个，或改成你现有的
阻断出站标签。

### 4. 恢复原生出口

本脚本不会自动写 3x-ui 数据库。要恢复某条业务流量，删除对应 WARP 路由规则，或把它的
`outboundTag` 改回你原有的直连 Tag 即可。系统默认路由从未被替换，因此无需修复 SSH、
面板或网卡路由。

生成文件：

```text
/etc/warp-manager/xray-outbounds.json
/etc/warp-manager/xray-outbound-ipv4.json
/etc/warp-manager/xray-outbound-ipv6.json
/etc/warp-manager/xray-outbound-auto.json
/etc/warp-manager/xray-routing-rules.json
```

## 管理命令

```bash
sudo warpm
sudo warpm status
sudo warpm test --strict
warpm proxy-info
warpm env
warpm run -- COMMAND
warpm curl -4 URL
sudo warpm reconnect
sudo warpm rotate
sudo warpm update-client
sudo warpm set-egress ipv4
sudo warpm set-egress ipv6
sudo warpm set-egress dual
sudo warpm self-update --github
sudo warpm self-update --repo xinian5216/warp-egress-manager
sudo warpm self-update --main
sudo warpm integrations
sudo warpm uninstall
```

直接运行 `sudo warpm`（root Shell 可直接输入 `warpm`）会进入循环管理菜单，可以安装、
检查状态、切换 IPv4/IPv6 出口、查看代理用法、更新客户端或管理脚本以及卸载。每项操作
完成后按 Enter 返回主菜单，选择 `0` 才退出。

- `update-client`：只通过 Cloudflare 官方 APT/YUM 仓库更新，随后恢复 proxy 模式并验收。
- `set-egress`：只切换验收地址族并重生成 Xray 示例，不改默认路由、不重装客户端；3x-ui
  已导入的配置仍需按新 Tag 手动调整。
- `self-update`：默认查询最新正式 GitHub Release（`releases/latest`），并从对应不可变 tag
  下载主脚本，不需要 `gh` 或 PAT；也可 `--url` / `--file` / `--repo`。draft 与 prerelease
  会被拒绝，Release tag 必须与脚本 `SCRIPT_VERSION` 一致，否则拒绝安装；查询或解析失败时
  明确退出，**不会**回退 `main`。与最新正式版本相同时提示已最新；当前版本更高时拒绝自动
  降级。下载后执行 `bash -n`、项目标识、版本号检查，拒绝空文件和 HTML 错误页，再把新文件
  写入暂存并 `mv` 替换；旧版保留为 `/usr/local/sbin/warpm.bak`。失败时现有 `warpm` 继续可用。
  `warp3xui` 继续作为兼容命令。
  仅用于测试：`sudo warpm self-update --main` 显式从 `main` 分支更新；`main` 是开发基线，
  不是生产更新通道。
- `rotate`：删除并重建 WARP 注册。它可能更换出口，但 WARP 不支持指定国家，不能保证修复
  Google 地区判断。

## 更新与维护约定

- 主脚本包含语义化版本号 `SCRIPT_VERSION`；
- `CHANGELOG.md` 记录行为变化；
- WARP 客户端始终取自 Cloudflare 官方软件源，失败时不会改走第三方镜像；
- 项目脚本的唯一来源是 GitHub；GitHub 不可达时使用可选的 GitHub-only Proxy；
- GitHub Actions 对每次提交执行 ShellCheck、`bash -n` 和静态安全检查；
- 更新失败不会切换到全局 WARP 模式；安装中途失败会主动断开未验收的 WARP 连接。

## 故障排查

1. `sudo warpm status`
2. `sudo warpm test --strict`
3. `sudo journalctl -u warp-svc -n 100 --no-pager`
4. Local Proxy 必须使用 MASQUE；旧 WireGuard 配置会自动迁移
5. IPv6-only 无法访问 `pkg.cloudflareclient.com`：检查网络、DNS、NAT64，或手工提供官方离线包
6. 无法访问 GitHub：设置 `WARPM_GITHUB_PROXY`，不要把它当成系统全局代理
7. WARP 正常但 Google 仍显示 CN：运行 `rotate` 尝试换出口；仍为 CN 时通常只能换 VPS
   机房/线路，WARP 本身不能选国家
8. Google 规则不命中：确认入站 sniffing 已开启，规则在兜底规则之前，`geosite.dat` 足够新

## 安全说明

- SOCKS5 无认证，所以脚本只允许它监听 `127.0.0.1`/`::1`，切勿转发到公网；
- 本项目不会修改 3x-ui 数据库，避免不同 3x-ui 版本导致配置损坏；
- 安装表示你接受 Cloudflare WARP 的相关条款；
- WARP 不是匿名工具，也不保证流媒体、Gemini 或其他地区限制永久可用。

## 上游资料

- [Cloudflare WARP Linux 官方文档](https://developers.cloudflare.com/warp-client/get-started/linux/)
- [Cloudflare WARP 模式说明](https://developers.cloudflare.com/warp-client/warp-modes/)
- [Cloudflare Linux 软件包仓库](https://pkg.cloudflareclient.com/)
- [Xray SOCKS 出站文档](https://xtls.github.io/config/outbounds/socks.html)
- [Xray 出站与 targetStrategy 文档](https://xtls.github.io/config/outbound.html)
- [Xray 路由与 geosite 文档](https://xtls.github.io/config/routing.html)

## License

MIT
