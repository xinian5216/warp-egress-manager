# WARP for 3x-ui（安全 Local Proxy 版）

为 IPv4-only、IPv6-only、双栈 VPS 安装 Cloudflare 官方 WARP 客户端，并只在本机
`127.0.0.1:40000` 提供 SOCKS5 出站，供 3x-ui/Xray 按域名分流。

核心原则：**不让 WARP 接管系统 IPv4/IPv6 默认路由**。SSH、3x-ui 面板和未显式分流的
流量继续走 VPS 原生网络。

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
| `ipv4` | `warp-ipv4` / `ForceIPv4` | IPv6-only 补 IPv4；双栈 VPS 替换“送中”IPv4 |
| `ipv6` | `warp-ipv6` / `ForceIPv6` | IPv4-only 补 IPv6 |
| `dual` | `warp-ipv4`、`warp-ipv6`、`warp-auto` | 按规则自由选择两种 WARP 地址族 |
| `auto` | 单栈补另一族；双栈等同 `dual` | 不确定时使用 |

这些是 **Xray 的可选出站**，不是给 VPS 网卡新增地址。脚本不修改默认路由，也不会把整机
流量切到 WARP。

## 快速安装

### 方式一：Cloudflare Worker + 私有 R2（纯 IPv6 首选）

本项目使用独立的 Worker `warp-3xui-download` 与私有 R2 桶
`warp-3xui-private`，不会读取或覆盖 `xray-manager` 的对象。首次下载不访问 GitHub，
IPv4、双栈和没有 NAT64 的 IPv6-only VPS 都可以使用：

```bash
curl -fsSLo /tmp/warp3xui-install.sh \
  https://warp-3xui-download.xinian5216.workers.dev/install.sh &&
sudo bash /tmp/warp3xui-install.sh
```

按提示输入本项目专用的 Cloudflare 安装密钥。引导脚本会：

1. 从 Cloudflare 边缘下载 R2 中受保护的主脚本和 SHA256；
2. 校验 Bash 语法、项目标识和 SHA256；
3. 安装 Cloudflare 官方 WARP 客户端并配置 Local Proxy；
4. 把管理命令安装为 `/usr/local/sbin/warp3xui`；
5. 记录 Cloudflare 更新通道，以后从菜单更新时仍不依赖 GitHub。

> 该入口解决的是“纯 IPv6 无法获取私有 GitHub 脚本”的第一步。WARP 尚未安装时不可能
> 借 WARP 自己完成下载，所以系统软件源和 `pkg.cloudflareclient.com` 仍须通过原生 IPv6
> 可达。脚本会先检查官方软件源；不可达时明确停止，需临时 NAT64/代理或离线上传官方包，
> 不会偷偷启用全局 WARP。

### 一次性配置 R2 自动发布

本仓库的 `.github/workflows/publish-r2.yml` 会在改动合并到 `main` 后上传：

| R2 对象 | 用途 |
|---|---|
| `public/install.sh` | 公开引导脚本 |
| `releases/warp3xui/warp-3xui.sh` | 需要 Bearer 密钥的主脚本 |
| `releases/warp3xui/warp-3xui.sha256` | 需要 Bearer 密钥的校验值 |

先在 Cloudflare 创建 R2 桶 `warp-3xui-private`，再创建一个只对该桶拥有“对象读取和
写入”权限的 R2 API Token。把新凭据配置到 `warp-3xui-safe` 仓库：

- Variable：`CLOUDFLARE_ACCOUNT_ID`
- Secrets：`R2_ACCESS_KEY_ID`、`R2_SECRET_ACCESS_KEY`

`CLOUDFLARE_ACCOUNT_ID` 可以与 `xray-manager` 相同；两个 R2 Secrets 应使用刚创建的
专用 Token，不要复用 `xray-manager` 的凭据。

### 部署专用 Worker

仓库的 `worker/` 目录包含完整 Worker 源码和 `wrangler.jsonc`。在 Cloudflare Workers
中连接本 GitHub 仓库，并设置：

| 项目 | 值 |
|---|---|
| Worker 名称 | `warp-3xui-download` |
| 根目录 | `worker` |
| 构建命令 | `npm ci` |
| 部署命令 | `npm run deploy` |
| R2 Binding | `BUNDLES` → `warp-3xui-private`（已写入配置） |

为 Worker 添加一个独立 Secret：`INSTALL_TOKEN`。它就是用户运行引导脚本时输入的安装
密钥，不需要、也不建议与 `xray-manager` 相同。Worker 只公开：

- `/install.sh`：公开引导脚本；
- `/releases/warp3xui/warp-3xui.sh`：Bearer Token 保护；
- `/releases/warp3xui/warp-3xui.sha256`：Bearer Token 保护。

配置并完成首次发布后检查：

```bash
curl -6I \
  https://warp-3xui-download.xinian5216.workers.dev/install.sh
```

不带密钥访问 `/releases/warp3xui/warp-3xui.sh` 返回 `401` 才是正常状态。

### 方式二：私有 GitHub 安装

私有仓库不能匿名使用 `curl raw.githubusercontent.com/... | bash`。不要把 GitHub Token
直接写进命令历史。推荐在 VPS 上先登录 GitHub CLI：

```bash
gh auth login
gh api -H 'Accept: application/vnd.github.raw+json' \
  'repos/xinian5216/warp-3xui-safe/contents/warp-3xui.sh?ref=main' \
  > /tmp/warp-3xui.sh
sudo bash /tmp/warp-3xui.sh
```

如果未配置 Cloudflare 通道且 VPS 无法访问 GitHub，也可先在电脑上下载
`warp-3xui.sh`，再用 SCP 上传到 VPS：

```bash
sudo bash warp-3xui.sh
```

非交互安装示例：

```bash
sudo bash warp-3xui.sh install \
  --port 40000 \
  --protocol auto \
  --egress auto \
  --repo xinian5216/warp-3xui-safe \
  --non-interactive
```

协议选择：

- `masque`：推荐，Cloudflare 当前默认；
- `wireguard`：部分网络上更合适；
- `auto`：先 MASQUE，失败再试 WireGuard。

`--protocol` 决定 VPS 到 Cloudflare 使用 MASQUE 还是 WireGuard；`--egress` 决定 Xray
把目标解析为 IPv4、IPv6 还是两者。两组选项互不替代。

## 3x-ui 配置

安装完成后运行：

```bash
sudo warp3xui status
sudo warp3xui snippets
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
/etc/warp-3xui/xray-outbounds.json
/etc/warp-3xui/xray-outbound-ipv4.json
/etc/warp-3xui/xray-outbound-ipv6.json
/etc/warp-3xui/xray-outbound-auto.json
/etc/warp-3xui/xray-routing-rules.json
```

## 管理命令

```bash
sudo warp3xui
sudo warp3xui status
sudo warp3xui test --strict
sudo warp3xui reconnect
sudo warp3xui rotate
sudo warp3xui update-client
sudo warp3xui set-egress ipv4
sudo warp3xui set-egress ipv6
sudo warp3xui set-egress dual
sudo warp3xui self-update --repo xinian5216/warp-3xui-safe
sudo warp3xui snippets
sudo warp3xui uninstall
```

直接运行 `sudo warp3xui` 会进入循环管理菜单。执行状态检查、重连、更新等操作后按
Enter 返回主菜单，选择 `0` 才退出。

- `update-client`：通过 Cloudflare 官方 APT/YUM 仓库更新客户端，随后恢复 proxy 模式并验收。
- `set-egress`：只切换验收地址族并重生成 Xray 示例，不改默认路由、不重装客户端；3x-ui
  已导入的配置仍需按新 Tag 手动调整。
- `self-update`：自动沿用首次安装来源；Cloudflare 通道额外校验 SHA256，随后执行
  `bash -n` 与项目标识检查，再原子安装新脚本，旧版保留为
  `/usr/local/sbin/warp3xui.bak`。
- `rotate`：删除并重建 WARP 注册。它可能更换出口，但 WARP 不支持指定国家，不能保证修复
  Google 地区判断。

## 更新与维护约定

- 主脚本包含语义化版本号 `SCRIPT_VERSION`；
- `CHANGELOG.md` 记录行为变化；
- 第三方客户端不打包进仓库，始终来自 Cloudflare 官方软件源；
- GitHub Actions 对每次提交执行 ShellCheck、`bash -n` 和静态安全检查，合并后自动同步 R2；
- 更新失败不会切换到全局 WARP 模式；安装中途失败会主动断开未验收的 WARP 连接。

## 故障排查

1. `sudo warp3xui status`
2. `sudo warp3xui test --strict`
3. `sudo journalctl -u warp-svc -n 100 --no-pager`
4. MASQUE 不通时：重新安装选择 `auto` 或 `wireguard`
5. IPv6-only 安装在 `pkg.cloudflareclient.com` 处停止：说明 GitHub 引导已解决，但官方包源
   原生 IPv6 不可达；先提供 NAT64/临时代理或离线上传官方包
6. WARP 正常但 Google 仍显示 CN：运行 `rotate` 尝试换出口；仍为 CN 时通常只能换 VPS
   机房/线路，WARP 本身不能选国家
7. Google 规则不命中：确认入站 sniffing 已开启，规则在兜底规则之前，`geosite.dat` 足够新

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
