# Changelog

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
