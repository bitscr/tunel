# tunel

tunel 在 Linux VPS 或容器上安装 sing-box 与 Cloudflare Tunnel，通过守护检查恢复隧道、同步变化的 VMess 节点，再由 Cloudflare Worker 汇聚和转换订阅。当前版本为 `2.0.0`。

```text
VPS / 容器：sing-box ← cloudflared
                   ↑ tunel 守护检查 ── 变化时上报 ──→ Worker ↔ TUNEL_KV
                                                     ↑ 客户端访问链接
```

Worker 保存服务器上报的内容，不探活、不判断在线状态，也不会因为服务器下线自动删除记录。根路径 `/` 公开显示静态 nginx 欢迎页；管理中心位于 `/ui`。

## 先部署 Worker

### Cloudflare 网页编辑器

1. 创建 Worker 和一个 KV namespace，在 Worker 的 Settings 中添加 KV 绑定，名称必须是 `TUNEL_KV`。
2. 设置两个不同的 secrets：`ADMIN_TOKEN` 用于登录和管理，`REPORT_TOKEN` 用于服务器同步。建议使用足够长的随机 ASCII 值。
3. 打开代码编辑器，将仓库 [worker/_worker.js](worker/_worker.js) 的**完整 ES module 内容**替换入口文件内容。入口叫 `work.js` 也有效；不要再套入 `addEventListener` 或额外的 `export default { fetch }` 模板。
4. 兼容日期可设为 `2026-01-01`，按下表配置普通变量，保存并部署。
5. 打开 `https://your-worker.workers.dev/ui`，输入 `ADMIN_TOKEN` 的值作为密码登录，再从设置页复制安装命令。

请将示例中的 `your-worker.workers.dev` 换成自己的部署域名。[worker/wrangler.toml](worker/wrangler.toml) 不会自动应用到网页编辑器部署，绑定和变量需要在 Settings 中配置。

### Wrangler 与 Pages

Workers 命令行部署：进入 `worker/`，运行 `npx wrangler login`、`npx wrangler kv namespace create TUNEL_KV`，将返回的 namespace ID 替换 `wrangler.toml` 中的占位值；然后执行：

```sh
npx wrangler secret put ADMIN_TOKEN
npx wrangler secret put REPORT_TOKEN
npx wrangler deploy
```

Pages 高级模式使用同一份 `_worker.js`：项目根目录设为 `worker/`，构建命令留空、输出目录设为 `.`，在 Pages 设置中绑定 `TUNEL_KV` 和两个 secrets，保存后重新部署。生产与预览环境分别配置；无需 Cron Trigger。

## Worker 变量

| 名称 | 类型 | 作用 / 默认值 |
| --- | --- | --- |
| `TUNEL_KV` | 必填 KV 绑定 | 保存记录、数据源和 CFIP 设置 |
| `ADMIN_TOKEN` | 必填 secret | 管理中心密码、管理 API 与订阅鉴权 |
| `REPORT_TOKEN` | 必填 secret | 服务器上报与注销；请与 ADMIN_TOKEN 分开 |
| `SUBAPI` | var | `https://clawsub.7979.pp.ua`，可替换为自建转换服务 |
| `SUBCONFIG` | var | `https://raw.githubusercontent.com/ACL4SSR/ACL4SSR/master/Clash/config/ACL4SSR_Online_Mini_MultiMode.ini` |
| `SUBNAME` | var | `tunel`，输出文件名 |
| `CFIP` | var | 初始连接地址，默认空；面板保存后由 KV 设置覆盖 |
| `UPSTREAM` | var | 初始远程订阅 URL，换行或逗号分隔，可选 |

除根路径 GET / HEAD 欢迎页外，其余请求要求完整配置。缺少 secret 或 KV 会返回 JSON 500；根页能显示不代表管理接口已经配置完成。

## 管理中心

直接打开 HTTPS `/ui`，密码就是已有 `ADMIN_TOKEN`，无需新增密码变量或使用长链接。登录后可刷新或重新打开页面；会话有效期为 7 天，普通访问不续期，轮换 ADMIN_TOKEN 后需要重新登录。

页签分别为「记录」「数据源」「访问链接」「设置」。记录页可以复制链接、确认后删除；更新时间表示最近实际保存的时间，不代表在线状态。数据源页接受一行一个手工链接或远程 HTTP(S) URL；保存空远程列表时仍会回退 `UPSTREAM`，要停用远程源需同时清空该变量。

访问链接页提供通用格式、Clash、sing-box、Surge、Quantumult X、Loon 六种地址。设置页显示真实 REPORT_TOKEN，提供「复制凭据」和「一键安装并启动服务」；复制的安装命令已包含实际域名与 token，并进行 shell 单引号转义，无需再替换占位符。

设置页还提供系统目录与默认用户目录的卸载命令及复制按钮。按安装时输出的实际路径选择；自定义 TUNEL_HOME 使用其 `bin/tunel` 卸载。

UI 会话 cookie 为 `HttpOnly; Secure; SameSite=Strict; Path=/ui`，使用 HMAC-SHA256 签名并绑定当前 origin。它只授权 UI；API 和订阅仍使用显式 token。旧含 token 的 UI 入口仍可建立会话并清理地址栏。

## CFIP 连接地址

在设置页编辑 CFIP，可换行或逗号分隔 IP、域名及端口；省略端口时使用 443，指定 IPv6 端口时必须加方括号。例如：

```text
162.159.1.1:443
cf.example.com:8443
[2606:4700::1111]:443
```

以上仅为写法示例，地址是否适合连接需按实际环境选择。允许端口范围为 1–65535，保存时去空、去重；也接受不带端口的 IPv6 地址。

尚未保存时使用 Worker 的 `CFIP` 变量；保存后使用 KV 设置。**保存空内容会关闭自定义地址，不再回退环境变量**。对可解析的 VMess 链接，Worker 按每个地址生成副本，只修改连接地址、端口与备注，保留原始 Host 和 SNI。

CFIP 变化后使用对应的新缓存，旧地址输出不会因共用缓存键继续复用；KV 跨区传播仍可能有约 60 秒延迟。CFIP 设置请求与存储上限均为 8KB。

## 安装服务器端

先部署 Worker，再到外网 Linux VPS 或容器执行。以下示例中的域名与 `REPLACE_REPORT_TOKEN` 必须替换为实际值；token 不应含空白或引号，示例使用的 ASCII 占位值不会被 shell 当作重定向。

临时隧道：

```sh
curl -fsSL https://raw.githubusercontent.com/bitscr/tunel/main/tunel.sh \
  | bash -s -- quick --report-url https://your-worker.workers.dev/api/report \
    --report-token 'REPLACE_REPORT_TOKEN' -y
```

固定隧道：先在 Cloudflare 创建隧道与公开主机名，将源服务配置为 `http://127.0.0.1:18080`，再安装；域名、token 和端口需对应实际配置。

```sh
curl -fsSL https://raw.githubusercontent.com/bitscr/tunel/main/tunel.sh \
  | bash -s -- fixed --domain tunnel.example.com --token 'REPLACE_TUNNEL_TOKEN' \
    --port 18080 --report-url https://your-worker.workers.dev/api/report \
    --report-token 'REPLACE_REPORT_TOKEN' -y
```

固定模式也支持 `--json-file /path/to/tunnel.json`，与 `--token` 二选一。上报 URL 与 token 必须同时提供或同时省略；省略时可独立使用隧道。`--no-agent` 不启动后台守护，但配置了上报时仍会首次上报。

交互菜单与非交互 quick / fixed 安装末尾均输出模式、域名、本地端口、UUID、WS 路径、vmess 链接和服务状态。节点已经生成后，即使脚本落地或守护初始化失败也会显示节点信息，并保留失败退出码。

Quick Tunnel 官方定位是测试用途，无可用性保证，重启可能改变域名；200 个并发在途请求超限可能返回 429。长期使用可选择固定隧道，守护恢复不提供 SLA。

### 常用安装参数

| 参数 | 默认 / 说明 |
| --- | --- |
| `--port N` | 随机空闲端口；显式端口须为 1–65535 且未占用 |
| `--name X` | 主机短名，清理为字母、数字、点、下划线或短横线，最长 64 字符 |
| `--node-id ID` | 主机标识哈希前 12 位；自定义 4–64 位字母、数字、下划线或短横线 |
| `--cfip H` | 服务器单一连接地址，默认隧道域名；批量地址建议使用面板 CFIP |
| `--check-interval S` | CF 连接检查周期，默认 7200，范围 300–86400 秒；检查失败立即重建隧道 |
| `--watch-interval S` | 域名同步周期，默认 7200；0 关闭额外同步，或 15–86400 秒；连接检查也会同步域名 |
| `-y` / `--yes` | 非交互，不等待终端输入 |

支持 `--参数 值` 和 `--参数=值`。对应环境变量有 `TUNEL_NODE_NAME`、`TUNEL_NODE_ID`、`TUNEL_CFIP`、`TUNEL_REPORT_URL`、`TUNEL_REPORT_TOKEN`。克隆机器可能共享 machine-id，需为不同机器分配独立 node-id。

## 系统安装与普通用户自动兜底

root 未设置 TUNEL_HOME 时优先使用 `/etc/cf-tunel`、`/usr/local/bin/tunel` 和 `/var/log/cf-tunel`，有实际运行的 systemd / OpenRC 时使用系统服务；无 init 时使用进程守护。

root 执行 quick / fixed 或从菜单选择安装时，若默认系统目录或其最近的既存父目录不可写或无法访问，会在安装前自动退到 `$HOME/.local/share/tunel`，提示原因并显示实际安装路径。此兜底不会迁移旧安装；管理旧安装仍使用其原有启动器。显式指定的 TUNEL_HOME 无效或不可写时会报错，不能静默换到其他目录；HOME 兜底目录不可用时也会明确报错。

普通用户自动使用便携模式，默认 `$HOME/.local/share/tunel`；显式设置 TUNEL_HOME 时使用指定目录。便携模式不调用系统包管理器、系统服务、cron 或 rc.local，缺依赖时提示先预装 bash、curl、tar、base64、sha256sum、flock（util-linux）、nohup、awk、sed、grep、tr、常规 coreutils 与 CA 证书。

便携目录包含 `work/`、`bin/`、`log/`、`run/`，真实脚本在 `work/tunel.sh`，临时文件在 `work/tmp/`。普通用户命令为：

```sh
~/.local/share/tunel/bin/tunel node
~/.local/share/tunel/bin/tunel agent status
```

TUNEL_HOME 必须是专用、可写的 ASCII 绝对目录，仅允许字母、数字、点、下划线、短横线和斜杠；不能含空白、引号或 `.` / `..` 路径段，不能使用系统目录或 HOME 本身，管理子目录不能为符号链接。

便携 `bin/tunel` 固定导出安装时的 TUNEL_HOME，后续无需重复设置；系统启动器固定使用系统安装。创建便携安装应对原始 `tunel.sh` 设置 TUNEL_HOME。

## 无 init 容器与前台 run

先在已经挂载的持久化目录中完成 quick / fixed 安装，再将 run 作为启动入口。保存仓库根目录的 `tunel.sh` 后，例如：

```sh
TUNEL_HOME=/data/tunel bash tunel.sh quick --no-agent -y \
  --report-url https://your-worker.workers.dev/api/report --report-token 'REPLACE_REPORT_TOKEN'
/data/tunel/bin/tunel run
```

run 仅用于无 init / 便携环境，读取已安装配置、接管本安装的后台 agent；已有前台 run 时拒绝重复启动。收到 INT / TERM 或退出时停止本安装的核心进程。

Compose 服务配置可使用以下片段，镜像需预装上述依赖，持久卷中需已有安装：

```yaml
volumes:
  - ./tunel-data:/data/tunel
entrypoint: ["/data/tunel/bin/tunel", "run"]
stop_grace_period: 45s
```

shell 入口使用 `exec /data/tunel/bin/tunel run`。便携后台 `agent start` 不注册开机钩子；容器重启依靠 entrypoint 重新启动、恢复并按需上报，不依靠构建阶段的后台进程。

## 常用命令

下表的 `tunel` 指对应安装的命令；便携安装请使用其 `bin/tunel` 完整路径。

| 命令 | 用途 |
| --- | --- |
| `tunel` / `tunel menu` | 有终端时打开交互菜单；无参数且无终端时打印帮助并退出 2 |
| `tunel node` | 显示节点信息与服务状态 |
| `tunel agent start/stop/restart/status` | 此处斜杠表示任选一个动作，例如 `tunel agent status` |
| `tunel agent log` | 持续查看最近 100 行守护日志 |
| `tunel agent once` | 手动执行一轮守护检查与按需上报 |
| `tunel run` | 无 init / 便携安装前台运行 |
| `tunel report` | 手动立即上报，不要求节点已变化 |
| `tunel restart` | 受控重启隧道、刷新域名后上报 |
| `tunel config K=V ...` | 修改配置后重启守护 |
| `tunel uninstall -y` | 注销记录并清理本安装 |
| `tunel help` / `tunel version` | 用法 / 版本 |

config 只接受 REPORT_URL、REPORT_TOKEN、NODE_NAME、CFIP、CHECK_INTERVAL、WATCH_INTERVAL，例如 `tunel config CHECK_INTERVAL=7200 WATCH_INTERVAL=7200`。上报端点使用精确的 `/api/report`，不要追加斜杠或 query。

重新 quick / fixed 安装时，未显式指定的两个周期会重设为 2 小时，显式参数仍可自定义。已有安装不重装时，执行上述 config 命令更新；旧配置或进程不会仅因源码更新自动改为 2 小时。

## 守护检查

默认每 **2 小时检查一次 CF 隧道能否连接**，流程如下：

1. 读取 cloudflared 当前域名，检查进程、CF 连接就绪状态与外网 WebSocket 握手。
2. 连接正常就继续使用；任一检查失败，立即重启 cloudflared，重新建立临时隧道，不对旧连接重复探测。
3. 取得新的 `*.trycloudflare.com` 域名后，立即更新本机节点并上报到 Worker，订阅随之更新。

这里的“另一个 CF”指新的临时隧道域名。固定隧道也会重新连接，但绑定域名保持不变。

本机 sing-box 停止或不通时会一并重启。重建保留端口、UUID 和路径；取得新域名有最多 60 秒的等待，本轮重建失败则记录错误，下一次仍按 2 小时周期检查。默认从断连到下一次检查最多约 2 小时。

域名同步也默认每 2 小时执行，已包含在上述连接检查中；cloudflared 被系统自动拉起后，脚本会读取其新域名。CHECK_INTERVAL 与 WATCH_INTERVAL 均默认 7200 秒，可用参数调整。

首次安装、节点变化和手动 report 才上报，没有周期心跳。取得新域名后不再重复执行外网探测；上报失败保留待补发状态。启动时确保组件运行，域名与最后成功上报值不同时更新。稳定检查成功不会产生新写入。

系统安装配置为 `/etc/cf-tunel/agent.env`，便携配置为 TUNEL_HOME 下 `work/agent.env`；运行计数在 `agent.state`，守护日志在 `agent.log`。服务名保留为 cf-tunel-singbox、cf-tunel-argo、cf-tunel-agent。

## API 与订阅

| 方法 / 路径 | 鉴权 / 用途 |
| --- | --- |
| POST `/api/report`、`/api/node/delete` | REPORT_TOKEN，保存或注销节点；注销 body 为 `{"id":"记录ID"}` |
| GET `/api/nodes`、DELETE `/api/node?id=...` | ADMIN_TOKEN，读取或删除记录 |
| GET / PUT `/api/sources` | ADMIN_TOKEN，手工 links 与远程 upstream，总体积上限 64KB |
| GET / PUT `/api/settings` | ADMIN_TOKEN，CFIP 设置；PUT body 为 `{"cfip":"地址列表"}` |
| GET `/api/status` | ADMIN_TOKEN，版本、配置与数量 |
| GET `/sub` | ADMIN_TOKEN，订阅输出；可加 clash、sb、surge、quanx、loon 等参数 |
| GET `/raw?t=...` | 日派生只读 token，供转换服务读取本地链接 |

REPORT 支持 Bearer 或 X-Report-Token；ADMIN 支持 Bearer、X-Admin-Token、query token 或路径首段 token。相同节点内容返回 skipped:true，不写 KV，也不刷新更新时间；记录没有 TTL，注销或手动删除才消失。转换异常会回退本地 base64，响应头为 `X-Tunel-Fallback: subconverter-failed`。

## 故障排查

| 现象 | 处理 |
| --- | --- |
| 登录后又回登录页 | 使用 HTTPS、允许会话 cookie；会话到期或 ADMIN_TOKEN 轮换后重新登录 |
| API JSON 500 | 检查 KV、两个 secrets 和部署环境；CFIP 无效时到设置页修正 |
| 平台错误 1101 | 表示 JavaScript 异常，不能仅凭它认定封禁；启用 Workers Logs，在 Observability Events 查看 exception / stack，分享前隐藏 token |
| 安装停在已有核心或核心启动失败 | 新版安装确认现有 cloudflared / sing-box 的实际版本与执行结果，异常时说明原因并从 vendor 重新下载；配置检查或服务失败会显示具体路径和错误 |
| 获取不到域名 | 查看 agent 日志；metrics 端口在 agent.env，检查 `http://127.0.0.1:端口/quicktunnel` 与 `/ready` |
| 上报 401 | 核对服务器 REPORT_TOKEN 与 Worker secret，不要错用 ADMIN_TOKEN |
| 握手 000 / 502、503、530 / 404 / 429 | 分别检查连接超时、源服务不可达、路径不匹配、Quick Tunnel 并发限流 |
| 订阅为空或格式回退 | 检查记录与数据源、SUBAPI；部分远程源屏蔽 SubConverter-Request 请求头 |
| 容器重启未恢复 | 持久化安装目录，先安装再运行，使用对应 bin/tunel run 作为 entrypoint |
| 安装目录不可写或便携缺依赖 | root 默认系统路径不可写时会显示自动兜底的用户目录；显式 TUNEL_HOME 报错时选择可写的专用绝对目录，便携模式缺依赖需先预装 |

## 卸载与安全

执行对应安装的 `tunel uninstall -y`。注销失败不阻止本地卸载，此时到管理中心的记录页手动删除；相同链接若仍在数据源中也需移除。

设置页提供以下两条命令，按安装时输出的实际路径选择：

| 安装位置 | 卸载命令 |
| --- | --- |
| 系统目录 | `/usr/local/bin/tunel uninstall -y` |
| 默认用户目录 | `"$HOME/.local/share/tunel/bin/tunel" uninstall -y` |

自定义 TUNEL_HOME 使用其 `bin/tunel uninstall -y`。命令调用已安装的启动器，读取本地 `agent.env` 中的凭据注销记录并卸载，无需在命令中重新传入 token。

系统卸载清理三服务、启动器、工作目录与日志；便携卸载删除 work/log 和本工具文件，bin/run/安装根目录仅在为空时删除，保留其中其他文件。服务器永久下线不会自动移除 Worker 记录。

工作目录权限为 700，含凭据配置为 600，固定隧道 token 使用私有 token 文件。登录后的管理页面会包含 ADMIN_TOKEN 与 REPORT_TOKEN；订阅 URL 也包含管理凭据，请只交给可信客户端，复制的安装命令也应妥善保管。

第三方 SUBAPI 可以读取节点明文与远程 URL；需要减少第三方接触时使用自建转换服务。只在变化时上报、重复写抑制与 60 秒缓存可减少用量，但面板读取、分页与设置保存仍消耗配额，容量与计费以 Cloudflare 当前控制台及官方说明为准。
