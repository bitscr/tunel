# 上游运行文件

安装器使用以下固化版本：cloudflared `2026.10.7`、sing-box `1.14.4`。文件来源如下：

| 本仓库文件 | 上游下载地址 |
| --- | --- |
| `cloudflared/cloudflared-linux-386` | [cloudflared-linux-386](https://github.com/cloudflare/cloudflared/releases/download/2026.10.7/cloudflared-linux-386) |
| `cloudflared/cloudflared-linux-amd64` | [cloudflared-linux-amd64](https://github.com/cloudflare/cloudflared/releases/download/2026.10.7/cloudflared-linux-amd64) |
| `cloudflared/cloudflared-linux-arm` | [cloudflared-linux-arm](https://github.com/cloudflare/cloudflared/releases/download/2026.10.7/cloudflared-linux-arm) |
| `cloudflared/cloudflared-linux-arm64` | [cloudflared-linux-arm64](https://github.com/cloudflare/cloudflared/releases/download/2026.10.7/cloudflared-linux-arm64) |
| `sing-box/sing-box-1.14.4-linux-386.tar.gz` | [sing-box-1.14.4-linux-386.tar.gz](https://github.com/SagerNet/sing-box/releases/download/v1.14.4/sing-box-1.14.4-linux-386.tar.gz) |
| `sing-box/sing-box-1.14.4-linux-amd64.tar.gz` | [sing-box-1.14.4-linux-amd64-musl.tar.gz](https://github.com/SagerNet/sing-box/releases/download/v1.14.4/sing-box-1.14.4-linux-amd64-musl.tar.gz) |
| `sing-box/sing-box-1.14.4-linux-arm64.tar.gz` | [sing-box-1.14.4-linux-arm64-musl.tar.gz](https://github.com/SagerNet/sing-box/releases/download/v1.14.4/sing-box-1.14.4-linux-arm64-musl.tar.gz) |
| `sing-box/sing-box-1.14.4-linux-armv7.tar.gz` | [sing-box-1.14.4-linux-armv7.tar.gz](https://github.com/SagerNet/sing-box/releases/download/v1.14.4/sing-box-1.14.4-linux-armv7.tar.gz) |

AMD64 / ARM64 的 sing-box 使用官方静态 musl 包，适用于 glibc、musl 与精简容器；本仓库保留安装器使用的文件名，压缩包内容保持上游原样。保留随包提供的许可证文件。

更新运行文件后，在仓库根目录重新生成 [SHA256SUMS](SHA256SUMS)：

```sh
sha256sum vendor/cloudflared/* vendor/sing-box/* > vendor/SHA256SUMS
```

同时更新 `tunel.sh` 中的 `BUILTIN_SUMS`，确保文件名与摘要和清单一致。
