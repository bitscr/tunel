# tunel 安装指南

安装顺序：部署 Worker → 安装服务器端 → 导入订阅。

只使用独立隧道时，可以跳过 Worker 部署，并省略安装命令中的上报参数。

## 1. 安装前准备

- 使用管理面板和订阅时，需要 Cloudflare 账号。
- 服务器支持 Linux AMD64、ARM64、ARMv7 与 386；预装 bash、curl 和 CA 证书。
- 普通用户及容器安装还需预装 tar、base64、sha256sum、flock（util-linux）、nohup、awk、sed、grep、tr 及常规 coreutils。
- 至少预留 128MiB 下载空间，并另留核心程序的安装空间。

## 2. 部署 Worker

### Cloudflare 网页编辑器

1. 创建 Worker 和 KV namespace，在 Worker Settings 中绑定 KV，名称必须是 `TUNEL_KV`。
2. 添加两个不同的 secrets：`ADMIN_TOKEN` 用于管理，`REPORT_TOKEN` 用于服务器上报。建议使用足够长、无空白和引号的随机 ASCII 值。
3. 用 [worker/_worker.js](worker/_worker.js) 的完整内容替换入口文件，保存并部署。
4. 打开 `https://your-worker.workers.dev/ui`，使用 `ADMIN_TOKEN` 登录。

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
| `SUB` | 可选 var | 初始优选订阅器域名或 URL，面板可保存覆盖或关闭 |
| `UPSTREAM` | 可选 var | 初始远程订阅 URL，换行或逗号分隔 |

### Wrangler（可选）

先安装 Node.js/npm，再在 `worker/` 目录执行：

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

### Pages（可选）

1. 使用 Pages 高级模式，项目根目录设为 `worker/`，构建命令留空，输出目录设为 `.`。
2. 在生产环境绑定 `TUNEL_KV`，添加 `ADMIN_TOKEN` 和 `REPORT_TOKEN`，然后重新部署；使用预览环境时也需单独配置。
3. 打开 Pages 域名下的 `/ui`，使用 `ADMIN_TOKEN` 登录。

## 3. 安装服务器端

推荐在管理面板「设置」页复制「一键安装并启动服务」命令，到服务器终端执行。

手工安装时，使用下面的命令，并替换域名及所有 `REPLACE_*` 占位值。

### 临时隧道

```sh
curl -fsSL https://raw.githubusercontent.com/bitscr/tunel/main/tunel.sh \
  | bash -s -- quick --report-url https://your-worker.workers.dev/api/report \
    --report-token 'REPLACE_REPORT_TOKEN' -y
```

### 固定隧道

先在 Cloudflare 创建隧道和公开主机名，将源服务设为 `http://127.0.0.1:18080`；安装端口必须与其一致。

```sh
curl -fsSL https://raw.githubusercontent.com/bitscr/tunel/main/tunel.sh \
  | bash -s -- fixed --domain tunnel.example.com --token 'REPLACE_TUNNEL_TOKEN' \
    --port 18080 --report-url https://your-worker.workers.dev/api/report \
    --report-token 'REPLACE_REPORT_TOKEN' -y
```

使用 JSON 凭据时，将 `--token 'REPLACE_TUNNEL_TOKEN'` 换成 `--json-file /path/to/tunnel.json`。不使用管理面板时，同时删除 `--report-url` 和 `--report-token`。

安装完成后，按下表选择管理命令，执行 `node` 查看节点与服务状态。

### 系统安装与普通用户

| 安装方式 | 管理命令 |
| --- | --- |
| root 默认系统安装 | `tunel` |
| 普通用户安装 | `"$HOME/.local/share/tunel/bin/tunel"` |
| 自定义目录 | `<TUNEL_HOME>/bin/tunel` |

系统目录不可写时会自动改用用户目录，以安装输出的实际路径为准。系统安装默认配置开机自启；普通用户安装需自行配置开机启动。

使用 `TUNEL_HOME` 指定自定义目录时，选择专用、可写的 ASCII 绝对路径，不要包含空格、引号、特殊字符或 `.` / `..` 路径段。

### 可选安装参数

| 参数 | 用法 |
| --- | --- |
| `--port N` | 指定未占用的监听端口，范围 1–65535；默认随机 |
| `--name X` | 设置管理页中的机器名称 |
| `--node-id ID` | 设置 4–64 位字母、数字、下划线或短横线组成的 ID；克隆机器使用独立 ID |
| `--cfip H` | 设置单个连接 IP / 域名；批量地址在面板 CFIP 中填写 |
| `--no-agent` | 不启动后台守护；后续手动执行 `agent start` 或容器入口 `run` |
| `-y` / `--yes` | 非交互安装 |

完整参数执行 `tunel help` 查看。

### 持久化容器（可选）

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

## 4. 导入订阅与设置优选

### 导入订阅

1. 登录管理面板 `/ui`，在「记录」页确认服务器节点已上报。
2. 打开「访问链接」，复制客户端对应的通用、Clash、sing-box、Surge、Quantumult X 或 Loon 订阅地址。
3. 在客户端添加订阅并更新。

需要添加手工节点或远程订阅时，在「数据源」中填写并保存。

### 设置优选（可选）

1. 打开「设置」页，在「优选订阅器」中填写可用的订阅器域名或完整 HTTP(S) 订阅 URL。
2. 在「CFIP 优选域名 / IP」中填写备用地址，一行一个，也可用逗号分隔；端口默认 443，IPv6 指定端口时使用 `[IPv6]:端口`。
3. 点击「保存连接设置」，再到客户端更新订阅。

优选订阅器按 cmliu/edgetunnel 官方协议拉取：固定请求所填域名的 `/sub?host=example.com&uuid=00000000-0000-4000-8000-000000000000`，使用官方格式的 User-Agent，不附加 `b64`。填写完整 URL 时，其路径与查询参数会被忽略；需要 token 或自定义路径的普通订阅 URL 应放到「数据源」的远程订阅中。

不使用优选订阅器时清空该字段并保存；清空 CFIP 可停用手工优选地址。保存后以面板设置为准。

## 5. 管理与更新

普通用户和自定义目录安装，将下面的 `tunel` 替换为实际管理命令。

| 命令 | 用途 |
| --- | --- |
| `tunel` / `tunel menu` | 打开交互菜单 |
| `tunel node` | 显示节点与服务状态 |
| `tunel agent status` / `tunel agent log` | 查看守护状态 / 日志 |
| `tunel agent start` / `tunel agent stop` / `tunel agent restart` | 启动、停止或重启守护，动作任选一个 |
| `tunel agent once` | 手动执行一轮检查 |
| `tunel restart` / `tunel report` | 重建隧道 / 手动上报 |
| `tunel config K=V ...` | 修改配置，可用参数见 `tunel help` |
| `tunel version` / `tunel help` | 版本 / 完整用法 |

### 更新已有安装

root 默认系统安装执行：

```sh
curl -fsSL https://raw.githubusercontent.com/bitscr/tunel/main/tunel.sh | bash -s -- agent start
```

用户或便携安装须沿用原 TUNEL_HOME；默认用户目录例如：

```sh
curl -fsSL https://raw.githubusercontent.com/bitscr/tunel/main/tunel.sh | TUNEL_HOME="$HOME/.local/share/tunel" bash -s -- agent start
```

自定义目录须使用原来的 `TUNEL_HOME`。更新后执行 `node` 查看状态，并在客户端刷新订阅。

## 6. 卸载与排障

按实际安装路径选择命令，设置页也提供对应复制按钮：

```sh
/usr/local/bin/tunel uninstall -y
"$HOME/.local/share/tunel/bin/tunel" uninstall -y
```

自定义目录使用其 `bin/tunel uninstall -y`。卸载后检查「记录」页，仍有对应记录时手动删除。

| 问题 | 处理方法 |
| --- | --- |
| 缺少依赖或目录不可写 | 补齐依赖，或设置可写的专用 `TUNEL_HOME` 后重新安装 |
| 未取得临时域名 | 查看 `tunel agent log`，确认守护已启动；使用了 `--no-agent` 时执行 `tunel agent start` |
| 申请临时域名返回 HTTP 429 | 保持守护运行，至少等待 1 小时后再试 |
| 上报返回 401 | 核对安装参数中的 `REPORT_TOKEN` 与 Worker secret 是否一致 |
| 国家/地区未识别 | 查看 `tunel agent log`；私网/ULA 先绑定原生默认接口取得公网出口 IP，再按该 IP 查询位置；IPv4 失败后尝试 IPv6，仍拒绝 WARP 位置 |
| 面板提示配置错误 | 核对 `TUNEL_KV`、两个 secrets 及当前部署环境 |

位置识别支持 IPv4 单栈、IPv6 单栈和双栈；没有 `ip` 命令时读取 `/proc` 默认路由。沿用 Linux/Bash、curl、awk 等原有依赖，不新增 jq/Python。IPify 不可用时仍会尝试原有位置接口；全部查询失败时保留已验证缓存或显示未识别，不阻断隧道运行。

订阅地址和安装命令包含凭据，不要公开。`SUBAPI` 请使用可信或自建转换服务。核心版本及来源见 [vendor/README.md](vendor/README.md)。
