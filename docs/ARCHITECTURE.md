# Architecture

```text
warp-egress-manager
      │
      ├── GitHub：代码 / 自更新的唯一项目来源
      │     └── 可选 WARPM_GITHUB_PROXY（只代理 GitHub）
      │
      ├── Cloudflare 官方仓库：cloudflare-warp 软件包来源
      │
      └── 本机 127.0.0.1:<port> SOCKS5 Local Proxy（MASQUE）
```

```mermaid
flowchart TD
    Client[代理客户端] --> Xray[3x-ui / Xray]
    Xray -->|Google TCP| Socks[127.0.0.1:40000]
    Socks --> Warp[Cloudflare WARP MASQUE]
    Xray -->|其他流量| Native[VPS 原生出口]
    Xray -->|Google UDP / QUIC| Block[Blackhole]
    Script[warpm self-update] -->|optional proxy| GitHub[GitHub]
    WarpPkg[cloudflare-warp] --> Official[pkg.cloudflareclient.com]
```

`warp-svc` 被固定在 Local Proxy 模式，隧道协议固定为 MASQUE。系统默认路由不指向
WARP，因此 SSH、面板与未命中 Xray 规则的连接不受 WARP 状态影响。

GitHub Proxy 若存在，只给 `github_curl` 使用。Cloudflare 官方软件源、
WARP trace、Google 和 YouTube 验收仍直连。

## Trust boundaries

- Cloudflare 官方软件包：由 Cloudflare APT/YUM 仓库和 GPG key 提供。
- 本管理脚本：复制到 `/usr/local/sbin/warpm`，保留 `warp3xui` 兼容入口。
- 非敏感运行参数：保存到权限 `0600` 的 `/etc/warp-manager/config.env`。
- WARP 注册信息：由官方客户端管理，本项目不读取或导出私钥。
- 3x-ui：只生成示例，不直接修改数据库或 Xray 配置。

## Failure behavior

- `mode proxy` 失败时不会执行 `connect`。
- 首次安装在验收前出错，会调用 `warp-cli disconnect`。
- 更新管理脚本前运行 `bash -n` 并验证项目标识；新文件先写入暂存再 `mv` 替换，旧版本保留为 `.bak`。
- WARP 代理异常不会改变系统默认路由，原生 SSH 不依赖 WARP。
- 官方软件源失败时不会改走第三方镜像。
