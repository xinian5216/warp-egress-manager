# Security Policy

## Supported versions

仅最新版本接收安全修复。

## Reporting

请在仓库中创建私有安全报告，不要在公开 Issue 中粘贴 WARP+ Key、3x-ui 配置、UUID、
私钥、服务器 IP 或访问令牌。

## Secrets

- `--license-file` 从本地文件读取 Key，只传递给 Cloudflare 官方 `warp-cli`，不会写入本项目配置文件。
- 不要把 GitHub Token 写进 README、脚本或命令历史。
- 3x-ui 示例不包含任何服务器凭据。
