# tunel

tunel 在 Linux VPS 或容器中安装 sing-box 与 Cloudflare Tunnel，生成 VMess-WS 节点，并通过 Cloudflare Worker 管理记录和订阅。当前版本为 `0.0.1`。

节点名称显示国家和地区，例如 `美国 · California`；本机使用 `US · California` 或 `US-CA`，无法确认时显示 `未识别地区`。位置查询会避开 WARP 出口，避免把 Cloudflare 的位置当作服务器位置。

## 安装前准备

- 支持 Linux AMD64、ARM64、ARMv7 与 386。下载脚本前需要 bash、curl 和 CA 证书。
- 用户模式和容器需预装 tar、base64、sha256sum、flock（util-linux）、nohup、awk、sed、grep、tr 及常规 coreutils；便携模式不会调用系统包管理器。
- 每次安装核心至少需要 128MiB 可用空间，另需容纳安装后的二进制。项目带有日志整理和低资源保护，实际用量仍取决于连接数。

使用管理面板和订阅时先部署 Worker；独立使用隧道可以省略上报参数。

## 部署 Worker

### Cloudflare 网页编辑器

1. 创建 Worker 和 KV namespace，在 Worker Settings 中绑定 KV，名称必须是 `TUNEL_KV`。
2. 添加两个不同的 secrets：`ADMIN_TOKEN` 用于管理，`REPORT_TOKEN` 用于服务器上报。建议使用足够长、无空白和引号的随机 ASCII 值。
3. 用 [worker/_worker.js](worker/_worker.js) 的完整内容替换入口文件，保存并部署；入口叫 `work.js` 也可以。
4. 打开 `https://your-worker.workers.dev/ui`，使用 ADMIN_TOKEN 登录，从设置页复制安装命令。

兼容日期可使用 `2026-01-01`。网页编辑器不会自动读取 [worker/wrangler.toml](worker/wrangler.toml)，绑定和变量需在 Settings 中配置。

| 名称 | 类型 | 用途 |
| --- | --- | --- |
| `TUNEL_KV` | 必填 KV 绑定 | 保存节点与设置 |
| `ADMIN_TOKEN` | 必填 secret | 管理中心密码和订阅凭据 |
| `REPORT_TOKEN` | 必填 secret | 服务器上报凭据 |
| `SUBAPI` | 可选 var | 转换服务，默认 `https://clawsub.7979.pp.ua` |
| `SUBCONFIG` | 可选 var | 转换配置，默认值见 wrangler.toml |
| `SUBNAME` | 可选 var | 订阅文件名，默认 `tunel` |
| `CFIP` | 可选 var | 初始连接地址，面板保存后使用面板设置 |
| `UPSTREAM` | 可选 var | 初始远程订阅 URL，换行或逗号分隔 |

根路径公开显示 nginx 欢迎页；管理功能需要上述三个必填配置。

### Wrangler / Pages

在 `worker/` 目录执行：

```sh
npx wrangler login
npx wrangler kv namespace create TUNEL_KV
```

将返回的 namespace ID 填入 wrangler.toml，替换占位符，然后部署：

```sh
npx wrangler secret put ADMIN_TOKEN
npx wrangler secret put REPORT_TOKEN
npx wrangler deploy
```

Pages 高级模式也可使用同一份 `_worker.js`：项目根目录为 `worker/`，构建命令留空、输出目录为 `.`；绑定 KV 和 secrets 后重新部署，生产与预览环境分别配置。

## 安装服务器端

设置页的「一键安装并启动服务」会复制包含实际域名和凭据的命令。下面的手工示例需要替换部署域名及 ASCII 占位值。

临时隧道：

```sh
curl -fsSL https://raw.githubusercontent.com/bitscr/tunel/main/tunel.sh \
  | bash -s -- quick --report-url https://your-worker.workers.dev/api/report \
    --report-token 'REPLACE_REPORT_TOKEN' -y
```

固定隧道：先在 Cloudflare 创建隧道和公开主机名，将源服务设为 `http://127.0.0.1:18080`；安装端口必须与其一致。

```sh
curl -fsSL https://raw.githubusercontent.com/bitscr/tunel/main/tunel.sh \
  | bash -s -- fixed --domain tunnel.example.com --token 'REPLACE_TUNNEL_TOKEN' \
    --port 18080 --report-url https://your-worker.workers.dev/api/report \
    --report-token 'REPLACE_REPORT_TOKEN' -y
```

固定模式也可使用 `--json-file /path/to/tunnel.json`，与 `--token` 二选一。上报 URL 与 token 必须同时提供或同时省略；独立安装省略这两个参数即可。取得有效域名后会显示节点链接和服务状态，可直接导入客户端。

首次取域名失败会显示错误、服务状态和有限日志，退出码为 5；脚本与配置已保存，默认启动守护继续恢复，取得有效域名后更新节点并上报。Cloudflare 申请临时隧道返回 HTTP 429 时，至少等待 5 分钟再申请。使用 `--no-agent` 时需手动启动 `agent start` 或容器入口 `run`；恢复后执行 `node` 查看节点。

### 系统安装与普通用户

root 默认使用 `/etc/cf-tunel`、`/usr/local/bin/tunel` 和 `/var/log/cf-tunel`。系统目录不可写时，安装会自动退到 `$HOME/.local/share/tunel` 并显示实际路径；普通用户默认使用该用户目录。

默认系统安装会为 sing-box、cloudflared 和守护配置开机自启。systemd 等待 network-online；网络晚到时由守护继续恢复。使用 `--no-agent` 时不启用守护自启，便携与容器沿用各自的启动方式。

显式设置 `TUNEL_HOME` 可选择便携目录，出错时会报错；它必须是专用、可写的 ASCII 绝对路径，不能含空格、引号、特殊字符或 `.` / `..` 路径段。新安装不会自动迁移旧安装。

系统安装使用 `tunel` 命令；用户安装使用 `"$HOME/.local/share/tunel/bin/tunel"`，自定义目录使用其 `bin/tunel`。后续按安装时显示的路径管理。

### 持久化容器

先挂载持久卷到 `/data/tunel`，预装上述依赖，再在运行中的容器内下载并安装：

```sh
mkdir -p /data/tunel
curl -fsSL https://raw.githubusercontent.com/bitscr/tunel/main/tunel.sh -o /data/tunel/setup.sh
TUNEL_HOME=/data/tunel bash /data/tunel/setup.sh quick --no-agent -y \
  --report-url https://your-worker.workers.dev/api/report --report-token 'REPLACE_REPORT_TOKEN'
/data/tunel/bin/tunel run
```

安装完成后，将 `run` 设为容器入口，例如 Compose 服务片段：

```yaml
volumes:
  - ./tunel-data:/data/tunel
entrypoint: ["/data/tunel/bin/tunel", "run"]
stop_grace_period: 45s
```

`run` 用于无 init / 便携环境，读取持久化配置、前台运行并在正常停止时关闭本安装的核心进程。容器重启依靠入口恢复，不要只在镜像构建阶段启动后台进程。

## 参数与常用命令

安装选项支持 `--参数 值` 和 `--参数=值`：

| 参数 | 说明 |
| --- | --- |
| `--port N` | 本地监听端口，默认随机；显式端口须为 1–65535 且未占用 |
| `--name X` | 管理页的机器名称，默认主机名；订阅名称仍使用国家地区 |
| `--node-id ID` | 自定义 4–64 位字母、数字、下划线或短横线；克隆机器需独立 ID |
| `--cfip H` | 单一连接 IP / 域名；批量地址使用面板 CFIP |
| `--check-interval S` | 连接检查周期，默认 3600（1 小时），范围 300–86400 秒 |
| `--watch-interval S` | 域名同步周期，默认 60（1 分钟）；0 关闭额外同步，或 15–86400 秒 |
| `--no-agent` | 不启动后台守护；取得有效节点且配置了上报时仍首次上报，容器可随后启动 run |
| `-y` / `--yes` | 非交互安装 |

也可使用 `TUNEL_HOME`、`TUNEL_NODE_NAME`、`TUNEL_NODE_ID`、`TUNEL_CFIP`、`TUNEL_REPORT_URL`、`TUNEL_REPORT_TOKEN` 环境变量。

| 命令 | 用途 |
| --- | --- |
| `tunel` / `tunel menu` | 交互菜单；无终端时使用明确子命令 |
| `tunel node` | 显示节点与服务状态 |
| `tunel agent status` / `tunel agent log` | 查看守护状态 / 日志 |
| `tunel agent start` / `tunel agent stop` / `tunel agent restart` | 启动、停止或重启守护，动作任选一个 |
| `tunel agent once` | 手动执行一轮检查 |
| `tunel restart` / `tunel report` | 重建隧道 / 手动上报 |
| `tunel config K=V ...` | 修改配置 |
| `tunel version` / `tunel help` | 版本 / 完整用法 |

config 支持 REPORT_URL、REPORT_TOKEN、NODE_NAME、CFIP、CHECK_INTERVAL、WATCH_INTERVAL。重新 quick / fixed 安装时，未显式指定的周期恢复默认值：连接检查 3600 秒、域名同步 60 秒。

### 更新已有安装

已有安装先更新脚本，再应用新周期。root 默认系统安装执行：

```sh
curl -fsSL https://raw.githubusercontent.com/bitscr/tunel/main/tunel.sh | bash -s -- agent start
tunel config CHECK_INTERVAL=3600 WATCH_INTERVAL=60
```

用户或便携安装须沿用原 TUNEL_HOME；默认用户目录例如：

```sh
curl -fsSL https://raw.githubusercontent.com/bitscr/tunel/main/tunel.sh | TUNEL_HOME="$HOME/.local/share/tunel" bash -s -- agent start
"$HOME/.local/share/tunel/bin/tunel" config CHECK_INTERVAL=3600 WATCH_INTERVAL=60
```

自动兜底或自定义目录将两处示例路径都换成原目录。脚本更新会刷新本地脚本和相应的服务自启配置，保留既有 UUID、端口、路径、上报配置及已有周期；第二步 config 才应用新周期，无需重新填写上报 token。更新后的守护立即恢复缺失组件、同步当前域名，并检查连接。

## 日常使用

在 `/ui` 的「记录」按机器名称区分服务器，默认使用主机名；订阅里的节点名称仍只使用国家地区。「数据源」保存手工链接或远程订阅，「访问链接」复制通用、Clash、sing-box、Surge、Quantumult X 或 Loon 订阅。订阅支持 GET / HEAD；保存后刷新订阅，跨区传播仍可能短暂延迟。

设置页 CFIP 支持换行或逗号分隔的 IP / 域名及可选端口，默认端口 443；指定 IPv6 端口时使用 `[IPv6]:端口`。保存空 CFIP 会关闭自定义连接地址，不再回退环境变量；CFIP 不改变国家地区名称。

本机巡检默认间隔 30 秒，检查 cloudflared、sing-box 进程与核心文件、sing-box 配置；正在进行的连接检查、上报或下载结束后继续巡检。发现进程或文件丢失时立即恢复服务，取得当前有效临时域名后上报，无需重启机器。已有核心可运行就继续使用，缺失或无法运行时重新下载并校验；恢复保留原 UUID、端口和路径。恢复失败后约 5 分钟重试。

每次守护启动立即检查一次连接，此后默认每 1 小时检查一次；失败直接重建，不连续重复测活。重建失败约 5 分钟后直接重试重建，不再探测已判定失效的旧域名；上报失败只补发，不因此提前检查连接。域名默认每 1 分钟从本机同步，cloudflared 被系统自动拉起后也会同步新域名；本机域名同步不做外网测活。取得新域名后刷新客户端订阅。

systemd 安装会自动拉起被杀的守护；普通用户与容器安装需由进程管理器或容器重启策略保持守护运行。

Worker 不判断服务器是否在线，也不会自动删除离线记录。Quick Tunnel 没有可用性保证，长期使用建议固定隧道。

## 卸载与排障

按实际安装路径选择命令，设置页也提供对应复制按钮：

```sh
/usr/local/bin/tunel uninstall -y
"$HOME/.local/share/tunel/bin/tunel" uninstall -y
```

自定义目录使用其 `bin/tunel uninstall -y`。注销失败不会阻止本地清理，此时到记录页手动删除；永久下线的服务器也需手动移除。

安装失败先阅读终端显示的原因和日志路径；缺依赖先预装，目录错误改为可写的专用目录。申请临时域名出现 HTTP 429 表示限流，保持守护运行并等待自动重试；5 分钟是本地重试间隔，Cloudflare 何时解除限流由其服务决定。上报 401 时核对 REPORT_TOKEN；管理功能报配置错误时核对 KV、两个 secrets 与部署环境。

订阅地址与安装命令含凭据，请妥善保管。第三方 SUBAPI 可读取节点明文，需要时改用可信或自建转换服务。核心版本及上游来源见 [vendor/README.md](vendor/README.md)。
