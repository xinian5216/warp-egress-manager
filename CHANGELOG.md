# Changelog

## 1.2.0 - 2026-08-11

- 新增 `auto`、`ipv4`、`ipv6`、`dual` 四种可选 WARP 出口模式，单栈自动补齐缺失地址族。
- 为 Xray 生成 `warp-ipv4`、`warp-ipv6`、`warp-auto` 出站，使用 `targetStrategy` 严格控制目标地址族。
- IPv4 与 IPv6 WARP 出口分别验证；双栈模式要求两族都通过，仍禁止 WARP 接管系统默认路由。
- 新增 `warp3xui set-egress MODE` 和菜单入口，无需重装即可切换模式并重生成 3x-ui 示例。
- IPv6-only 安装前检查 Cloudflare 官方软件源，无法自举时给出 NAT64、临时代理或离线包提示。
- 补充恢复原生 3x-ui 出口的方法，明确脚本不会修改 3x-ui 数据库或 VPS 网卡地址。

## 1.1.1 - 2026-08-10

- 将下载链路从 `xray-manager` 拆分为专用 Worker `warp-3xui-download` 和专用 R2 桶 `warp-3xui-private`。
- 公开引导入口改为 Worker 根路径 `/install.sh`，主脚本与校验文件继续受独立 Bearer Token 保护。
- 将 Worker 源码、R2 绑定配置、路由测试和部署检查纳入仓库与 CI。
- 已安装版本读取到旧共享 Worker 地址时会自动迁移到新的专用地址。

## 1.1.0 - 2026-08-10

- `warp3xui` 无参数运行时进入可循环操作的管理菜单。
- 增加 Cloudflare Worker + 私有 R2 引导安装，解决 IPv6-only VPS 首次无法读取私有 GitHub 仓库的问题。
- Cloudflare 安装与自更新均校验 SHA256，安装密钥只在当前进程和临时权限文件中使用。
- 记录 GitHub / Cloudflare 更新来源，后续自更新自动沿用安装通道。
- 增加 Bash、ShellCheck、安全不变量检查和 R2 自动发布工作流。

## 1.0.0 - 2026-08-09

- 首个版本。
- 支持 IPv4-only、IPv6-only 和双栈 VPS 网络检测。
- 使用 Cloudflare 官方 Linux 客户端 Local Proxy 模式。
- 支持 MASQUE、WireGuard 与自动回退。
- 增加 WARP、Google、监听地址、双栈默认路由和“送中”启发式检查。
- 生成 3x-ui/Xray SOCKS 出站、Google TCP 分流和 QUIC 防泄漏示例。
- 增加客户端更新、脚本自更新、重连、注册轮换和卸载命令。
