#!/bin/sh
# ============================================================================
# 极端环境保护：Alpine / minimal 系统默认没有 bash。
# 用 sh 直接跑（sh <脚本名>）时先自举安装 bash，再切回 bash 重新执行自己。
# ============================================================================
if [ -z "$BASH_VERSION" ]; then
    if ! command -v bash > /dev/null 2>&1; then
        echo "当前 shell 不是 bash，正在尝试安装 bash..."
        if command -v apk > /dev/null 2>&1; then
            apk add --no-cache bash > /dev/null 2>&1
        elif command -v apt-get > /dev/null 2>&1; then
            apt-get update -y > /dev/null 2>&1
            DEBIAN_FRONTEND=noninteractive apt-get install -y bash > /dev/null 2>&1
        elif command -v yum > /dev/null 2>&1; then
            yum install -y bash > /dev/null 2>&1
        elif command -v dnf > /dev/null 2>&1; then
            dnf install -y bash > /dev/null 2>&1
        fi
    fi
    if command -v bash > /dev/null 2>&1 && [ -f "$0" ]; then
        exec bash "$0" "$@"
    fi
    echo "错误: 本脚本需要 bash。请先安装后重试（Alpine: apk add bash / Debian: apt-get install -y bash）"
    echo "或者用: curl -fsSL <脚本地址> | bash"
    exit 1
fi
# ============================================================================

SELF="${0##*/}"
case "$SELF" in
    bash|sh|dash|-bash|-sh|"") SELF="tunel.sh" ;;
esac

# ============================================================================
# 版本固化：只从本仓库 vendor 下载，sha256 必须与 vendor/SHA256SUMS 一致
# ============================================================================
VENDOR_CF_TAG="2026.10.7"
VENDOR_SB_TAG="1.14.4"
VENDOR_REPO="${VENDOR_REPO:-bitscr/cf-tunel}"
VENDOR_REF="${VENDOR_REF:-main}"
VENDOR_RAW_BASE="https://raw.githubusercontent.com/$VENDOR_REPO/$VENDOR_REF"

# 内置校验清单：仓库 SHA256SUMS 取不到时兜底，改版本时务必与 vendor/SHA256SUMS 一起更新
BUILTIN_SUMS="
4823d2f038395617e04e4070601ab45c0c43f31f15ee7586be299e19ef49d46e  vendor/cloudflared/cloudflared-linux-386
1f99fb518b83dec2ba8d870a7cc991d82a77e6196295a3d2754ba17ab9f91872  vendor/cloudflared/cloudflared-linux-amd64
74f690f6707182839b63e0465726c7776dd63f0a174390b911d5d71f35cab94e  vendor/cloudflared/cloudflared-linux-arm
3df43aedc9ff291d1735b5cb576cb97e0b157488796db2e32b28aecabb445775  vendor/cloudflared/cloudflared-linux-arm64
efb46daaa48ee55e090bd1dfcaee34bfbe9bdbd9b89fa9f328d25f81a619e865  vendor/sing-box/sing-box-1.14.4-linux-386.tar.gz
699a1b510aa4396b2176d32d1181920399ebf1e267835da6f3b598d0f7c24968  vendor/sing-box/sing-box-1.14.4-linux-amd64.tar.gz
436441f76ee2f7fe21b5b2d426d3cb261a480455a704865789ad533e4273ec26  vendor/sing-box/sing-box-1.14.4-linux-arm64.tar.gz
fd164ed45ebc784f657a3e1d0e0ad0f68afdcff864ee57122c2cfed3ddb80a00  vendor/sing-box/sing-box-1.14.4-linux-armv7.tar.gz
"

# 工作目录与文件
WORK_DIR="/etc/cf-tunel"
SB_DIR="$WORK_DIR/sing-box"
SB_BIN="$SB_DIR/sing-box"
SB_CFG="$SB_DIR/config.json"
CF_BIN="$WORK_DIR/cloudflared"
ARGO_LOG="$WORK_DIR/argo.log"
TUNNEL_YML="$WORK_DIR/tunnel.yml"
TUNNEL_JSON="$WORK_DIR/tunnel.json"
NODE_DIR="$WORK_DIR/nodes"

# --- 颜色定义 ---
red='\033[0;31m'
green='\033[0;32m'
yellow='\033[0;33m'
purple='\033[0;35m'
skyblue='\033[0;36m'
white='\033[1;91m'
re='\033[0m'

# ============================================================================
# 基础工具
# ============================================================================
has() { command -v "$1" > /dev/null 2>&1; }

install_soft() { # $1..=包名
    local pkg
    for pkg in "$@"; do
        has "$pkg" && continue
        if has apk; then
            apk add --no-cache "$pkg" > /dev/null 2>&1
        elif has apt-get; then
            DEBIAN_FRONTEND=noninteractive apt-get install -y "$pkg" > /dev/null 2>&1
        elif has dnf; then
            dnf install -y "$pkg" > /dev/null 2>&1
        elif has yum; then
            yum install -y "$pkg" > /dev/null 2>&1
        fi
    done
}

# 环境探测：init 系统 + 内存/磁盘
ENV_INIT="none"
ENV_LOWMEM=0
env_detect() {
    if has systemctl && [ -d /run/systemd/system ]; then
        ENV_INIT="systemd"
    elif has rc-service && has rc-update; then
        ENV_INIT="openrc"
    else
        ENV_INIT="none"
    fi
    local mem
    mem=$(awk '/MemTotal/{printf "%d", $2/1024}' /proc/meminfo 2>/dev/null)
    [ -n "$mem" ] && [ "$mem" -lt 400 ] && ENV_LOWMEM=1
    return 0
}

env_line() {
    local mem
    mem=$(awk '/MemTotal/{printf "%d", $2/1024}' /proc/meminfo 2>/dev/null)
    echo -e "${skyblue}系统: $(uname -m) | 内存: ${mem:-?}MB | init: $ENV_INIT${re}"
}

clear_screen() {
    if [ -n "$TERM" ] && [ -t 1 ]; then
        clear 2>/dev/null || true
    fi
}

press_any_key_to_continue() {
    echo -e "${skyblue}---------------------------------------------------------${re}"
    if [ ! -t 0 ] || [ -n "$DIRECT_MODE" ]; then
        return 0
    fi
    read -n 1 -s -r -p "按任意键返回上一级菜单..."
    echo ""
}

# --- 端口工具 ---
valid_port() {
    local p=$1
    case "$p" in
        ''|*[!0-9]*) return 1 ;;
    esac
    [ "${#p}" -le 5 ] || return 1
    p=$((10#$p))
    [ "$p" -ge 1 ] && [ "$p" -le 65535 ]
}

norm_port() {
    local p=$1
    case "$p" in
        ''|*[!0-9]*) printf '%s' "$p"; return 1 ;;
    esac
    printf '%d' "$((10#$p))"
}

rand_port() {
    if has shuf; then
        shuf -i 2000-65000 -n 1
    else
        awk 'BEGIN{srand(); printf "%d\n", 2000+int(rand()*63001)}'
    fi
}

check_port() { # 返回 0 = 被占用
    local port=$1 hex
    if has netstat; then
        netstat -tuln 2>/dev/null | grep -qE "[:.]$port\b" && return 0
        return 1
    fi
    if has ss; then
        ss -tuln 2>/dev/null | grep -qE "[:.]$port\b" && return 0
        return 1
    fi
    hex=$(printf '%04X' "$port")
    awk -v h="$hex" 'NR>1 { n=split($2,a,":"); if (a[n]==h) { f=1; exit } } END { exit !f }' \
        /proc/net/tcp /proc/net/tcp6 /proc/net/udp /proc/net/udp6 2>/dev/null
}

ensure_netstat() {
    has netstat || has ss && return 0
    install_soft net-tools
}

pick_free_port() {
    local pref=${1:-} p i
    if [ -n "$pref" ] && ! check_port "$pref"; then
        printf '%s' "$pref"
        return 0
    fi
    for ((i = 0; i < 50; i++)); do
        p=$(rand_port)
        if ! check_port "$p"; then
            printf '%s' "$p"
            return 0
        fi
    done
    printf '%s' "$(rand_port)"
}

# --- 随机值：不依赖 openssl / shuf ---
rand_uuid() {
    if [ -r /proc/sys/kernel/random/uuid ]; then
        cat /proc/sys/kernel/random/uuid
        return
    fi
    local h
    h=$(od -An -tx1 -N16 /dev/urandom 2>/dev/null | tr -d ' \n')
    printf '%s-%s-%s-%s-%s\n' "${h:0:12}" "${h:12:4}" "${h:16:4}" "${h:20:4}" "${h:24:12}"
}

rand_token() {
    od -An -tx1 -N8 /dev/urandom 2>/dev/null | tr -d ' \n' | cut -c1-12
}

# --- 下载与校验 ---
http_fetch() { # $1=url $2=输出文件
    if has curl; then
        curl -fsSL --retry 3 --retry-delay 2 --connect-timeout 15 --max-time 600 -o "$2" "$1"
    elif has wget; then
        wget -q -T 30 -t 3 -O "$2" "$1"
    else
        echo -e "${red}错误: 本机没有 curl 也没有 wget，无法下载${re}" >&2
        echo -e "${yellow}请先安装其一（Alpine: apk add curl / Debian: apt-get install -y curl）${re}" >&2
        return 127
    fi
}

VENDOR_SUMS=""
vendor_sums_load() {
    [ -n "$VENDOR_SUMS" ] && return 0

    # 1) 脚本旁边有 vendor/SHA256SUMS（本地跑或整包下载）就直接用
    local here f
    here=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)
    if [ -n "$here" ] && [ -r "$here/vendor/SHA256SUMS" ]; then
        VENDOR_SUMS=$(cat "$here/vendor/SHA256SUMS")
    fi
    # 2) 否则从仓库拉
    if [ -z "$VENDOR_SUMS" ]; then
        f=$(mktemp) || return 1
        if http_fetch "$VENDOR_RAW_BASE/vendor/SHA256SUMS" "$f"; then
            VENDOR_SUMS=$(cat "$f")
        fi
        rm -f "$f"
    fi
    # 3) 都拿不到就用脚本里写死的清单兜底（与仓库 SHA256SUMS 保持同步）
    if [ -z "$VENDOR_SUMS" ]; then
        echo -e "${yellow}取不到 vendor/SHA256SUMS，使用脚本内置清单${re}" >&2
        VENDOR_SUMS="$(printf '%s\n' "$BUILTIN_SUMS")"
    fi

    [ -n "$VENDOR_SUMS" ]
}

vendor_expect_sha() { # $1=vendor 内相对路径
    vendor_sums_load || return 1
    printf '%s\n' "$VENDOR_SUMS" | awk -v p="vendor/$1" '$2==p {print $1; exit}'
}

sha256_of() { # $1=文件
    if has sha256sum; then
        sha256sum "$1" 2>/dev/null | awk '{print $1}'
    elif has openssl; then
        openssl dgst -sha256 -r "$1" 2>/dev/null | awk '{print $1}'
    else
        return 1
    fi
}

# 下载并强校验：只从仓库 vendor 取，sha256 与清单不一致直接拒绝安装
vendor_fetch() { # $1=vendor 内相对路径  $2=输出文件
    local rel=$1 out=$2 want got
    vendor_sums_load >/dev/null 2>&1
    want=$(vendor_expect_sha "$rel")
    if [ -z "$want" ]; then
        echo -e "${red}错误: 校验清单里没有 $rel${re}"
        echo -e "${yellow}可能是仓库 vendor/SHA256SUMS 未同步，请检查。${re}"
        return 1
    fi

    echo -e "${yellow}正在下载 $rel ...${re}"
    if ! http_fetch "$VENDOR_RAW_BASE/vendor/$rel" "$out" || [ ! -s "$out" ]; then
        rm -f "$out"
        echo -e "${red}错误: 从 $VENDOR_RAW_BASE 下载失败${re}"
        echo -e "${yellow}检查本机网络能否访问 raw.githubusercontent.com（国内可能需要代理）。${re}"
        return 1
    fi

    got=$(sha256_of "$out")
    if [ -z "$got" ]; then
        echo -e "${red}错误: 本机没有 sha256sum / openssl，无法校验${re}"
        return 1
    fi
    if [ "$got" != "$want" ]; then
        echo -e "${red}错误: sha256 校验不通过，文件可能被篡改或下载损坏，已拒绝安装${re}"
        echo -e "${yellow}期望: $want${re}"
        echo -e "${yellow}实际: $got${re}"
        return 1
    fi
    echo -e "${green}sha256 校验通过${re}"
    return 0
}

# --- 架构映射 ---
cf_arch() { # cloudflared 资产名后缀
    case "$(uname -m)" in
        x86_64|amd64)      echo "amd64" ;;
        aarch64|arm64)     echo "arm64" ;;
        armv7l|armv8l|arm) echo "arm" ;;
        i386|i686)         echo "386" ;;
        *)                 return 1 ;;
    esac
}

sb_arch() { # sing-box 资产名后缀
    case "$(uname -m)" in
        x86_64|amd64)      echo "amd64" ;;
        aarch64|arm64)     echo "arm64" ;;
        armv7l|armv8l|arm) echo "armv7" ;;
        i386|i686)         echo "386" ;;
        *)                 return 1 ;;
    esac
}

# ============================================================================
# 服务管理抽象层：systemd -> openrc -> 都没有（nohup + ctl 脚本）
# ============================================================================
svc_wrapper() { # $1=服务名 $2=完整命令行
    cat > "/usr/local/bin/$1-run" <<EOF
#!/bin/sh
exec $2
EOF
    chmod 755 "/usr/local/bin/$1-run"
}

svc_env_lines() {
    if [ "$ENV_LOWMEM" = 1 ]; then
        printf 'Environment=GOGC=30\nEnvironment=GOMEMLIMIT=48MiB\n'
    fi
}

svc_install() { # $1=systemd单元名 $2=openrc服务名 $3=描述 $4=完整命令行 $5=日志目录
    local unit=$1 oname=$2 desc=$3 cmd=$4 logdir=$5 envsh=""
    mkdir -p "$logdir"
    svc_wrapper "$oname" "$cmd"
    [ "$ENV_LOWMEM" = 1 ] && envsh=$(printf 'export GOGC=30\nexport GOMEMLIMIT=48MiB')

    case "$ENV_INIT" in
    systemd)
        cat > "/etc/systemd/system/$unit.service" <<EOF
[Unit]
Description=$desc
After=network.target nss-lookup.target

[Service]
Type=simple
User=root
ExecStart=$cmd
Restart=on-failure
RestartSec=10
LimitNOFILE=infinity
$(svc_env_lines)
[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        systemctl enable "$unit" >/dev/null 2>&1
        systemctl restart "$unit"
        ;;
    openrc)
        if has supervise-daemon; then
            cat > "/etc/init.d/$oname" <<EOF
#!/sbin/openrc-run
name="$oname"
description="$desc"
command="/usr/local/bin/$oname-run"
$envsh
supervisor="supervise-daemon"
supervise_daemon_args="--respawn-delay 5 --respawn-max 0"
output_log="$logdir/access.log"
error_log="$logdir/error.log"
depend() {
    need net
    after net
}
EOF
        else
            cat > "/etc/init.d/$oname" <<EOF
#!/sbin/openrc-run
name="$oname"
description="$desc"
command="/usr/local/bin/$oname-run"
$envsh
command_background=true
pidfile="/run/$oname.pid"
output_log="$logdir/access.log"
error_log="$logdir/error.log"
depend() {
    need net
    after net
}
EOF
        fi
        chmod 755 "/etc/init.d/$oname"
        rc-update add "$oname" default >/dev/null 2>&1
        rc-service "$oname" restart >/dev/null 2>&1
        ;;
    none)
        svc_none_install "$oname" "$logdir"
        ;;
    esac
    return 0
}

svc_none_install() { # $1=服务名 $2=日志目录
    local name=$1 logdir=$2 envsh=""
    [ "$ENV_LOWMEM" = 1 ] && envsh=$(printf 'export GOGC=30\nexport GOMEMLIMIT=48MiB\n')
    cat > "/usr/local/bin/$name-ctl" <<EOF
#!/bin/sh
case "\$1" in
start)
    if [ -f /run/$name.pid ] && kill -0 "\$(cat /run/$name.pid)" 2>/dev/null; then echo "$name 已在运行"; exit 0; fi
    $envsh
    nohup /usr/local/bin/$name-run >> "$logdir/access.log" 2>> "$logdir/error.log" &
    echo \$! > /run/$name.pid
    echo "$name 已启动 (pid \$(cat /run/$name.pid))"
    ;;
stop)
    if [ -f /run/$name.pid ]; then
        __pid=\$(cat /run/$name.pid)
        kill "\$__pid" 2>/dev/null
        __i=0
        while [ \$__i -lt 10 ] && kill -0 "\$__pid" 2>/dev/null; do sleep 0.5; __i=\$((__i+1)); done
        kill -0 "\$__pid" 2>/dev/null && kill -9 "\$__pid" 2>/dev/null
        rm -f /run/$name.pid
    fi
    echo "$name 已停止"
    ;;
restart)
    "\$0" stop; sleep 1; "\$0" start
    ;;
status)
    if [ -f /run/$name.pid ] && kill -0 "\$(cat /run/$name.pid)" 2>/dev/null; then
        echo "$name running (pid \$(cat /run/$name.pid))"
    else
        echo "$name stopped"
    fi
    ;;
*)
    echo "用法: \$0 {start|stop|restart|status}"
    ;;
esac
EOF
    chmod 755 "/usr/local/bin/$name-ctl"
    "/usr/local/bin/$name-ctl" restart
}

svc_restart() {
    case "$ENV_INIT" in
    systemd) systemctl restart "$1" >/dev/null 2>&1 ;;
    openrc)  rc-service "$2" restart >/dev/null 2>&1 ;;
    none)    "/usr/local/bin/$2-ctl" restart >/dev/null 2>&1 ;;
    esac
    return 0
}

svc_state() {
    local out
    case "$ENV_INIT" in
    systemd)
        out=$(systemctl is-active "$1" 2>/dev/null)
        echo "${out:-unknown}"
        ;;
    openrc)
        if rc-service "$2" status >/dev/null 2>&1; then echo "running (openrc)"; else echo "not running (openrc)"; fi
        ;;
    none)
        if [ -f "/run/$2.pid" ] && kill -0 "$(cat /run/$2.pid)" 2>/dev/null; then echo "running (nohup)"; else echo "not running (nohup)"; fi
        ;;
    *)
        echo "unknown"
        ;;
    esac
}

svc_remove() {
    if has systemctl; then
        systemctl stop "$1" >/dev/null 2>&1
        systemctl disable "$1" >/dev/null 2>&1
    fi
    rm -f "/etc/systemd/system/$1.service"
    has systemctl && systemctl daemon-reload >/dev/null 2>&1
    has rc-service && rc-service "$2" stop >/dev/null 2>&1
    has rc-update && rc-update del "$2" default >/dev/null 2>&1
    rm -f "/etc/init.d/$2"
    [ -x "/usr/local/bin/$2-ctl" ] && "/usr/local/bin/$2-ctl" stop >/dev/null 2>&1
    rm -f "/usr/local/bin/$2-ctl" "/usr/local/bin/$2-run" "/run/$2.pid"
    return 0
}

# ============================================================================
# 内核安装（都是从 vendor 走 sha256）
# ============================================================================
install_cloudflared() {
    install_soft curl
    if [ -x "$CF_BIN" ]; then
        echo -e "${green}已存在 cloudflared $( "$CF_BIN" --version 2>/dev/null | head -1)${re}"
        return 0
    fi
    local arch tmp
    arch=$(cf_arch) || { echo -e "${red}错误: 当前架构 $(uname -m) 没有 cloudflared 构建${re}"; return 1; }
    tmp=$(mktemp -d) || return 1
    echo -e "${yellow}正在安装 cloudflared ${VENDOR_CF_TAG} (linux-$arch)，来自本项目 vendor${re}"
    if ! vendor_fetch "cloudflared/cloudflared-linux-$arch" "$tmp/cloudflared"; then
        rm -rf "$tmp"; return 1
    fi
    mkdir -p "$WORK_DIR"
    install -m 755 "$tmp/cloudflared" "$CF_BIN" || { rm -rf "$tmp"; return 1; }
    rm -rf "$tmp"
    if ! "$CF_BIN" --version >/dev/null 2>&1; then
        echo -e "${red}错误: cloudflared 二进制无法在本机运行${re}"
        return 1
    fi
    echo -e "${green}已安装 cloudflared $( "$CF_BIN" --version 2>/dev/null | head -1)${re}"
    return 0
}

install_singbox_core() {
    install_soft curl
    if [ -x "$SB_BIN" ]; then
        echo -e "${green}已存在 sing-box $( "$SB_BIN" version 2>/dev/null | head -1)${re}"
        return 0
    fi
    local arch asset tmp
    arch=$(sb_arch) || { echo -e "${red}错误: 当前架构 $(uname -m) 没有 sing-box 构建${re}"; return 1; }
    asset="sing-box-${VENDOR_SB_TAG}-linux-${arch}.tar.gz"
    tmp=$(mktemp -d) || return 1
    echo -e "${yellow}正在安装 sing-box ${VENDOR_SB_TAG} (linux-$arch)，来自本项目 vendor${re}"
    if ! vendor_fetch "sing-box/$asset" "$tmp/$asset"; then
        rm -rf "$tmp"; return 1
    fi
    if ! tar -xzf "$tmp/$asset" -C "$tmp" 2>/dev/null; then
        echo -e "${red}错误: 解压 sing-box 失败${re}"
        rm -rf "$tmp"; return 1
    fi
    local bin
    bin=$(find "$tmp" -type f -name sing-box | head -1)
    if [ -z "$bin" ]; then
        echo -e "${red}错误: 压缩包里没找到 sing-box 可执行文件${re}"
        rm -rf "$tmp"; return 1
    fi
    mkdir -p "$SB_DIR"
    install -m 755 "$bin" "$SB_BIN" || { rm -rf "$tmp"; return 1; }
    rm -rf "$tmp"
    if ! "$SB_BIN" version >/dev/null 2>&1; then
        echo -e "${red}错误: sing-box 二进制无法在本机运行${re}"
        return 1
    fi
    echo -e "${green}已安装 sing-box $( "$SB_BIN" version 2>/dev/null | head -1)${re}"
    return 0
}

# ============================================================================
# sing-box 配置：vmess + ws 明文（TLS 由 CF 边缘负责）
# ============================================================================
sb_write_config() { # $1=监听端口 $2=uuid $3=ws路径
    local port=$1 uuid=$2 path=$3
    mkdir -p "$SB_DIR"
    cat > "$SB_CFG" <<EOF
{
  "log": { "level": "warn", "timestamp": true },
  "inbounds": [
    {
      "type": "vmess",
      "tag": "vmess-ws-argo",
      "listen": "127.0.0.1",
      "listen_port": $port,
      "users": [ { "uuid": "$uuid" } ],
      "transport": {
        "type": "ws",
        "path": "$path",
        "early_data_header_name": "Sec-WebSocket-Protocol"
      }
    }
  ],
  "outbounds": [
    { "type": "direct", "tag": "direct" }
  ]
}
EOF
    "$SB_BIN" check -c "$SB_CFG" >/dev/null 2>&1
}

# ============================================================================
# 隧道两种模式
# ============================================================================
# 临时隧道：cloudflared 自动分配 *.trycloudflare.com，域名从日志里捞
argo_quick_args() { # $1=local_port
    echo "tunnel --url http://127.0.0.1:$1 --no-autoupdate --edge-ip-version auto --protocol http2"
}

# 固定隧道（token）：CF Zero Trust 里建的隧道，绑自己域名
argo_token_args() { # $1=token
    echo "tunnel --no-autoupdate --edge-ip-version auto --protocol http2 run --token $1"
}

# 固定隧道（凭据 JSON）：写出 tunnel.json + tunnel.yml
argo_write_creds() { # $1=JSON $2=域名 $3=local_port
    local json=$1 domain=$2 port=$3 tid
    mkdir -p "$WORK_DIR"
    printf '%s\n' "$json" > "$TUNNEL_JSON"
    chmod 600 "$TUNNEL_JSON"
    tid=$(printf '%s' "$json" | sed -n 's/.*"TunnelID"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
    cat > "$TUNNEL_YML" <<EOF
tunnel: $tid
credentials-file: $TUNNEL_JSON
protocol: http2
no-autoupdate: true

ingress:
  - hostname: $domain
    service: http://127.0.0.1:$port
    originRequest:
      noTLSVerify: true
  - service: http_status:404
EOF
    [ -n "$tid" ] && return 0 || return 1
}

argo_config_args() {
    echo "tunnel --no-autoupdate --edge-ip-version auto --protocol http2 --config $TUNNEL_YML run"
}

# 从 argo.log 抓 trycloudflare 域名，最多重试 $2 次，每次间隔 2s
argo_grab_domain() { # $1=日志 $2=重试次数(默认10)
    local log=$1 tries=${2:-10} d i
    for ((i = 1; i <= tries; i++)); do
        d=$(sed -n 's|.*https://\([A-Za-z0-9_-]*\.trycloudflare\.com\).*|\1|p' "$log" 2>/dev/null | tail -1)
        if [ -n "$d" ]; then
            printf '%s' "$d"
            return 0
        fi
        sleep 2
    done
    return 1
}

# ============================================================================
# 节点链接（vmess 标准分享格式）
# ============================================================================
# $1=域名 $2=uuid $3=ws路径 $4=CF优选地址 $5=备注
vmess_link() {
    local domain=$1 uuid=$2 path=$3 cfip=$4 ps=$5
    local json b64
    json=$(printf '{"v":"2","ps":"%s","add":"%s","port":"443","id":"%s","aid":"0","scy":"auto","net":"ws","type":"none","host":"%s","path":"%s?ed=2560","tls":"tls","sni":"%s","alpn":"","fp":"firefox"}' \
        "$ps" "$cfip" "$uuid" "$domain" "$path" "$domain")
    # 无换行 base64（busybox/base64 均有 -w0 差异，这里用 tr 兜底）
    if printf '%s' "$json" | base64 -w0 >/dev/null 2>&1; then
        b64=$(printf '%s' "$json" | base64 -w0)
    else
        b64=$(printf '%s' "$json" | base64 | tr -d '\n')
    fi
    printf 'vmess://%s' "$b64"
}

# ============================================================================
# 安装 / 卸载 / 重启
# ============================================================================
CFIP_DEFAULT="cf.877774.xyz"

sb_service_up() {
    svc_install "cf-tunel-singbox" "cf-tunel-singbox" "CF Tunnel VMess-WS" "$SB_BIN run -c $SB_CFG" "/var/log/cf-tunel"
}

argo_service_up() { # $1=模式 quick|token|config  $2 参数
    local mode=$1 args=$2 logarg=""
    case "$mode" in
        quick) logarg=" >> $ARGO_LOG 2>&1" ;;
        *)     logarg=" >> $ARGO_LOG 2>&1" ;;
    esac
    # cloudflared 的日志用重定向到 argo.log，容器/noinit 下也能抓到域名
    svc_install "cf-tunel-argo" "cf-tunel-argo" "CF Tunnel (cloudflared)" "/bin/sh -c '$CF_BIN $args$logarg'" "/var/log/cf-tunel"
}

restart_argo() {
    : > "$ARGO_LOG" 2>/dev/null || true
    svc_restart "cf-tunel-argo" "cf-tunel-argo"
}

install_quick() { # $1=端口(空=随机)
    local port=$1 uuid path domain link cfip ps
    env_detect
    ensure_netstat
    install_cloudflared || return 1
    install_singbox_core || return 1

    if [ -z "$port" ]; then
        port=$(rand_port)
        echo -e "${yellow}未输入端口，已分配随机端口: $port${re}"
    fi
    while ! valid_port "$port" || check_port "$port"; do
        valid_port "$port" || echo -e "${red}端口不合法: $port（需 1-65535 的数字），请重新输入${re}"
        valid_port "$port" && echo -e "${red}${port} 端口已被占用，请更换端口${re}"
        read -rp $'\033[1;35m设置本地监听端口[1-65535]（回车跳过则随机）: \033[0m' port
        [ -z "$port" ] && port=$(rand_port)
    done
    port=$(norm_port "$port")

    # 端口占用了要先停旧服务，否则 sing-box 起不来
    svc_remove "cf-tunel-argo" "cf-tunel-argo"
    svc_remove "cf-tunel-singbox" "cf-tunel-singbox"
    sleep 1

    uuid=$(rand_uuid)
    path="/vmess-$(rand_token)"

    echo -e "${yellow}正在写入 sing-box 配置 (vmess-ws 明文, 127.0.0.1:$port)...${re}"
    if ! sb_write_config "$port" "$uuid" "$path"; then
        echo -e "${red}错误: sing-box 配置校验失败${re}"
        return 1
    fi
    sb_service_up
    sleep 2

    echo -e "${yellow}正在启动临时隧道 (quick tunnel)...${re}"
    : > "$ARGO_LOG"
    argo_service_up quick "$(argo_quick_args "$port")"
    sleep 3

    echo -e "${yellow}正在从日志抓取 trycloudflare 域名...${re}"
    domain=$(argo_grab_domain "$ARGO_LOG" 10)
    if [ -z "$domain" ]; then
        echo -e "${red}错误: 10 次重试仍未从 $ARGO_LOG 抓到域名${re}"
        echo -e "${yellow}日志尾部：${re}"
        tail -20 "$ARGO_LOG" 2>/dev/null
        return 1
    fi
    echo -e "${green}隧道域名: $domain${re}"

    link=$(vmess_link "$domain" "$uuid" "$path" "$CFIP_DEFAULT" "CF-Quick")
    mkdir -p "$NODE_DIR"
    printf '%s\n' "$link" > "$NODE_DIR/quick.txt"
    printf 'MODE=quick\nPORT=%s\nUUID=%s\nPATH=%s\nDOMAIN=%s\n' "$port" "$uuid" "$path" "$domain" > "$NODE_DIR/quick.env"

    echo -e "${green}---------------------------------------------------------${re}"
    echo -e "${green}临时隧道节点已就绪${re}"
    echo -e "${white}隧道域名 : ${re}$domain"
    echo -e "${white}本地端口 : ${re}127.0.0.1:$port (vmess-ws 明文)"
    echo -e "${white}WS 路径  : ${re}$path"
    echo -e "${white}UUID     : ${re}$uuid"
    echo -e "${white}节点链接 : ${re}"
    echo -e "${skyblue}$link${re}"
    echo -e "${yellow}注意: trycloudflare 域名重启即变，重启后请重新获取节点。${re}"
}

install_fixed() { # $1=端口 $2=域名 $3=凭据(token 或 JSON)
    local port=$1 domain=$2 cred=$3 uuid path link cfip mode
    env_detect
    ensure_netstat
    install_cloudflared || return 1
    install_singbox_core || return 1

    if [ -z "$port" ]; then
        port=$(rand_port)
        echo -e "${yellow}未输入端口，已分配随机端口: $port${re}"
    fi
    while ! valid_port "$port" || check_port "$port"; do
        valid_port "$port" || echo -e "${red}端口不合法: $port（需 1-65535 的数字），请重新输入${re}"
        valid_port "$port" && echo -e "${red}${port} 端口已被占用，请更换端口${re}"
        read -rp $'\033[1;35m设置本地监听端口[1-65535]（回车跳过则随机）: \033[0m' port
        [ -z "$port" ] && port=$(rand_port)
    done
    port=$(norm_port "$port")

    # 判断凭据形态：JSON(含 TunnelSecret) / token / config
    if [ -z "$cred" ]; then
        echo -e "${red}错误: 固定隧道需要凭据（token 或 tunnel JSON）${re}"
        return 1
    fi
    if printf '%s' "$cred" | grep -q 'TunnelSecret'; then
        mode="config"
        if ! argo_write_creds "$cred" "$domain" "$port"; then
            echo -e "${red}错误: 无法从 JSON 里解析 TunnelID${re}"
            return 1
        fi
    else
        mode="token"
        if [ -z "$domain" ]; then
            echo -e "${red}错误: token 模式必须提供你绑定的域名（用于生成节点 host/sni）${re}"
            return 1
        fi
    fi

    svc_remove "cf-tunel-argo" "cf-tunel-argo"
    svc_remove "cf-tunel-singbox" "cf-tunel-singbox"
    sleep 1

    uuid=$(rand_uuid)
    path="/vmess-$(rand_token)"

    if ! sb_write_config "$port" "$uuid" "$path"; then
        echo -e "${red}错误: sing-box 配置校验失败${re}"
        return 1
    fi
    sb_service_up
    sleep 2

    : > "$ARGO_LOG"
    if [ "$mode" = "config" ]; then
        argo_service_up config "$(argo_config_args)"
    else
        argo_service_up token "$(argo_token_args "$cred")"
    fi
    sleep 3

    link=$(vmess_link "$domain" "$uuid" "$path" "$CFIP_DEFAULT" "CF-Fixed")
    mkdir -p "$NODE_DIR"
    printf '%s\n' "$link" > "$NODE_DIR/fixed.txt"
    printf 'MODE=fixed\nPORT=%s\nUUID=%s\nPATH=%s\nDOMAIN=%s\n' "$port" "$uuid" "$path" "$domain" > "$NODE_DIR/fixed.env"

    echo -e "${green}---------------------------------------------------------${re}"
    echo -e "${green}固定隧道节点已就绪${re}"
    echo -e "${white}隧道域名 : ${re}$domain"
    echo -e "${white}本地端口 : ${re}127.0.0.1:$port (vmess-ws 明文)"
    echo -e "${white}WS 路径  : ${re}$path"
    echo -e "${white}UUID     : ${re}$uuid"
    echo -e "${white}service  : ${re}$(svc_state cf-tunel-argo cf-tunel-argo)"
    echo -e "${white}节点链接 : ${re}"
    echo -e "${skyblue}$link${re}"
}

restart_quick() {
    local envf="$NODE_DIR/quick.env" port
    if [ ! -f "$envf" ]; then
        echo -e "${red}错误: 没找到临时隧道配置，请先安装${re}"
        return 1
    fi
    port=$(sed -n 's/^PORT=//p' "$envf")
    echo -e "${yellow}正在重启临时隧道（域名会变）...${re}"
    : > "$ARGO_LOG"
    svc_restart "cf-tunel-argo" "cf-tunel-argo"
    local domain uuid path link
    domain=$(argo_grab_domain "$ARGO_LOG" 10)
    if [ -z "$domain" ]; then
        echo -e "${red}错误: 未能抓到新域名，请看 $ARGO_LOG${re}"
        return 1
    fi
    uuid=$(sed -n 's/^UUID=//p' "$envf")
    path=$(sed -n 's/^PATH=//p' "$envf")
    link=$(vmess_link "$domain" "$uuid" "$path" "$CFIP_DEFAULT" "CF-Quick")
    printf '%s\n' "$link" > "$NODE_DIR/quick.txt"
    sed -i "s|^DOMAIN=.*|DOMAIN=$domain|" "$envf"
    echo -e "${green}新域名: $domain${re}"
    echo -e "${white}节点链接: ${re}"
    echo -e "${skyblue}$link${re}"
}

show_node() {
    local f=""
    [ -f "$NODE_DIR/fixed.txt" ] && f="$NODE_DIR/fixed.txt"
    [ -f "$NODE_DIR/quick.txt" ] && f="$NODE_DIR/quick.txt"
    if [ -z "$f" ]; then
        echo -e "${yellow}尚未安装任何节点${re}"
        return 0
    fi
    echo -e "${white}sing-box : ${re}$(svc_state cf-tunel-singbox cf-tunel-singbox)"
    echo -e "${white}argo     : ${re}$(svc_state cf-tunel-argo cf-tunel-argo)"
    echo -e "${white}节点链接 : ${re}"
    cat "$f"
}

uninstall_all() {
    env_detect
    svc_remove "cf-tunel-argo" "cf-tunel-argo"
    svc_remove "cf-tunel-singbox" "cf-tunel-singbox"
    rm -rf "$WORK_DIR"
    echo -e "${green}已卸载 cf-tunel（sing-box + cloudflared + 配置 + 节点文件）${re}"
}

# ============================================================================
# 主菜单
# ============================================================================
main_menu() {
    while true; do
        cd ~ || exit 1
        clear_screen
        echo -e "${purple}▶ CF 隧道节点 (vmess-ws + cloudflared)${re}"
        echo -e "${green}---------------------------------------------------------${re}"
        echo -e "${white} 1. 安装临时隧道 (quick tunnel, trycloudflare 域名)${re}"
        echo -e "${white} 2. 安装固定隧道 (token / 凭据 JSON, 绑定自己域名)${re}"
        echo -e "${white} 3. 重启临时隧道并更新域名${re}"
        echo -e "${white} 4. 查看节点 / 服务状态${re}"
        echo -e "${white} 5. 卸载${re}"
        echo -e "${yellow}---------------------------------------------------------${re}"
        echo -e "$(env_line)"
        echo -e "${skyblue} 0. 退出脚本${re}"
        echo "---------------"
        read -rp $'\033[1;91m请输入你的选择: \033[0m' c
        case $c in
            1)
                read -rp $'\033[1;35m本地监听端口(回车跳过则随机): \033[0m' p
                install_quick "$p"
                press_any_key_to_continue
                ;;
            2)
                read -rp $'\033[1;35m绑定域名 (如 node.example.com): \033[0m' d
                echo -e "${yellow}凭据二选一：① 隧道 token 串  ② Zero Trust 下载的 tunnel JSON 全文${re}"
                read -rp $'\033[1;35m粘贴凭据: \033[0m' cred
                read -rp $'\033[1;35m本地监听端口(回车跳过则随机): \033[0m' p
                install_fixed "$p" "$d" "$cred"
                press_any_key_to_continue
                ;;
            3)
                restart_quick
                press_any_key_to_continue
                ;;
            4)
                show_node
                press_any_key_to_continue
                ;;
            5)
                read -rp $'\033[1;91m确认卸载? (y/N): \033[0m' yn
                case "$yn" in [Yy]*) uninstall_all ;; esac
                press_any_key_to_continue
                ;;
            0)
                echo "退出脚本。"
                exit 0
                ;;
            *)
                echo -e "${red}无效的输入!${re}"
                sleep 1
                ;;
        esac
    done
}

env_detect
main_menu
