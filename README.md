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

网络可以是 IPv4-only、IPv6-only 或双栈。安装时会分别探测公网 IPv4/IPv6，但不会据此
修改默认路由。

## 私有仓库安装

私有仓库不能匿名使用 `curl raw.githubusercontent.com/... | bash`。不要把 GitHub Token
直接写进命令历史。推荐在 VPS 上先登录 GitHub CLI：

```bash
gh auth login
gh api -H 'Accept: application/vnd.github.raw+json' \
  'repos/xinian5216/warp-3xui-safe/contents/warp-3xui.sh?ref=main' \
  > /tmp/warp-3xui.sh
sudo bash /tmp/warp-3xui.sh
```

如果 VPS（尤其 IPv6-only）无法访问 GitHub，先在电脑上下载 `warp-3xui.sh`，再用 SCP
上传到 VPS：

```bash
sudo bash warp-3xui.sh
```

非交互安装示例：

```bash
sudo bash warp-3xui.sh install \
  --port 40000 \
  --protocol auto \
  --repo xinian5216/warp-3xui-safe \
  --non-interactive
```

协议选择：

- `masque`：推荐，Cloudflare 当前默认；
- `wireguard`：部分网络上更合适；
- `auto`：先 MASQUE，失败再试 WireGuard。

## 3x-ui 配置

安装完成后运行：

```bash
sudo warp3xui status
sudo warp3xui snippets
```

### 1. 添加 SOCKS 出站

在 3x-ui 的“出站”中添加：

| 字段 | 值 |
|---|---|
| 协议 | `socks` |
| 标签/Tag | `warp-google` |
| 地址 | `127.0.0.1` |
| 端口 | `40000`（或安装时自定义端口） |
| 用户名、密码 | 留空 |

对应当前 Xray JSON：

```json
{
  "tag": "warp-google",
  "protocol": "socks",
  "settings": {
    "address": "127.0.0.1",
    "port": 40000
  }
}
```

### 2. 添加 Google TCP 分流

把该规则放在兜底规则之前：

```json
{
  "type": "field",
  "domain": ["geosite:google"],
  "network": "tcp",
  "outboundTag": "warp-google",
  "ruleTag": "Google via WARP"
}
```

建议路由 `domainStrategy` 保持 `AsIs`，并确保相关入站已开启域名嗅探，否则客户端只传入
目标 IP 时，`geosite:google` 无法识别域名。

### 3. 防止 QUIC 从原生 IP 泄漏

Cloudflare Local Proxy 不适合承载 UDP/QUIC。只让 TCP 走 WARP、UDP 继续直连会泄漏原生
出口，并可能继续触发 Google“送中”。建议把下面的规则放在 Google TCP 规则之后、其他
兜底规则之前，让应用自动回退 HTTPS/TCP：

```json
{
  "type": "field",
  "domain": ["geosite:google"],
  "network": "udp",
  "outboundTag": "blocked",
  "ruleTag": "Block Google QUIC leak"
}
```

这里假设 3x-ui 已有标签为 `blocked` 的 Blackhole 出站；没有时先创建一个 Blackhole 出站，
或把上述标签改成你现有的阻断出站标签。

完整示例也会写入：

```text
/etc/warp-3xui/xray-outbound.json
/etc/warp-3xui/xray-routing-rule-tcp.json
/etc/warp-3xui/xray-routing-rule-udp-block.json
```

## 管理命令

```bash
sudo warp3xui status
sudo warp3xui test --strict
sudo warp3xui reconnect
sudo warp3xui rotate
sudo warp3xui update-client
sudo warp3xui self-update --repo xinian5216/warp-3xui-safe
sudo warp3xui snippets
sudo warp3xui uninstall
```

- `update-client`：通过 Cloudflare 官方 APT/YUM 仓库更新客户端，随后恢复 proxy 模式并验收。
- `self-update`：先做 `bash -n` 与项目标识检查，再原子安装新脚本，旧版保留为
  `/usr/local/sbin/warp3xui.bak`。
- `rotate`：删除并重建 WARP 注册。它可能更换出口，但 WARP 不支持指定国家，不能保证修复
  Google 地区判断。

## 更新与维护约定

- 主脚本包含语义化版本号 `SCRIPT_VERSION`；
- `CHANGELOG.md` 记录行为变化；
- 第三方客户端不打包进仓库，始终来自 Cloudflare 官方软件源；
- GitHub Actions 对每次提交执行 ShellCheck、`bash -n` 和静态安全检查；
- 更新失败不会切换到全局 WARP 模式；安装中途失败会主动断开未验收的 WARP 连接。

## 故障排查

1. `sudo warp3xui status`
2. `sudo warp3xui test --strict`
3. `sudo journalctl -u warp-svc -n 100 --no-pager`
4. MASQUE 不通时：重新安装选择 `auto` 或 `wireguard`
5. WARP 正常但 Google 仍显示 CN：运行 `rotate` 尝试换出口；仍为 CN 时通常只能换 VPS
   机房/线路，WARP 本身不能选国家
6. Google 规则不命中：确认入站 sniffing 已开启，规则在兜底规则之前，`geosite.dat` 足够新

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
- [Xray 路由与 geosite 文档](https://xtls.github.io/config/routing.html)

## License

MIT
