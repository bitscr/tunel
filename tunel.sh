#!/bin/sh
# shellcheck shell=bash
# mkdir 的系统父目录不能统一 chmod；私有工作目录另行显式 chmod 700。
# shellcheck disable=SC2174
# ============================================================================
# 极端环境保护：Alpine / minimal 系统默认没有 bash。
# 用 sh 直接跑（sh <脚本名>）时先自举安装 bash，再切回 bash 重新执行自己。
# ============================================================================
if [ -z "$BASH_VERSION" ]; then
    if ! command -v bash > /dev/null 2>&1; then
        # 用户与便携安装不能借自举写系统，缺少 bash 时交由管理员或镜像准备。
        if [ "$(id -u 2>/dev/null)" != 0 ] || [ -n "${TUNEL_HOME:-}" ]; then
            echo "错误: 用户/便携模式需要预装 bash；不会调用系统包管理器。请安装 bash 后重试。" >&2
            exit 3
        fi
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
    echo "错误: 本脚本需要 bash。用法: bash tunel.sh ... 或 curl -fsSL <url> | bash -s -- ..." >&2
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
TUNEL_VERSION="2.0.0"
DEFAULT_CHECK_INTERVAL=7200
LOCATION_MEMORY_ATTEMPT_TS=0
VENDOR_CF_TAG="2026.10.7"
VENDOR_SB_TAG="1.14.4"
VENDOR_REPO="${VENDOR_REPO:-bitscr/tunel}"
VENDOR_REF="${VENDOR_REF:-main}"
VENDOR_RAW_BASE="https://raw.githubusercontent.com/$VENDOR_REPO/$VENDOR_REF"

# 内置校验清单：仓库 SHA256SUMS 取不到时兜底，改版本时务必与 vendor/SHA256SUMS 一起更新
BUILTIN_SUMS="
4823d2f038395617e04e4070601ab45c0c43f31f15ee7586be299e19ef49d46e  vendor/cloudflared/cloudflared-linux-386
1f99fb518b83dec2ba8d870a7cc991d82a77e6196295a3d2754ba17ab9f91872  vendor/cloudflared/cloudflared-linux-amd64
74f690f6707182839b63e0465726c7776dd63f0a174390b911d5d71f35cab94e  vendor/cloudflared/cloudflared-linux-arm
3df43aedc9ff291d1735b5cb576cb97e0b157488796db2e32b28aecabb445775  vendor/cloudflared/cloudflared-linux-arm64
efb46daaa48ee55e090bd1dfcaee34bfbe9bdbd9b89fa9f328d25f81a619e865  vendor/sing-box/sing-box-1.14.4-linux-386.tar.gz
8f7c5f0651238850d96a0e488e5473cd77ec1a0098f63942e943f475a12057ca  vendor/sing-box/sing-box-1.14.4-linux-amd64.tar.gz
b95e25f921dc5e17a4cf13327243d1177642c7e35425bf5372862c477c359f56  vendor/sing-box/sing-box-1.14.4-linux-arm64.tar.gz
fd164ed45ebc784f657a3e1d0e0ad0f68afdcff864ee57122c2cfed3ddb80a00  vendor/sing-box/sing-box-1.14.4-linux-armv7.tar.gz
"

# 默认 root 安装保留旧路径；安装前的权限兜底可重算同一组派生路径。
setup_paths() {
    local __tunel_anchor __tunel_suffix __tunel_physical __tunel_user_home
    TUNEL_SYSTEM=1
    TUNEL_PATH_ERROR=""
    if [ "$EUID" != 0 ] || [ -n "${TUNEL_HOME:-}" ]; then
        TUNEL_SYSTEM=0
        if [ -z "${TUNEL_HOME:-}" ] && [ -z "${HOME:-}" ]; then
            TUNEL_PATH_ERROR="用户模式未设置 HOME，请显式设置专用的绝对路径 TUNEL_HOME。"
        fi
        TUNEL_HOME=${TUNEL_HOME:-${HOME:-}/.local/share/tunel}
        TUNEL_HOME=${TUNEL_HOME%/}
        # 包装脚本与 ingress 都需引用目录，明确拒绝不能安全贯穿所有后端的格式。
        if [[ ! "$TUNEL_HOME" =~ ^/[A-Za-z0-9._/-]+$ ]] || [[ "/$TUNEL_HOME/" == *'/../'* || "/$TUNEL_HOME/" == *'/./'* ]]; then
            TUNEL_PATH_ERROR="TUNEL_HOME 必须是无空格、引号和 shell 特殊字符的绝对路径，且不能包含 . 或 .. 段: $TUNEL_HOME"
        else
            # 解析已存在的父目录，防止符号链接把便携树指向用户 home 或系统根。
            __tunel_anchor=$TUNEL_HOME; __tunel_suffix=""
            while [ ! -d "$__tunel_anchor" ] && [ "$__tunel_anchor" != / ]; do
                if [ -e "$__tunel_anchor" ] || [ -L "$__tunel_anchor" ]; then
                    TUNEL_PATH_ERROR="TUNEL_HOME 的路径不是目录: $__tunel_anchor"; break
                fi
                __tunel_suffix="/${__tunel_anchor##*/}$__tunel_suffix"
                __tunel_anchor=${__tunel_anchor%/*}; __tunel_anchor=${__tunel_anchor:-/}
            done
            if [ -z "$TUNEL_PATH_ERROR" ]; then
                __tunel_physical=$(cd "$__tunel_anchor" 2>/dev/null && pwd -P)
                if [ -z "$__tunel_physical" ]; then
                    TUNEL_PATH_ERROR="无法访问 TUNEL_HOME 的父目录: $__tunel_anchor"
                else
                    TUNEL_HOME="${__tunel_physical%/}$__tunel_suffix"
                    __tunel_user_home=$(cd "${HOME:-/nonexistent}" 2>/dev/null && pwd -P)
                    case "$TUNEL_HOME" in
                        /|/etc|/usr|/usr/local|/var|/var/log|/run|/home|/root|/bin|/sbin|/lib|/lib64|/boot|/dev|/proc|/sys|/tmp|/opt|/mnt|/media)
                            TUNEL_PATH_ERROR="TUNEL_HOME 不能使用受保护的系统目录: $TUNEL_HOME" ;;
                    esac
                    if [ -n "$__tunel_user_home" ] && [ "$TUNEL_HOME" = "$__tunel_user_home" ]; then
                        TUNEL_PATH_ERROR="TUNEL_HOME 不能是用户 home 本身，请使用其下专用目录: $TUNEL_HOME"
                    fi
                    [[ "$TUNEL_HOME" =~ ^/[A-Za-z0-9._/-]+$ ]] || TUNEL_PATH_ERROR="TUNEL_HOME 解析后的目录包含不支持的字符: $TUNEL_HOME"
                fi
            fi
        fi
        # 导出规范化目录，让 self、ctl、守护及重启始终定位同一套安装。
        export TUNEL_HOME
        WORK_DIR="$TUNEL_HOME/work"; BIN_DIR="$TUNEL_HOME/bin"
        LOG_DIR="$TUNEL_HOME/log"; RUN_DIR="$TUNEL_HOME/run"
    else
        WORK_DIR="/etc/cf-tunel"; BIN_DIR="/usr/local/bin"
        LOG_DIR="/var/log/cf-tunel"; RUN_DIR="/run"
    fi
    SB_DIR="$WORK_DIR/sing-box"
    SB_BIN="$SB_DIR/sing-box"
    SB_CFG="$SB_DIR/config.json"
    CF_BIN="$WORK_DIR/cloudflared"
    ARGO_LOG="$WORK_DIR/argo.log"
    TUNNEL_YML="$WORK_DIR/tunnel.yml"
    TUNNEL_JSON="$WORK_DIR/tunnel.json"
    NODE_DIR="$WORK_DIR/nodes"
    TMP_DIR="$WORK_DIR/tmp"
    ARGO_TOKEN_FILE="$WORK_DIR/argo.token"
    AGENT_ENV="$WORK_DIR/agent.env"
    AGENT_STATE="$WORK_DIR/agent.state"
    AGENT_LOG="$WORK_DIR/agent.log"
    AGENT_LOCK="$RUN_DIR/cf-tunel-agent.lock"
    SELF_INSTALL="$BIN_DIR/tunel"
    SELF_SCRIPT="$WORK_DIR/tunel.sh"
}

# 只读检查目录或最近已有父目录，不用创建临时文件探测系统权限。
path_write_preflight() {
    local probe=$1
    TUNEL_PREFLIGHT_REASON=""
    while [ ! -d "$probe" ] && [ "$probe" != / ]; do
        if [ -e "$probe" ] || [ -L "$probe" ]; then
            TUNEL_PREFLIGHT_REASON="$probe 不是可用目录"; return 1
        fi
        probe=${probe%/*}; probe=${probe:-/}
    done
    if [ ! -d "$probe" ] || [ ! -w "$probe" ] || [ ! -x "$probe" ]; then
        TUNEL_PREFLIGHT_REASON="$probe 不可写或无法访问"; return 1
    fi
    return 0
}

# 仅默认系统安装自动选用户目录，其他命令与显式 TUNEL_HOME 保持原安装归属。
install_paths_preflight() {
    local path reason="" rc=0
    case "$COMMAND" in
        quick|fixed) : ;;
        menu) [ "${1:-}" = menu-install ] || return 0 ;;
        *) return 0 ;;
    esac
    [ "$TUNEL_SYSTEM" = 1 ] && [ "$EUID" = 0 ] || return 0
    for path in "$WORK_DIR" "$BIN_DIR" "$LOG_DIR" "$RUN_DIR"; do
        if ! path_write_preflight "$path"; then reason=$TUNEL_PREFLIGHT_REASON; break; fi
    done
    [ -n "$reason" ] || return 0
    if [ -z "${HOME:-}" ] || [[ "$HOME" != /* ]] || [ ! -d "$HOME" ] || [ ! -x "$HOME" ]; then
        echo "错误: 系统安装目录不可用（$reason），且 HOME 未设置为可访问的绝对目录；请显式设置可写的 TUNEL_HOME。" >&2
        return 1
    fi
    TUNEL_HOME="${HOME%/}/.local/share/tunel"
    setup_paths
    if [ -n "$TUNEL_PATH_ERROR" ]; then
        echo "错误: 无法自动选择用户目录: $TUNEL_PATH_ERROR" >&2; rc=2
    elif ! portable_paths_valid; then
        rc=2
    else
        for path in "$TUNEL_HOME" "$WORK_DIR" "$BIN_DIR" "$LOG_DIR" "$RUN_DIR" "$SB_DIR" "$NODE_DIR" "$TMP_DIR"; do
            if ! path_write_preflight "$path"; then
                echo "错误: 系统安装目录不可用（$reason），HOME 下的便携目录也不可用: $TUNEL_PREFLIGHT_REASON；请显式设置可写的 TUNEL_HOME。" >&2
                rc=1; break
            fi
        done
    fi
    # 候选目录失败时保留菜单原归属，后续查看或卸载仍指向旧系统安装。
    if [ "$rc" != 0 ]; then unset TUNEL_HOME; setup_paths; return "$rc"; fi
    echo "提示: 系统安装目录不可用（$reason），已自动选择便携安装目录 TUNEL_HOME=$TUNEL_HOME（工作目录 $WORK_DIR）。" >&2
}

setup_paths
SVC_SB="cf-tunel-singbox"
SVC_ARGO="cf-tunel-argo"
SVC_AGENT="cf-tunel-agent"
NONINTERACTIVE=""

# --- 颜色定义 ---
red='\033[0;31m'
green='\033[0;32m'
yellow='\033[0;33m'
skyblue='\033[0;36m'
re='\033[0m'

# ============================================================================
# 基础工具
# ============================================================================
# 按当前 PATH 检测依赖，避免把固定发行版路径写死。
has() { command -v "$1" > /dev/null 2>&1; }

# 私有树集中建目录，权限错误始终指出真实目标，不回退到系统路径。
runtime_dirs_ensure() {
    [ -z "$TUNEL_PATH_ERROR" ] || { echo "错误: $TUNEL_PATH_ERROR" >&2; return 2; }
    umask 077
    if [ "$TUNEL_SYSTEM" = 1 ]; then
        # /usr/local/bin 与 /run 为系统共享目录，不能改成只有本工具可访问。
        [ "$EUID" = 0 ] || { echo "错误: 系统安装需要 root；普通用户请设置 TUNEL_HOME。" >&2; return 1; }
        mkdir -p "$BIN_DIR" "$RUN_DIR" || { echo "错误: 无法写入系统目录 $BIN_DIR / $RUN_DIR" >&2; return 1; }
    else
        # 便携模式只在指定树内建目录，不安装系统服务或开机钩子。
        portable_paths_valid || return 2
        mkdir -p -m 700 "$TUNEL_HOME" "$BIN_DIR" "$RUN_DIR" || { echo "错误: 无法写入 TUNEL_HOME=$TUNEL_HOME" >&2; return 1; }
        chmod 700 "$TUNEL_HOME" "$BIN_DIR" "$RUN_DIR" || return 1
    fi
    if [ -L "$TMP_DIR" ] || { [ -e "$TMP_DIR" ] && [ ! -d "$TMP_DIR" ]; }; then
        echo "错误: 安装临时目录必须是私有普通目录: $TMP_DIR" >&2; return 1
    fi
    mkdir -p -m 700 "$WORK_DIR" "$SB_DIR" "$NODE_DIR" "$LOG_DIR" "$TMP_DIR" || { echo "错误: 无法写入工作/日志/临时目录 $WORK_DIR / $LOG_DIR / $TMP_DIR" >&2; return 1; }
    chmod 700 "$WORK_DIR" "$SB_DIR" "$NODE_DIR" "$LOG_DIR" "$TMP_DIR" || return 1
    # 系统和便携安装均优先使用自己的临时目录，不占共享 /tmp。
    export TMPDIR="$TMP_DIR"
}

# 专用子目录不能通过符号链接越过便携树，尤其不能 chmod 或卸载外部目录。
portable_paths_valid() {
    local dir
    [ "$TUNEL_SYSTEM" != 1 ] || return 0
    for dir in "$WORK_DIR" "$BIN_DIR" "$LOG_DIR" "$RUN_DIR" "$SB_DIR" "$NODE_DIR" "$TMP_DIR"; do
        if [ -L "$dir" ] || { [ -e "$dir" ] && [ ! -d "$dir" ]; }; then
            echo "错误: 便携安装目录必须是树内的普通目录，不能是符号链接或文件: $dir" >&2
            return 2
        fi
    done
}

# 只补缺少的依赖，让已准备好的 VPS 安装无需反复访问包仓库。
install_soft() { # $1..=包名
    local pkg rc
    for pkg in "$@"; do
        has "$pkg" && continue
        if [ "$TUNEL_SYSTEM" != 1 ] || [ "$EUID" != 0 ]; then
            # 包管理器属于系统管理，普通用户和便携模式都只提示所缺依赖。
            echo "错误: 用户/便携模式缺少依赖 $pkg，请预装后重试；不会调用系统包管理器。" >&2
            return 3
        fi
        if has apk; then
            # Alpine 使用本机 apk，保持 minimal 环境可自举。
            apk add --no-cache "$pkg" > /dev/null 2>&1
        elif has apt-get; then
            # Debian 系列关闭包安装交互，避免管道命令卡住。
            DEBIAN_FRONTEND=noninteractive apt-get install -y "$pkg" > /dev/null 2>&1 || {
                # slim 镜像常清空 apt 索引，仅在首次安装失败时更新并重试一次。
                apt-get update > /dev/null 2>&1 && DEBIAN_FRONTEND=noninteractive apt-get install -y "$pkg" > /dev/null 2>&1
            }
        elif has dnf; then
            # 新版 RPM 发行版优先使用 dnf。
            dnf install -y "$pkg" > /dev/null 2>&1
        elif has yum; then
            # 旧版 RPM 发行版保留 yum 兼容。
            yum install -y "$pkg" > /dev/null 2>&1
        else
            echo "错误: 缺少依赖 $pkg 且没有可用系统包管理器，请预装后重试。" >&2
            return 3
        fi
        rc=$?
        [ "$rc" = 0 ] || { echo "错误: 安装依赖包 $pkg 失败，请预装后重试。" >&2; return 3; }
    done
}

# 环境探测：init 系统 + 内存/磁盘
ENV_INIT="none"
ENV_LOWMEM=0
ENV_MEMORY_MB=""
env_detect() {
    local pid1
    pid1=$(cat /proc/1/comm 2>/dev/null)
    if [ "$TUNEL_SYSTEM" != 1 ]; then
        # 用户与便携安装不注册系统服务，即使宿主有 init 命令也走进程模式。
        ENV_INIT="none"
    elif [ "$pid1" = systemd ] && has systemctl && systemctl show --property=Version --value >/dev/null 2>&1; then
        # 必须确实由 PID1 systemd 管理且总线可用，容器里仅有命令不算。
        ENV_INIT="systemd"
    elif { [ "$pid1" = init ] || [ "$pid1" = openrc-init ]; } && [ -s /run/openrc/softlevel ] && has rc-service && has rc-update && has rc-status && rc-status --runlevel >/dev/null 2>&1; then
        # OpenRC 还需实际运行级标记，避免把镜像中预装工具当作正在运行的 init。
        ENV_INIT="openrc"
    else
        # 无 init 环境交由 ctl 与启动钩子管理。
        ENV_INIT="none"
    fi
    local mem file bytes limit
    mem=$(awk '/MemTotal/{printf "%d", $2/1024}' /proc/meminfo 2>/dev/null)
    # 容器的 /proc/meminfo 可能展示宿主内存，取 cgroup 限额与宿主值中较小者。
    for file in /sys/fs/cgroup/memory.max /sys/fs/cgroup/memory/memory.limit_in_bytes /sys/fs/cgroup/memory.limit_in_bytes; do
        [ -r "$file" ] || continue
        bytes=$(cat "$file" 2>/dev/null)
        # max 与 v1 的巨大无限值不参与计算，限定长度也避免 shell 整数溢出。
        [[ "$bytes" =~ ^[0-9]{1,18}$ ]] || continue
        [ "$((10#$bytes))" -gt 0 ] || continue
        limit=$((10#$bytes/1048576)); [ "$limit" -gt 0 ] || limit=1
        if [ -z "$mem" ] || [ "$limit" -lt "$mem" ]; then mem=$limit; fi
    done
    ENV_MEMORY_MB=$mem; ENV_LOWMEM=0
    [ -n "$mem" ] && [ "$mem" -lt 400 ] && ENV_LOWMEM=1
    return 0
}

# 菜单展示资源与 init 信息，便于选择适合 VPS 的运行方式。
env_line() {
    echo -e "${skyblue}系统: $(uname -m) | 有效内存: ${ENV_MEMORY_MB:-?}MB | init: $ENV_INIT${re}"
}

# 非终端输出保留完整日志，避免清屏字符干扰自动化。
clear_screen() {
    if [ -n "$TERM" ] && [ -t 1 ]; then
        clear 2>/dev/null || true
    fi
}

# 菜单才等待用户继续，非交互路径立即返回。
press_any_key_to_continue() {
    echo -e "${skyblue}---------------------------------------------------------${re}"
    if [ ! -t 0 ] || [ -n "$NONINTERACTIVE" ]; then
        return 0
    fi
    ask "按回车返回上一级菜单..." "" >/dev/null
    echo ""
}

# --- 端口工具 ---
# 先限制数字和长度，再做十进制运算，避免八进制与超大数字溢出。
valid_port() {
    local p=$1
    case "$p" in
        ''|*[!0-9]*) return 1 ;;
    esac
    [ "${#p}" -le 5 ] || return 1
    p=$((10#$p))
    [ "$p" -ge 1 ] && [ "$p" -le 65535 ]
}

# 接受用户的前导零，但写入配置时始终使用普通十进制端口。
norm_port() {
    local p=$1
    case "$p" in
        ''|*[!0-9]*) printf '%s' "$p"; return 1 ;;
    esac
    printf '%d' "$((10#$p))"
}

# 随机端口只给候选值，是否空闲统一由 pick_free_port 再检查。
rand_port() {
    if has shuf; then
        shuf -i 2000-65000 -n 1
    else
        # 每次从内核随机源取值，避免同一秒多次 srand 总选到相同占用端口。
        local seed
        seed=$(od -An -tu2 -N2 /dev/urandom | tr -d ' ')
        printf '%s\n' "$((2000+seed%63001))"
    fi
}

# 工具缺失时直接读 proc，BusyBox grep 不使用不稳定的单词边界。
check_port() { # 返回 0 = 被占用
    local port=$1 hex
    if has netstat; then
        # netstat 在旧 VPS 更常见，先使用已有工具。
        netstat -tuln 2>/dev/null | grep -qE "[:.]$port([^0-9]|$)" && return 0
        return 1
    fi
    if has ss; then
        # 新版发行版通常仅提供 iproute2 的 ss。
        ss -tuln 2>/dev/null | grep -qE "[:.]$port([^0-9]|$)" && return 0
        return 1
    fi
    hex=$(printf '%04X' "$port")
    awk -v h="$hex" 'NR>1 { n=split($2,a,":"); if (a[n]==h) { f=1; exit } } END { exit !f }' \
        /proc/net/tcp /proc/net/tcp6 /proc/net/udp /proc/net/udp6 2>/dev/null
}

# 保留已核实的 shell 优先级写法，只在两个工具都没有时补依赖。
ensure_netstat() {
    has netstat || has ss && return 0
    [ ! -r /proc/net/tcp ] || [ ! -r /proc/net/udp ] || return 0
    install_soft net-tools
}

# 显式端口必须兑现；随机端口最多尝试五十次，避免无限循环。
pick_free_port() {
    local pref=${1:-} p i
    if [ -n "$pref" ]; then
        # 显式端口不能悄悄换掉，让调用者用约定的退出码解释冲突。
        valid_port "$pref" && ! check_port "$(norm_port "$pref")" || return 1
        norm_port "$pref"
        return 0
    fi
    for ((i = 0; i < 50; i++)); do
        p=$(rand_port)
        if ! check_port "$p"; then
            printf '%s' "$p"
            return 0
        fi
    done
    # 不返回未经检查的端口，否则随机选择也可能安装出无法启动的节点。
    return 1
}

# --- 随机值：不依赖 openssl / shuf ---
# 优先让内核生成 UUID，minimal 系统也有不依赖 openssl 的兜底。
rand_uuid() {
    if [ -r /proc/sys/kernel/random/uuid ]; then
        cat /proc/sys/kernel/random/uuid
        return
    fi
    local h
    h=$(od -An -tx1 -N16 /dev/urandom 2>/dev/null | tr -d ' \n')
    # urandom 兜底也必须生成 36 字符 UUID，并设置 v4 及 RFC variant。
    printf '%s-%s-4%s-a%s-%s\n' "${h:0:8}" "${h:8:4}" "${h:13:3}" "${h:17:3}" "${h:20:12}"
}

# 路径随机段从内核随机源产生，避免不同安装共享固定 WS 路径。
rand_token() {
    od -An -tx1 -N8 /dev/urandom 2>/dev/null | tr -d ' \n' | cut -c1-12
}

# --- 下载与校验 ---
# 使用有限超时下载，并让 HTTP 错误传播给强校验安装步骤。
http_fetch() { # $1=url $2=输出文件
    [ "${STOP:-0}" != 1 ] || return 1
    local __tunel_fetch_limit=${3:-134217728}
    if has curl; then
        # curl 能显式拒绝 HTTP 4xx/5xx，并控制连接与整次下载时间。
        if [ "${RUN_ACTIVE:-0}" = 1 ]; then
            curl -fsSL --retry 3 --retry-delay 2 --connect-timeout 15 --max-time 600 --max-filesize "$__tunel_fetch_limit" -o "$2" "$1" 7>&- 9>&- &
        else
            curl -fsSL --retry 3 --retry-delay 2 --connect-timeout 15 --max-time 600 --max-filesize "$__tunel_fetch_limit" -o "$2" "$1" 9>&-
            return $?
        fi
    elif has wget; then
        # 保留只有 wget 的 minimal 系统下载兼容。
        if [ "${RUN_ACTIVE:-0}" = 1 ]; then wget -q -T 30 -t 3 -O "$2" "$1" 7>&- 9>&- &
        else wget -q -T 30 -t 3 -O "$2" "$1" 9>&-; return $?; fi
    else
        # 不假装下载成功，调用者会返回依赖失败退出码。
        echo -e "${red}错误: 本机没有 curl 也没有 wget，无法下载${re}" >&2
        echo -e "${yellow}请先安装其一（Alpine: apk add curl / Debian: apt-get install -y curl）${re}" >&2
        return 127
    fi
    # 前台下载使用可中断的 wait，TERM 不必等完最长 600 秒的同步下载。
    local fetch_pid=$! rc
    RUN_FETCH_PID=$fetch_pid; RUN_FETCH_START=$(proc_start_time "$fetch_pid")
    if [ "${STOP:-0}" != 1 ]; then wait "$fetch_pid"; rc=$?; else rc=1; fi
    if [ "${STOP:-0}" = 1 ]; then
        run_request_stop
        wait "$fetch_pid" 2>/dev/null || true
        rc=1
    fi
    RUN_FETCH_PID=""; RUN_FETCH_START=""
    return "$rc"
}

VENDOR_SUMS=""
# 清单优先本仓库，其次远端，最后内置，仍然始终要求文件哈希相符。
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
        if http_fetch "$VENDOR_RAW_BASE/vendor/SHA256SUMS" "$f" 16384; then
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

# 按精确资产路径查哈希，不能用相似文件或架构的哈希放行。
vendor_expect_sha() { # $1=vendor 内相对路径
    vendor_sums_load || return 1
    printf '%s\n' "$VENDOR_SUMS" | awk -v p="vendor/$1" '$2==p {print $1; exit}'
}

# 两种校验工具任选其一，没有校验能力时拒绝二进制安装。
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
        echo "错误: 从 $VENDOR_RAW_BASE 下载 $rel 失败（HTTP 非 200 或内容为空），请检查 URL 与网络" >&2
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
# 两个项目的 ARM 资产命名不同，分别映射而不猜测下载文件名。
cf_arch() { # cloudflared 资产名后缀
    case "$(uname -m)" in
        x86_64|amd64)      echo "amd64" ;;
        aarch64|arm64)     echo "arm64" ;;
        armv7l|armv8l|arm) echo "arm" ;;
        i386|i686)         echo "386" ;;
        *)                 return 1 ;;
    esac
}

# sing-box 的 ARMv7 资产使用 armv7 后缀，避免与 cloudflared 混用。
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
# 内核安装（都是从 vendor 走 sha256）
# ============================================================================
# 只清理本安装生成、超过一天的核心暂存目录；活跃下载最多十分钟一轮。
core_tmp_cleanup() {
    [ -d "$TMP_DIR" ] && [ ! -L "$TMP_DIR" ] || return 0
    find "$TMP_DIR" -mindepth 1 -maxdepth 1 -type d -name 'core-download.??????' -mtime +0 -exec rm -rf {} \; 2>/dev/null
}

# 固化核心下载和解压需要空间，安装前检查可用容量，避免写满已有系统。
core_disk_preflight() {
    local available
    core_tmp_cleanup || true
    available=$(df -Pk "$TMP_DIR" 2>/dev/null | awk 'NR==2 {print $4}')
    if [[ ! "$available" =~ ^[0-9]+$ ]]; then
        echo "错误: 无法读取安装临时目录的剩余空间: $TMP_DIR" >&2; return 3
    fi
    if [ "$available" -lt 131072 ]; then
        echo "错误: 核心安装至少需要 128MiB 可用磁盘空间，$TMP_DIR 当前剩余 $((available/1024))MiB；请释放空间后重试。" >&2
        return 3
    fi
    return 0
}

# 版本命令必须成功且返回内容，不能把空版本或不可运行的文件当作已安装。
core_version_read() {
    local bin=$1 argument=$2 output rc
    CORE_VERSION_TEXT=""; CORE_VERSION_ERROR=""
    if output=$("$bin" "$argument" 2>&1); then rc=0; else rc=$?; fi
    if [ "$rc" != 0 ] || [ -z "$output" ]; then
        CORE_VERSION_ERROR="版本命令退出码 $rc；架构 $(uname -m)"
        [ -z "$output" ] || CORE_VERSION_ERROR+=$'\n'"$output"
        [ -n "$output" ] || CORE_VERSION_ERROR+=$'\n'"未返回版本信息。"
        if [ "$rc" = 127 ] && [ -f "$bin" ] && [[ "$output" == *"required file not found"* ]]; then
            # ELF 文件存在却返回 ENOENT，通常是内核找不到该构建依赖的动态加载器。
            CORE_VERSION_ERROR+=$'\n'"文件存在但系统无法加载，通常缺少二进制所需的动态加载器；请使用本项目 vendor 的静态兼容构建。"
        fi
        return 1
    fi
    CORE_VERSION_TEXT=$(printf '%s\n' "$output" | head -1)
}

# 复用可运行的核心；损坏或不兼容时先下载验证，再替换已有文件。
install_cloudflared() {
    install_soft curl || return 3
    if [ -x "$CF_BIN" ]; then
        if core_version_read "$CF_BIN" --version; then
            echo -e "${green}已存在 cloudflared $CORE_VERSION_TEXT${re}"
            return 0
        fi
        echo "警告: 已有 cloudflared 无法正常运行，将从 vendor 重新安装: $CF_BIN" >&2
        printf '%s\n' "$CORE_VERSION_ERROR" >&2
    fi
    local arch tmp
    arch=$(cf_arch) || { echo -e "${red}错误: 当前架构 $(uname -m) 没有 cloudflared 构建${re}"; return 1; }
    core_disk_preflight || return 3
    tmp=$(mktemp -d "$TMP_DIR/core-download.XXXXXX") || return 1
    echo -e "${yellow}正在安装 cloudflared ${VENDOR_CF_TAG} (linux-$arch)，来自本项目 vendor${re}"
    if ! vendor_fetch "cloudflared/cloudflared-linux-$arch" "$tmp/cloudflared"; then
        rm -rf "$tmp"; return 1
    fi
    if ! chmod 755 "$tmp/cloudflared" || ! core_version_read "$tmp/cloudflared" --version; then
        echo "错误: 下载的 cloudflared 无法在本机运行，原文件未替换。" >&2
        printf '%s\n' "$CORE_VERSION_ERROR" >&2
        rm -rf "$tmp"; return 3
    fi
    if svc_running "$SVC_ARGO" "$SVC_ARGO"; then
        svc_stop "$SVC_ARGO" "$SVC_ARGO" || { echo "错误: 替换 cloudflared 前无法停止 $SVC_ARGO 服务。" >&2; rm -rf "$tmp"; return 1; }
    fi
    # 临时目录位于同一安装树，rename 替换避免再复制一份大二进制占用磁盘。
    mkdir -p -m 700 "$WORK_DIR" && mv -f "$tmp/cloudflared" "$CF_BIN" || {
        echo "错误: 无法将 cloudflared 安装到 $CF_BIN" >&2; rm -rf "$tmp"; return 1
    }
    rm -rf "$tmp"
    echo -e "${green}已安装 cloudflared $CORE_VERSION_TEXT${re}"
    return 0
}

# tar 包校验成功才解压，并验证可执行文件兼容当前平台。
install_singbox_core() {
    install_soft curl || return 3
    if [ -x "$SB_BIN" ]; then
        if core_version_read "$SB_BIN" version; then
            echo -e "${green}已存在 sing-box $CORE_VERSION_TEXT${re}"
            return 0
        fi
        echo "警告: 已有 sing-box 无法正常运行，将从 vendor 重新安装: $SB_BIN" >&2
        printf '%s\n' "$CORE_VERSION_ERROR" >&2
    fi
    local arch asset tmp
    arch=$(sb_arch) || { echo -e "${red}错误: 当前架构 $(uname -m) 没有 sing-box 构建${re}"; return 1; }
    core_disk_preflight || return 3
    asset="sing-box-${VENDOR_SB_TAG}-linux-${arch}.tar.gz"
    tmp=$(mktemp -d "$TMP_DIR/core-download.XXXXXX") || return 1
    echo -e "${yellow}正在安装 sing-box ${VENDOR_SB_TAG} (linux-$arch)，使用本项目 vendor 静态兼容构建${re}"
    if ! vendor_fetch "sing-box/$asset" "$tmp/$asset"; then
        rm -rf "$tmp"; return 1
    fi
    if ! tar -xzf "$tmp/$asset" -C "$tmp" 2>/dev/null; then
        echo -e "${red}错误: 解压 sing-box 失败${re}"
        rm -rf "$tmp"; return 1
    fi
    rm -f "$tmp/$asset"
    local bin
    bin=$(find "$tmp" -type f -name sing-box | head -1)
    if [ -z "$bin" ]; then
        echo -e "${red}错误: 压缩包里没找到 sing-box 可执行文件${re}"
        rm -rf "$tmp"; return 1
    fi
    if ! chmod 755 "$bin" || ! core_version_read "$bin" version; then
        echo "错误: 下载的 sing-box 无法在本机运行，原文件未替换。" >&2
        printf '%s\n' "$CORE_VERSION_ERROR" >&2
        rm -rf "$tmp"; return 3
    fi
    if svc_running "$SVC_SB" "$SVC_SB"; then
        svc_stop "$SVC_SB" "$SVC_SB" || { echo "错误: 替换 sing-box 前无法停止 $SVC_SB 服务。" >&2; rm -rf "$tmp"; return 1; }
    fi
    mkdir -p -m 700 "$SB_DIR" && mv -f "$bin" "$SB_BIN" || {
        echo "错误: 无法将 sing-box 安装到 $SB_BIN" >&2; rm -rf "$tmp"; return 1
    }
    rm -rf "$tmp"
    echo -e "${green}已安装 sing-box $CORE_VERSION_TEXT${re}"
    return 0
}

# ============================================================================
# sing-box 配置：vmess + ws 明文（TLS 由 CF 边缘负责）
# ============================================================================
sb_write_config() { # $1=监听端口 $2=uuid $3=ws路径
    local port=$1 uuid=$2 path=$3 details rc log_disabled=false
    [ "${CORE_LOGS:-1}" = 1 ] || log_disabled=true
    mkdir -p -m 700 "$SB_DIR" && chmod 700 "$SB_DIR" || { echo "错误: 无法准备 sing-box 配置目录 $SB_DIR" >&2; return 1; }
    cat > "$SB_CFG" <<EOF
{
  "log": { "disabled": $log_disabled, "level": "warn", "timestamp": true },
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
    rc=$?
    [ "$rc" = 0 ] && chmod 600 "$SB_CFG" || { echo "错误: 无法写入 sing-box 配置 $SB_CFG" >&2; return 1; }
    if details=$("$SB_BIN" check -c "$SB_CFG" 2>&1); then return 0; else rc=$?; fi
    echo "错误: sing-box 配置检查失败（退出码 $rc）: $SB_CFG" >&2
    [ -z "$details" ] || printf '%s\n' "$details" >&2
    return "$rc"
}

# 统一交互入口：管道与服务进程永远取默认值，避免安装等待 stdin。
ask() {
    local prompt=$1 def=${2:-} ans
    if [ -n "$NONINTERACTIVE" ] || [ ! -t 0 ]; then printf '%s' "$def"; return 0; fi
    read -rp "$prompt" ans
    printf '%s' "${ans:-$def}"
}

# BusyBox 不保证有 install，复制后显式设置执行权限即可。
install_bin() { cp "$1" "$2" && chmod 755 "$2"; }

# 不 source 配置：PATH 是节点字段，且配置中的 token 不能当 shell 代码执行。
env_get() { sed -n "s/^$2=//p" "$1" 2>/dev/null | tail -1; }

# 原子替换配置，保护 token 中的 &、反斜线及分隔符，并保持文件 600。
env_set() {
    local file=$1 key=$2 value=$3 escaped tmp
    [[ "$key" =~ ^[A-Z_]+$ ]] || return 1
    # KEY=VALUE 是单行格式，禁止换行与回车防止注入额外键。
    [[ "$value" != *$'\n'* && "$value" != *$'\r'* ]] || return 1
    umask 077
    mkdir -p -m 700 "$(dirname "$file")" || return 1
    tmp=$(mktemp "${file}.XXXXXX") || return 1
    escaped=$(printf '%s' "$value" | sed 's/[\\&|]/\\&/g')
    if [ -f "$file" ] && grep -q "^$key=" "$file"; then
        # 替换既有键时仍写临时文件，进程中断不会留下半份配置。
        sed "s|^$key=.*|$key=$escaped|" "$file" > "$tmp" || { rm -f "$tmp"; return 1; }
    else
        # 新键追加到副本，避免第一次安装依赖已有文件。
        [ ! -f "$file" ] || cat "$file" > "$tmp" || { rm -f "$tmp"; return 1; }
        printf '%s=%s\n' "$key" "$value" >> "$tmp" || { rm -f "$tmp"; return 1; }
    fi
    if chmod 600 "$tmp" && mv -f "$tmp" "$file"; then return 0; fi
    rm -f "$tmp"
    return 1
}

# 既有安装也沿用节点身份，机器标识只用于第一次生成稳定 id。
default_node_id() {
    local mid f host
    host=$(hostname)
    for f in /etc/machine-id /var/lib/dbus/machine-id /sys/class/dmi/id/product_uuid; do
        if [ -s "$f" ]; then mid=$(cat "$f"); break; fi
    done
    mid=${mid:-$host}
    printf '%s%s' "$host" "$mid" | sha256sum | cut -c1-12
}

# 节点名可直接用于分享链接，统一清理并截断非法字符。
node_name_clean() { printf '%s' "$1" | tr '\r\n' '--' | LC_ALL=C sed 's/[^A-Za-z0-9._-]/-/g' | cut -c1-64; }

# 文件格式不允许空白或引号，所有 CLI 持久值在写入前统一拒绝。
env_value_valid() { [[ ! "$1" =~ [[:space:]\"\'] ]]; }

# 同一校验用于 CLI 与 config，避免守护读到无法执行的周期与地址。
setting_valid() {
    local key=$1 val=$2
    env_value_valid "$val" || return 1
    case "$key" in
        REPORT_URL) [[ -z "$val" || "$val" =~ ^https?://[^/]+ ]] ;;
        REPORT_TOKEN) [ -n "$val" ] ;;
        NODE_NAME) [[ "$val" =~ ^[A-Za-z0-9._-]{1,64}$ ]] ;;
        CFIP) [[ -z "$val" || "$val" =~ ^[A-Za-z0-9.:-]+$ ]] ;;
        CHECK_INTERVAL) [[ "$val" =~ ^[0-9]{1,5}$ ]] && ((10#$val >= 300 && 10#$val <= 86400)) ;;
        WATCH_INTERVAL) [[ "$val" =~ ^[0-9]{1,5}$ ]] && ((10#$val == 0 || (10#$val >= 15 && 10#$val <= 86400))) ;;
        *) return 1 ;; # 白名单拒绝覆盖 MODE/UUID/PATH 等运行身份字段。
    esac
}

# 权威配置显式映射到 WS_PATH，绝不覆盖系统 PATH。
agent_load() {
    MODE=$(env_get "$AGENT_ENV" MODE); PORT=$(env_get "$AGENT_ENV" PORT)
    UUID=$(env_get "$AGENT_ENV" UUID); WS_PATH=$(env_get "$AGENT_ENV" PATH)
    DOMAIN=$(env_get "$AGENT_ENV" DOMAIN); MP=$(env_get "$AGENT_ENV" METRICS_PORT)
    NODE_ID=$(env_get "$AGENT_ENV" NODE_ID); NODE_NAME=$(env_get "$AGENT_ENV" NODE_NAME)
    CFIP=$(env_get "$AGENT_ENV" CFIP); REPORT_URL=$(env_get "$AGENT_ENV" REPORT_URL)
    REPORT_TOKEN=$(env_get "$AGENT_ENV" REPORT_TOKEN)
    CHECK_INTERVAL=$(env_get "$AGENT_ENV" CHECK_INTERVAL); CHECK_INTERVAL=${CHECK_INTERVAL:-$DEFAULT_CHECK_INTERVAL}
    WATCH_INTERVAL=$(env_get "$AGENT_ENV" WATCH_INTERVAL); WATCH_INTERVAL=${WATCH_INTERVAL:-$DEFAULT_CHECK_INTERVAL}
    CORE_LOGS=$(env_get "$AGENT_ENV" CORE_LOGS); CORE_LOGS=${CORE_LOGS:-1}
    COUNTRY=$(env_get "$AGENT_ENV" COUNTRY); location_country_valid "$COUNTRY" || COUNTRY=""
    REGION=$(env_get "$AGENT_ENV" REGION); [[ "$REGION" =~ ^[A-Za-z0-9_-]{1,16}$ ]] || REGION=""
    REGION_NAME=$(env_get "$AGENT_ENV" REGION_NAME)
    location_region_name_valid "$REGION_NAME" || REGION_NAME=""
    [ -n "$COUNTRY" ] || { REGION=""; REGION_NAME=""; }
    LOCATION_TS=$(env_get "$AGENT_ENV" LOCATION_TS); [[ "$LOCATION_TS" =~ ^[0-9]{1,12}$ ]] || LOCATION_TS=0
    LOCATION_ATTEMPT_TS=$(env_get "$AGENT_ENV" LOCATION_ATTEMPT_TS); [[ "$LOCATION_ATTEMPT_TS" =~ ^[0-9]{1,12}$ ]] || LOCATION_ATTEMPT_TS=0
    LOCATION_SOURCE=$(env_get "$AGENT_ENV" LOCATION_SOURCE)
    case "$LOCATION_SOURCE" in ipinfo|ip.sb|ip-api|worker) : ;; *) LOCATION_SOURCE="" ;; esac
    LOCATION_POLICY=$(env_get "$AGENT_ENV" LOCATION_POLICY)
    LOCATION_IP=$(env_get "$AGENT_ENV" LOCATION_IP)
    LOCATION_INTERFACE=$(env_get "$AGENT_ENV" LOCATION_INTERFACE)
    LOCATION_METHOD=$(env_get "$AGENT_ENV" LOCATION_METHOD)
    LOCATION_VERIFIED=0; LOCATION_NEEDS_REPORT=0
    if [ "$LOCATION_POLICY" != native-v1 ]; then
        COUNTRY=""; REGION=""; REGION_NAME=""; LOCATION_TS=0; LOCATION_ATTEMPT_TS=0
        LOCATION_SOURCE=""; LOCATION_IP=""; LOCATION_INTERFACE=""; LOCATION_METHOD=""
        LOCATION_NEEDS_REPORT=1
    elif [ -n "$COUNTRY" ] && location_ip_key "$LOCATION_IP" >/dev/null && [[ "$LOCATION_INTERFACE" =~ ^[A-Za-z0-9_.:-]{1,32}$ ]] && [[ "$LOCATION_METHOD" = ip || "$LOCATION_METHOD" = interface ]]; then
        LOCATION_VERIFIED=1
    else
        COUNTRY=""; REGION=""; REGION_NAME=""; LOCATION_TS=0; LOCATION_SOURCE=""
        LOCATION_IP=""; LOCATION_INTERFACE=""; LOCATION_METHOD=""
    fi
    LAST_REPORTED_DOMAIN=$(env_get "$AGENT_ENV" LAST_REPORTED_DOMAIN)
}

# 补齐默认字段，并从旧 nodes 文件迁移，保留已安装机器的目录约定。
agent_env_ensure() {
    local f k value
    runtime_dirs_ensure || return $?
    if [ ! -s "$AGENT_ENV" ]; then
        # 旧节点文件只作为首次迁移来源，此后 agent.env 为权威。
        f="$NODE_DIR/quick.env"
        [ -s "$f" ] || f="$NODE_DIR/fixed.env"
        [ ! -s "$f" ] || cp "$f" "$AGENT_ENV"
        touch "$AGENT_ENV"
    fi
    for k in MODE PORT UUID PATH DOMAIN METRICS_PORT CFIP REPORT_URL REPORT_TOKEN LAST_REPORTED_DOMAIN; do
        grep -q "^$k=" "$AGENT_ENV" || env_set "$AGENT_ENV" "$k" ""
    done
    for k in NODE_ID NODE_NAME CHECK_INTERVAL WATCH_INTERVAL CORE_LOGS LAST_REPORT_TS LAST_DOMAIN_TS; do
        if [ -z "$(env_get "$AGENT_ENV" "$k")" ]; then
            # 默认值集中在这里，迁移与全新安装得到相同配置。
            case "$k" in
                NODE_ID) value=$(default_node_id) ;; NODE_NAME) value=$(node_name_clean "$(hostname -s)") ;;
                CHECK_INTERVAL|WATCH_INTERVAL) value=$DEFAULT_CHECK_INTERVAL ;; CORE_LOGS) value=1 ;; *) value=0 ;;
            esac
            env_set "$AGENT_ENV" "$k" "$value" || return 1
        fi
    done
    chmod 600 "$AGENT_ENV"
    agent_load
}

# 无论本地脚本还是 curl 管道安装，服务都能调用稳定的脚本路径。
install_self() {
    local source=${BASH_SOURCE[0]:-$0} tmp
    runtime_dirs_ensure || return 3
    if [ -f "$source" ] && [ -r "$source" ]; then
        # 老版 bin/tunel 仍是脚本，先复制到 work 再替换为绑定目录的启动器。
        if [ "$source" -ef "$SELF_SCRIPT" ]; then chmod 755 "$SELF_SCRIPT" || return 3
        else install_bin "$source" "$SELF_SCRIPT" || return 3; fi
    else
        tmp=$(mktemp "$WORK_DIR/tunel-download.XXXXXX") || return 3
        if ! http_fetch "$VENDOR_RAW_BASE/tunel.sh" "$tmp" 524288 || [ ! -s "$tmp" ] || ! bash -n "$tmp"; then
            rm -f "$tmp"; echo "错误: 无法下载可用脚本到 $SELF_SCRIPT" >&2; return 3
        fi
        install_bin "$tmp" "$SELF_SCRIPT" || { rm -f "$tmp"; return 3; }
        rm -f "$tmp"
    fi
    # 固定目录的启动器让自定义路径在直接调用和 daemon 重启中都保持一致。
    tmp=$(mktemp "$BIN_DIR/tunel-launcher.XXXXXX") || return 3
    {
        printf '#!/bin/sh\n'
        if [ "$TUNEL_SYSTEM" = 1 ]; then printf 'unset TUNEL_HOME\n'
        else printf "export TUNEL_HOME='%s'\n" "$TUNEL_HOME"; fi
        printf "exec bash '%s' \"\$@\"\n" "$SELF_SCRIPT"
    } > "$tmp"
    chmod 755 "$tmp" && mv -f "$tmp" "$SELF_INSTALL" && return 0
    rm -f "$tmp"; echo "错误: 无法将启动器安装到 $SELF_INSTALL" >&2; return 3
}

# 错误先给 stderr，再展示用法，保证退出码 2 能被自动化识别。
usage_error() { echo "$*" >&2; help >&2; return 2; }

# 参数支持 --k=v，first non-option 是子命令，其余位置参数交由子命令处理。
parse_args() {
    COMMAND=""; POSITIONAL=(); NO_AGENT=0; INSTALL_OPTIONS_USED=0
    OPT_PORT=""; OPT_DOMAIN=""; OPT_TOKEN=""; OPT_JSON_FILE=""
    OPT_NAME=$(node_name_clean "${TUNEL_NODE_NAME:-}"); OPT_CFIP=${TUNEL_CFIP:-}; OPT_NODE_ID=${TUNEL_NODE_ID:-}
    OPT_REPORT_URL=${TUNEL_REPORT_URL:-}; OPT_REPORT_TOKEN=${TUNEL_REPORT_TOKEN:-}
    OPT_CHECK=""; OPT_WATCH=""
    while [ "$#" -gt 0 ]; do
        if [[ "$1" == --*=* ]]; then set -- "${1%%=*}" "${1#*=}" "${@:2}"; fi
        case "$1" in
            -y|--yes) NONINTERACTIVE=1; shift ;;
            --no-agent) NO_AGENT=1; INSTALL_OPTIONS_USED=1; shift ;;
            --port|--name|--cfip|--node-id|--report-url|--report-token|--check-interval|--watch-interval|--domain|--token|--json-file)
                [ "$#" -ge 2 ] && [ -n "$2" ] || { usage_error "选项缺少值: $1"; return 2; }
                INSTALL_OPTIONS_USED=1
                case "$1" in
                    --port) OPT_PORT=$2 ;; --name) OPT_NAME=$(node_name_clean "$2") ;; --cfip) OPT_CFIP=$2 ;;
                    --node-id) OPT_NODE_ID=$2 ;; --report-url) OPT_REPORT_URL=$2 ;; --report-token) OPT_REPORT_TOKEN=$2 ;;
                    --check-interval) OPT_CHECK=$2 ;; --watch-interval) OPT_WATCH=$2 ;; --domain) OPT_DOMAIN=$2 ;;
                    --token) OPT_TOKEN=$2 ;; --json-file) OPT_JSON_FILE=$2 ;;
                esac
                shift 2 ;;
            --help|-h) COMMAND=help; shift ;;
            -*) usage_error "未知选项: $1"; return 2 ;;
            *)
                # agent 动作与 config 键值保留原顺序，不能被当成新子命令。
                if [ -z "$COMMAND" ]; then COMMAND=$1; else POSITIONAL+=("$1"); fi
                shift ;;
        esac
    done
    if [ -z "$COMMAND" ]; then
        if [ -t 0 ]; then COMMAND=menu; else help; return 2; fi
    fi
    case "$COMMAND" in
        run) NONINTERACTIVE=1 ;;
        quick|fixed|agent|report|uninstall|restart|config) [ -t 0 ] || NONINTERACTIVE=1 ;;
        menu|node|version|help) : ;;
        *) usage_error "未知子命令: $COMMAND"; return 2 ;;
    esac
    if [ "$COMMAND" != quick ] && [ "$COMMAND" != fixed ]; then
        # 安装参数不能在 node/config 等命令中被默默忽略；help 始终可读。
        [ "$COMMAND" = help ] || [ "$INSTALL_OPTIONS_USED" = 0 ] || { usage_error "安装选项只用于 quick/fixed"; return 2; }
        return 0
    fi
    [ -z "$OPT_PORT" ] || valid_port "$OPT_PORT" || { usage_error "端口不合法: $OPT_PORT"; return 2; }
    local pair key value
    for pair in "NODE_NAME=$OPT_NAME" "CFIP=$OPT_CFIP" "REPORT_URL=$OPT_REPORT_URL" "REPORT_TOKEN=$OPT_REPORT_TOKEN" "CHECK_INTERVAL=$OPT_CHECK" "WATCH_INTERVAL=$OPT_WATCH"; do
        key=${pair%%=*}; value=${pair#*=}
        [ -z "$value" ] || setting_valid "$key" "$value" || { usage_error "参数不合法: $key"; return 2; }
    done
    [[ -z "$OPT_NODE_ID" || "$OPT_NODE_ID" =~ ^[A-Za-z0-9_-]{4,64}$ ]] || { usage_error "参数不合法: NODE_ID"; return 2; }
    if [ "$COMMAND" = quick ] || [ "$COMMAND" = fixed ]; then
        [ "${#POSITIONAL[@]}" = 0 ] || { usage_error "安装命令不接受位置参数"; return 2; }
        # 成对配置才能安装可用的自动上报守护。
        [[ -z "$OPT_REPORT_URL" && -z "$OPT_REPORT_TOKEN" || -n "$OPT_REPORT_URL" && -n "$OPT_REPORT_TOKEN" ]] || { usage_error "--report-url 与 --report-token 必须同时提供"; return 2; }
    fi
    if [ "$COMMAND" = fixed ]; then
        [[ "$OPT_DOMAIN" =~ ^[A-Za-z0-9.-]{1,253}$ ]] || { usage_error "fixed 必须提供合法 --domain"; return 2; }
        [[ -n "$OPT_TOKEN" && -z "$OPT_JSON_FILE" || -z "$OPT_TOKEN" && -n "$OPT_JSON_FILE" ]] || { usage_error "fixed 必须提供 --token 或 --json-file（二选一）"; return 2; }
        [ -z "$OPT_TOKEN" ] || env_value_valid "$OPT_TOKEN" || { usage_error "隧道 token 不合法"; return 2; }
        [ -z "$OPT_JSON_FILE" ] || [ -r "$OPT_JSON_FILE" ] || { usage_error "JSON 文件不可读: $OPT_JSON_FILE"; return 2; }
    elif [ -n "$OPT_DOMAIN$OPT_TOKEN$OPT_JSON_FILE" ]; then
        usage_error "--domain/--token/--json-file 只用于 fixed"; return 2
    fi
}

# 帮助只读且不探测网络，适用于无 tty 的脚本调用。
help() {
    cat <<'EOF'
tunel 2.0.0 — vmess-ws 隧道与自动上报
用法: tunel.sh <子命令> [选项]
  menu                    交互菜单
  quick [选项]            安装临时隧道
  fixed --domain D (--token T | --json-file F) [选项]
  agent start|stop|restart|status|log|once|loop
  run                     读取已安装配置，前台运行（容器 ENTRYPOINT）
  report                  手动立即上报
  node                    节点信息与三服务状态
  restart                 受控重启隧道、刷新域名并上报
  config K=V ...           修改 REPORT_URL REPORT_TOKEN NODE_NAME CFIP
                          CHECK_INTERVAL WATCH_INTERVAL 后重启守护
  uninstall [-y]          注销节点并卸载全部服务与文件
  version | help
安装选项（支持 --k=v）:
  --port N --name X --cfip H --node-id ID
  --report-url U --report-token T --check-interval S (300–86400，默认7200)
  --watch-interval S (0 或15–86400，默认7200) --no-agent -y/--yes
可用环境变量: TUNEL_NODE_NAME TUNEL_CFIP TUNEL_NODE_ID
              TUNEL_REPORT_URL TUNEL_REPORT_TOKEN
              TUNEL_HOME（普通用户默认 $HOME/.local/share/tunel）
便携目录: TUNEL_HOME 下 work/bin/log/run；不安装系统服务或开机钩子。
TUNEL_HOME 须为专用绝对路径，无空格/引号/特殊字符及 .、.. 段。
退出码: 0成功 1一般失败 2用法错误 3下载/校验/依赖失败
        4端口不可用 5域名获取失败 6手动上报失败
EOF
}

# 服务包装只写路径和参数，敏感 token 始终从 600 文件读取。
svc_wrapper() {
    {
        printf '#!/bin/sh\n'
        if [ "$TUNEL_SYSTEM" = 1 ]; then printf 'unset TUNEL_HOME\n'
        else printf "export TUNEL_HOME='%s'\n" "$TUNEL_HOME"; fi
        [ "$ENV_LOWMEM" != 1 ] || printf 'export GOGC=30\nexport GOMEMLIMIT=48MiB\n'
        # 只降低过大的软限制，不提高普通用户已有的限制或硬限制。
        cat <<'EOF'
tunel_fd_limit=$(ulimit -Sn 2>/dev/null)
case "$tunel_fd_limit" in
    unlimited) ulimit -Sn 4096 2>/dev/null || true ;;
    ''|*[!0-9]*) : ;;
    *) [ "$tunel_fd_limit" -le 4096 ] || ulimit -Sn 4096 2>/dev/null || true ;;
esac
EOF
        # exec 让服务管理器直接追踪实际子进程。
        if [ "$1" != "$SVC_AGENT" ] && [ "${CORE_LOGS:-1}" != 1 ]; then
            # 显式禁用守护后无人限量日志，核心输出直接丢弃以免长期占盘。
            printf 'exec %s >/dev/null 2>&1\n' "$2"
        else
            printf 'exec %s\n' "$2"
        fi
    } > "$BIN_DIR/$1-run"
    chmod 755 "$BIN_DIR/$1-run"
}

# /proc starttime 与 PID 一起持久化，避免 stale PID 杀到重用该号码的其他进程。
proc_start_time() {
    [[ "$1" =~ ^[0-9]+$ ]] && [ "$1" -gt 0 ] || return 1
    awk '{sub(/^.*\) /, ""); if ($1 != "Z") print $20}' "/proc/$1/stat" 2>/dev/null
}

# 低内存机器收紧 Go 内存，保持既有兼容行为。
svc_env_lines() {
    if [ "$ENV_LOWMEM" = 1 ]; then printf 'Environment=GOGC=30\nEnvironment=GOMEMLIMIT=48MiB\n'; fi
}

# 六七参数让 agent 有始终重启和网络依赖，两种核心仍使用 on-failure。
svc_install() {
    local unit=$1 oname=$2 desc=$3 cmd=$4 logdir=$5 policy=${6:-on-failure} after=${7:-network.target nss-lookup.target}
    local envsh="" wants="" delay=10
    runtime_dirs_ensure || return 1
    mkdir -p -m 700 "$logdir" || return 1
    chmod 700 "$logdir"
    svc_wrapper "$oname" "$cmd" || return 1
    [ "$ENV_LOWMEM" != 1 ] || envsh=$(printf 'export GOGC=30\nexport GOMEMLIMIT=48MiB')
    if [ "$policy" = always ]; then wants="Wants=network-online.target"; delay=15; fi
    case "$ENV_INIT" in
        systemd)
            [ "$TUNEL_SYSTEM" = 1 ] && [ "$EUID" = 0 ] || return 1
            # agent 排在依赖之后，启动时仍自行校验服务以兼容人工停止。
            cat > "/etc/systemd/system/$unit.service" <<EOF
[Unit]
Description=$desc
After=$after
$wants
[Service]
Type=simple
User=root
ExecStart=$BIN_DIR/$oname-run
Restart=$policy
RestartSec=$delay
LimitNOFILE=4096
LogRateLimitIntervalSec=30s
LogRateLimitBurst=50
$(svc_env_lines)
[Install]
WantedBy=multi-user.target
EOF
            systemctl daemon-reload && systemctl enable "$unit" >/dev/null 2>&1 && systemctl restart "$unit" 9>&- ;;
        openrc)
            [ "$TUNEL_SYSTEM" = 1 ] && [ "$EUID" = 0 ] || return 1
            # 新 openrc 由 supervisor 拉起崩溃进程，旧版保留 background 兼容。
            local supervision
            if has supervise-daemon; then
                supervision=$(printf 'supervisor="supervise-daemon"\nsupervise_daemon_args="--respawn-delay 5 --respawn-max 0"')
            else
                supervision=$(printf 'command_background=true\npidfile="%s/%s.pid"' "$RUN_DIR" "$oname")
            fi
            cat > "/etc/init.d/$oname" <<EOF
#!/sbin/openrc-run
name="$oname"
description="$desc"
command="$BIN_DIR/$oname-run"
$envsh
$supervision
output_log="$logdir/access.log"
error_log="$logdir/error.log"
# 先连接网络再建立隧道，恢复逻辑由 agent 负责。
depend() {
    need net
    after net
}
EOF
            chmod 755 "/etc/init.d/$oname" && rc-update add "$oname" default >/dev/null 2>&1 && rc-service "$oname" restart 9>&- ;;
        none)
            # 容器没有 init 时使用同一包装脚本，控制脚本保存 PID。
            svc_none_install "$oname" "$logdir" ;;
    esac
    local rc=$?
    if [ "$rc" != 0 ]; then
        echo "错误: 注册或启动服务 $oname 失败（init: $ENV_INIT，退出码 $rc）。" >&2
        echo "服务日志: $logdir/access.log / $logdir/error.log" >&2
        [ ! -s "$logdir/error.log" ] || tail -n 20 "$logdir/error.log" >&2
        [ "$oname" != "$SVC_ARGO" ] || echo "cloudflared 日志: $ARGO_LOG" >&2
    fi
    return "$rc"
}

# 无 init 控制脚本记录 PID 和 starttime，旧纯数字 PID 只在命令路径匹配时接管。
svc_none_install() {
    local name=$1 logdir=$2 action=${3:-restart} expected legacy stopwait=20
    case "$name" in
        "$SVC_SB") expected=$SB_BIN ;;
        "$SVC_ARGO") expected=$CF_BIN ;;
        "$SVC_AGENT") expected=$SELF_SCRIPT ;;
        *) return 2 ;;
    esac
    legacy=$expected; [ "$name" != "$SVC_AGENT" ] || legacy=$SELF_INSTALL
    [ "$name" != "$SVC_AGENT" ] || stopwait=90
    {
        printf '#!/bin/sh\n'
        printf "pidfile='%s/%s.pid'\nwrapper='%s/%s-run'\nlogdir='%s'\nexpected='%s'\nlegacy='%s'\nctllock='%s/%s.ctl.lock'\nstopwait=%s\n" \
            "$RUN_DIR" "$name" "$BIN_DIR" "$name" "$logdir" "$expected" "$legacy" "$RUN_DIR" "$name" "$stopwait"
        printf "argoctl='%s/%s-ctl'\nsbctl='%s/%s-ctl'\n" "$BIN_DIR" "$SVC_ARGO" "$BIN_DIR" "$SVC_SB"
        cat <<'EOF'
starttime() {
    awk '{sub(/^.*\) /, ""); if ($1 != "Z") print $20}' "/proc/$1/stat" 2>/dev/null
}
pid_matches() {
    [ -f "$pidfile" ] || return 1
    read -r __pid __start __mode < "$pidfile"
    case "$__pid" in ''|*[!0-9]*) return 1 ;; esac
    [ "$__pid" -gt 0 ] && kill -0 "$__pid" 2>/dev/null || return 1
    __actual=$(starttime "$__pid")
    [ -n "$__actual" ] || return 1
    if [ -n "$__start" ]; then
        [ "$__start" = "$__actual" ]
    else
        # 兼容旧 PID 文件，但不能仅凭 kill -0 认领一个不相关进程。
        tr '\000' '\n' < "/proc/$__pid/cmdline" 2>/dev/null | grep -Fx -e "$expected" -e "$wrapper" -e "$legacy" >/dev/null
    fi
}
start_service() {
    pid_matches && return 0
    rm -f "$pidfile"
    # 关闭 ctl 锁与 agent 锁，守护退出时核心不能继续占有这些锁。
    nohup "$wrapper" >> "$logdir/access.log" 2>> "$logdir/error.log" < /dev/null 7>&- 8>&- 9>&- &
    __pid=$!; __start=$(starttime "$__pid")
    [ -n "$__start" ] || return 1
    printf '%s %s background\n' "$__pid" "$__start" > "$pidfile" || return 1
    sleep 0.2 9>&-
    pid_matches || { rm -f "$pidfile"; return 1; }
}
stop_service() {
    if pid_matches; then
        kill "$__pid" 2>/dev/null || true
        __i=0
        while [ "$__i" -lt "$stopwait" ] && pid_matches; do sleep 0.5 9>&-; __i=$((__i+1)); done
        # 前台失去响应时，强杀前先停同安装核心，不能留下脱管的隧道进程。
        if pid_matches && [ "$__mode" = run ]; then
            [ ! -x "$argoctl" ] || "$argoctl" stop 7>&- 8>&- 9>&- >/dev/null 2>&1
            [ ! -x "$sbctl" ] || "$sbctl" stop 7>&- 8>&- 9>&- >/dev/null 2>&1
        fi
        # 每次都重新比对 starttime，原进程退出后不对重用 PID 发 KILL。
        pid_matches && kill -9 "$__pid" 2>/dev/null
    fi
    rm -f "$pidfile"
}
case "$1" in
    status) if pid_matches; then echo running; else echo stopped; exit 1; fi; exit 0 ;;
    start|stop|restart) : ;;
    *) echo "用法: $0 {start|stop|restart|status}"; exit 2 ;;
esac
umask 077
exec 8>"$ctllock" || exit 1
flock -w 60 8 || exit 1
case "$1" in
    start) start_service ;;
    stop) stop_service ;;
    restart) stop_service; start_service ;;
esac
EOF
    } > "$BIN_DIR/$name-ctl"
    chmod 755 "$BIN_DIR/$name-ctl" || return 1
    [ "$action" != no-start ] || return 0
    "$BIN_DIR/$name-ctl" "$action" 7>&- 9>&-
}

# 服务操作保留真实退出码，启动失败不能被当成恢复成功。
svc_restart() {
    case "$ENV_INIT" in
        systemd) systemctl restart "$1" 9>&- >/dev/null 2>&1 ;;
        openrc) rc-service "$2" restart 9>&- >/dev/null 2>&1 ;;
        none) "$BIN_DIR/$2-ctl" restart 7>&- 9>&- >/dev/null 2>&1 ;;
    esac
}

# 单独的布尔接口避免把 running/not running 文案解析错。
svc_running() {
    case "$ENV_INIT" in
        systemd) systemctl is-active --quiet "$1" 9>&- ;;
        openrc) rc-service "$2" status 9>&- >/dev/null 2>&1 ;;
        none) [ -x "$BIN_DIR/$2-ctl" ] && "$BIN_DIR/$2-ctl" status 7>&- 9>&- >/dev/null 2>&1 ;;
    esac
}

# 管理命令只停止目标服务，删除交给卸载路径统一处理。
svc_stop() {
    case "$ENV_INIT" in
        systemd) systemctl stop "$1" 9>&- >/dev/null 2>&1 ;;
        openrc) rc-service "$2" stop 9>&- >/dev/null 2>&1 ;;
        none) [ ! -x "$BIN_DIR/$2-ctl" ] || "$BIN_DIR/$2-ctl" stop 7>&- 9>&- >/dev/null 2>&1 ;;
    esac
}

# 三种 init 使用同一简短状态展示。
svc_state() { if svc_running "$1" "$2"; then echo "running ($ENV_INIT)"; else echo "stopped ($ENV_INIT)"; fi; }

# 系统安装兼容旧 unit 文件，便携安装只清理自己树内的脚本和 PID。
svc_remove() {
    if [ "$TUNEL_SYSTEM" = 1 ] && [ "$EUID" = 0 ]; then
        case "$ENV_INIT" in
            systemd)
                systemctl stop "$1" 9>&- >/dev/null 2>&1
                systemctl disable "$1" >/dev/null 2>&1 ;;
            openrc)
                rc-service "$2" stop 9>&- >/dev/null 2>&1
                rc-update del "$2" default >/dev/null 2>&1 ;;
        esac
        rm -f "/etc/systemd/system/$1.service" "/etc/init.d/$2"
        [ "$ENV_INIT" != systemd ] || systemctl daemon-reload >/dev/null 2>&1
    fi
    [ ! -x "$BIN_DIR/$2-ctl" ] || "$BIN_DIR/$2-ctl" stop 9>&- >/dev/null 2>&1
    rm -f "$BIN_DIR/$2-ctl" "$BIN_DIR/$2-run" "$RUN_DIR/$2.pid" "$RUN_DIR/$2.ctl.lock"
}

# 无 init 的系统安装保留旧启动钩子，便携模式不依赖或修改 cron/rc.local。
boot_hook_install() {
    [ "$TUNEL_SYSTEM" = 1 ] && [ "$EUID" = 0 ] || return 0
    local line="@reboot $SELF_INSTALL agent start >/dev/null 2>&1" tmp
    tmp=$(mktemp) || return 1
    if has crontab; then
        (crontab -l 2>/dev/null || true) | grep -vF "$SELF_INSTALL agent start" > "$tmp"
        printf '%s\n' "$line" >> "$tmp"
        crontab "$tmp"; local rc=$?; rm -f "$tmp"; return "$rc"
    elif [ -f /etc/rc.local ]; then
        # 在 exit 0 前插入，不让启动命令变成不可达代码。
        grep -vF "$SELF_INSTALL agent start" /etc/rc.local > "$tmp"
        awk -v cmd="$SELF_INSTALL agent start >/dev/null 2>&1" '/^[[:space:]]*exit[[:space:]]+0/ && !done {print cmd; done=1} {print} END {if (!done) print cmd}' "$tmp" > /etc/rc.local
        chmod 755 /etc/rc.local
    fi
    rm -f "$tmp"
}

# 卸载仅删本工具的自启行，避免误删同一 crontab 的其他任务。
boot_hook_remove() {
    [ "$TUNEL_SYSTEM" = 1 ] && [ "$EUID" = 0 ] || return 0
    local tmp
    tmp=$(mktemp) || return 1
    if has crontab; then
        (crontab -l 2>/dev/null || true) | grep -vF "$SELF_INSTALL agent start" > "$tmp"
        crontab "$tmp"
    fi
    if [ -f /etc/rc.local ]; then grep -vF "$SELF_INSTALL agent start" /etc/rc.local > "$tmp"; cat "$tmp" > /etc/rc.local; fi
    rm -f "$tmp"
}

# 已运行的服务会占用自己的 metrics 端口，不能因此选错监控地址。
metrics_port_ensure() {
    local p
    p=$(env_get "$AGENT_ENV" METRICS_PORT)
    if ! valid_port "$p" || { check_port "$p" && ! svc_running "$SVC_ARGO" "$SVC_ARGO"; }; then
        # 仅新安装或旧端口被其他进程占用时重新选择。
        p=$(pick_free_port) || return 4
        env_set "$AGENT_ENV" METRICS_PORT "$p" || return 1
    fi
    MP=$p
}

# 三种启动方式都启用本机 metrics，域名获取无需依赖横幅格式。
argo_quick_args() { printf 'tunnel --no-autoupdate --loglevel warn --edge-ip-version auto --protocol http2 --metrics 127.0.0.1:%s --url http://127.0.0.1:%s' "$MP" "$1"; }

# token 值从文件读取，不进入 unit、wrapper 或 cloudflared 的进程参数。
argo_token_args() { printf 'tunnel --no-autoupdate --loglevel warn --edge-ip-version auto --protocol http2 --metrics 127.0.0.1:%s run --token-file "%s"' "$MP" "$ARGO_TOKEN_FILE"; }

# credentials 模式也通过相同的 metrics 端口判断边缘连接。
argo_config_args() { printf 'tunnel --no-autoupdate --loglevel warn --edge-ip-version auto --protocol http2 --metrics 127.0.0.1:%s --config "%s" run' "$MP" "$TUNNEL_YML"; }

# 凭据 JSON 和 YML 用私有权限保存，域名与端口已经经过 CLI 校验。
argo_write_creds() {
    local json=$1 domain=$2 port=$3 tid
    umask 077
    tid=$(printf '%s' "$json" | sed -n 's/.*"TunnelID"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)
    [[ "$tid" =~ ^[A-Za-z0-9-]+$ ]] && [[ "$json" == *TunnelSecret* ]] || return 1
    printf '%s\n' "$json" > "$TUNNEL_JSON"
    cat > "$TUNNEL_YML" <<EOF
tunnel: $tid
credentials-file: $TUNNEL_JSON
ingress:
  - hostname: $domain
    service: http://127.0.0.1:$port
  - service: http_status:404
EOF
    chmod 600 "$TUNNEL_JSON" "$TUNNEL_YML"
}

# 只有 metrics 暂不可用才读取当前进程日志，重启前必须清空旧日志。
argo_grab_domain() {
    local log=$1 tries=${2:-10} d i
    for ((i=0; i<tries; i++)); do
        d=$(sed -n 's|.*https://\([A-Za-z0-9-]*\.trycloudflare\.com\).*|\1|p' "$log" 2>/dev/null | tail -1)
        if [ -n "$d" ]; then printf '%s' "$d"; return 0; fi
        [ "$i" -ge "$((tries-1))" ] || sleep 2
    done
    return 1
}

# 本地接口不出网，只接受合法 quick tunnel 域名避免污染链接与 shell 参数。
domain_from_metrics() {
    local d
    d=$(exec 9>&-; curl -fsS -m 3 "http://127.0.0.1:$MP/quicktunnel" 9>&- 2>/dev/null | sed -n 's/.*"hostname"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
    [[ "$d" =~ ^[A-Za-z0-9.-]+\.trycloudflare\.com$ ]] && printf '%s' "$d"
}

# HTTP 200 表示 cloudflared 有边缘连接，其他状态均视为未就绪。
edge_ready() { [ "$(exec 9>&-; curl -s -o /dev/null -w '%{http_code}' -m 3 "http://127.0.0.1:$MP/ready" 9>&- 2>/dev/null)" = 200 ]; }

# 固定域名无需查询 quicktunnel；quick 优先从本机当前进程获取。
get_domain() {
    local d
    if [ "$MODE" = fixed ]; then env_get "$AGENT_ENV" DOMAIN; return; fi
    d=$(domain_from_metrics 9>&-)
    [ -n "$d" ] || d=$(argo_grab_domain "$ARGO_LOG" 1)
    printf '%s' "$d"
}

# 等待新域名有明确上限，固定隧道使用空旧值等待当前域名即可。
wait_new_domain() {
    local old=${1:-} timeout=${2:-60} d elapsed=0
    WAIT_DOMAIN=""
    while [ "$elapsed" -le "$timeout" ] && [ "${STOP:-0}" != 1 ]; do
        d=$(get_domain 9>&-)
        if [ -n "$d" ] && [ "$d" != "$old" ]; then WAIT_DOMAIN=$d; printf '%s' "$d"; return 0; fi
        [ "$elapsed" -lt "$timeout" ] || break
        agent_sleep 2 || return 1; elapsed=$((elapsed+2))
    done
    return 1
}

# WebSocket 仅检查 Upgrade 状态，不发送认证流量或 early data。
ws_probe() {
    local code
    code=$(exec 9>&-; curl -s -o /dev/null -w '%{http_code}' -m 8 --http1.1 -k \
        -H 'Connection: Upgrade' -H 'Upgrade: websocket' -H 'Sec-WebSocket-Version: 13' \
        -H "Sec-WebSocket-Key: $(head -c16 /dev/urandom | base64 | tr -d '\n')" "$1" 9>&- 2>/dev/null)
    WS_LAST_CODE=${code:-000}
    [ "$WS_LAST_CODE" = 101 ]
}

# JSON 按字节转义控制字符，中文 UTF-8 字节保持原样，不引入 jq 依赖。
json_escape() {
    local LC_ALL=C s=$1 out="" char n i
    for ((i=0;i<${#s};i++)); do
        char=${s:i:1}
        case "$char" in
            '"') out+='\"' ;; '\') out+='\\' ;;
            *)
                # 低位控制字符必须用 \u 转义，否则 Worker 无法解析 JSON。
                printf -v n '%d' "'$char"
                if [ "$n" -lt 32 ]; then printf -v char '\\u%04x' "$n"; fi
                out+=$char ;;
        esac
    done
    printf '%s' "$out"
}

# VMess 的连接地址缺省为隧道域名；Host 与 SNI 始终使用隧道域名。
node_display_name() {
    local location=""
    if [ -n "${COUNTRY:-}" ]; then
        location=$COUNTRY
        if [ -n "${REGION_NAME:-}" ]; then location+=" · $REGION_NAME"
        elif [ -n "${REGION:-}" ]; then location+="-$REGION"; fi
    fi
    printf '%s' "${location:-未识别地区}"
}

vmess_link() {
    local domain=$1 uuid=$2 path=$3 cfip=${4:-$1} ps=$5 json
    json=$(printf '{"v":"2","ps":"%s","add":"%s","port":"443","id":"%s","aid":"0","scy":"auto","net":"ws","type":"none","host":"%s","path":"%s?ed=2560","tls":"tls","sni":"%s","alpn":"","fp":"firefox"}' \
        "$(json_escape "$ps")" "$(json_escape "$cfip")" "$uuid" "$domain" "$(json_escape "$path")" "$domain")
    printf 'vmess://%s' "$(printf '%s' "$json" | base64 | tr -d '\n')"
}

# 兼容节点文件由权威配置生成，删除另一种模式避免显示旧节点。
nodes_refresh() {
    local link
    umask 077
    mkdir -p -m 700 "$NODE_DIR" || return 1
    chmod 700 "$NODE_DIR"
    link=$(vmess_link "$DOMAIN" "$UUID" "$WS_PATH" "${CFIP:-$DOMAIN}" "$(node_display_name)")
    printf '%s\n' "$link" > "$NODE_DIR/$MODE.txt"
    printf 'MODE=%s\nPORT=%s\nUUID=%s\nPATH=%s\nDOMAIN=%s\n' "$MODE" "$PORT" "$UUID" "$WS_PATH" "$DOMAIN" > "$NODE_DIR/$MODE.env"
    chmod 600 "$NODE_DIR/$MODE.env" "$NODE_DIR/$MODE.txt"
    if [ "$MODE" = quick ]; then rm -f "$NODE_DIR/fixed.env" "$NODE_DIR/fixed.txt"; else rm -f "$NODE_DIR/quick.env" "$NODE_DIR/quick.txt"; fi
}

# 服务描述与目录保持既有名称，使升级后卸载仍能找到旧安装。
sb_service_up() {
    local output="$LOG_DIR/access.log" error="$LOG_DIR/error.log"
    [ "${CORE_LOGS:-1}" = 1 ] || { output=/dev/null; error=/dev/null; }
    svc_install "$SVC_SB" "$SVC_SB" "tunel VMess-WS" "\"$SB_BIN\" run -c \"$SB_CFG\" >> \"$output\" 2>> \"$error\"" "$LOG_DIR" on-failure
}

# shell -c 中 exec 让 cloudflared 成为直接受监管的进程。
argo_service_up() {
    local output=$ARGO_LOG
    [ "${CORE_LOGS:-1}" = 1 ] || output=/dev/null
    svc_install "$SVC_ARGO" "$SVC_ARGO" "tunel (cloudflared)" "/bin/sh -c 'exec \"$CF_BIN\" $2 >> \"$output\" 2>&1'" "$LOG_DIR" on-failure
}

# 读取已保存的固定凭据，恢复时无需用户重新输入密钥。
argo_service_configure() {
    if [ "$MODE" = quick ]; then argo_service_up quick "$(argo_quick_args "$PORT")"
    elif [ -s "$ARGO_TOKEN_FILE" ]; then argo_service_up token "$(argo_token_args)"
    elif [ -s "$TUNNEL_JSON" ]; then argo_service_up config "$(argo_config_args)"
    else echo "错误: 固定隧道缺少 token 文件或 JSON，请重新执行 fixed 安装" >&2; return 1; fi
}

LOG_MAX_BYTES=262144
LOG_KEEP_BYTES=65536
RESOURCE_MAINTENANCE_INTERVAL=30

# stat 只读大小；旧 minimal 环境退回流式 wc，不把整份日志装进内存。
log_file_size() {
    local size
    if has stat; then size=$(stat -c %s "$1" 2>/dev/null) || return 1
    else size=$(wc -c < "$1" 2>/dev/null) || return 1; fi
    size=${size//[[:space:]]/}
    [[ "$size" =~ ^[0-9]{1,18}$ ]] || return 1
    printf '%s' "$size"
}

# 保留同一 inode，运行中 O_APPEND 的日志 FD 不会继续写入被改名的旧文件。
log_trim_in_place() (
    local file=$1 size tmp=""
    trap - EXIT TERM INT
    exec 7>&- 9>&-
    [ -f "$file" ] && [ ! -L "$file" ] && [ -w "$file" ] || return 0
    size=$(log_file_size "$file") || return 1
    [ "$size" -gt "$LOG_MAX_BYTES" ] || return 0
    umask 077
    tmp=$(mktemp "$TMP_DIR/log-trim.XXXXXX") || { : > "$file"; return $?; }
    trap 'rm -f "$tmp"' EXIT
    trap 'exit 1' TERM INT
    # 尾部副本有固定上限；磁盘已满时直接截空日志，优先释放空间。
    if ! tail -c "$LOG_KEEP_BYTES" "$file" > "$tmp"; then
        rm -f "$tmp"
        : > "$file"
        return $?
    fi
    cat "$tmp" > "$file"
)

# 固定枚举本安装的四个文本日志，每 30 秒限量一次，不扫描用户磁盘。
resource_maintenance() {
    local now=$1 file
    [ "$((now-${RESOURCE_LAST_MAINTENANCE_TS:-0}))" -ge "$RESOURCE_MAINTENANCE_INTERVAL" ] || return 0
    RESOURCE_LAST_MAINTENANCE_TS=$now
    for file in "$AGENT_LOG" "$ARGO_LOG" "$LOG_DIR/access.log" "$LOG_DIR/error.log"; do
        log_trim_in_place "$file" || printf '警告: 日志限量失败: %s\n' "$file" >&2
    done
    return 0
}

# 日志是尽力写入的诊断，磁盘错误不能阻止隧道恢复或节点上报。
agent_log() {
    local level=$1 msg=$2
    umask 077
    [ -d "$WORK_DIR" ] || mkdir -p -m 700 "$WORK_DIR" || return 0
    printf '%s [%s] %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$level" "$msg" >> "$AGENT_LOG" || return 0
    log_trim_in_place "$AGENT_LOG" || true
    return 0
}

# 每个探针失败都给出含义，便于区分本地入站与边缘问题。
probe_log() {
    local where=$1 meaning
    case "${WS_LAST_CODE:-000}" in
        101) meaning="WebSocket 通" ;; 000) meaning="连接失败/超时（本地检查 sing-box；远端检查隧道/边缘）" ;;
        502|503|530) meaning="边缘通但源不可达（检查 sing-box）" ;; 404) meaning="路径不对" ;;
        429) meaning="quick tunnel 被限流" ;; *) meaning="非预期 HTTP 状态" ;;
    esac
    agent_log WARN "$where 探针 HTTP ${WS_LAST_CODE:-000}: $meaning"
}

# 规范化真实公网地址，排除本地、NAT、保留地址与 WARP 的私有地址。
location_ip_key() {
    local value=$1 i part first second missing result=""
    local -a blocks=() left=() right=() parts=()
    if [[ "$value" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
        IFS=. read -r -a blocks <<< "$value"
        for i in 0 1 2 3; do
            part=$((10#${blocks[i]})); [ "$part" -le 255 ] || return 1
            blocks[i]=$part
        done
        first=${blocks[0]}; second=${blocks[1]}
        if [ "$first" -eq 0 ] || [ "$first" -ge 224 ] || [ "$first" -eq 10 ] || [ "$first" -eq 127 ] ||
            { [ "$first" -eq 100 ] && [ "$second" -ge 64 ] && [ "$second" -le 127 ]; } ||
            { [ "$first" -eq 169 ] && [ "$second" -eq 254 ]; } ||
            { [ "$first" -eq 172 ] && [ "$second" -ge 16 ] && [ "$second" -le 31 ]; } ||
            { [ "$first" -eq 192 ] && { [ "$second" -eq 168 ] || { [ "$second" -eq 0 ] && { [ "${blocks[2]}" -eq 0 ] || [ "${blocks[2]}" -eq 2 ]; }; } || { [ "$second" -eq 88 ] && [ "${blocks[2]}" -eq 99 ]; }; }; } ||
            { [ "$first" -eq 198 ] && { [ "$second" -eq 18 ] || [ "$second" -eq 19 ] || { [ "$second" -eq 51 ] && [ "${blocks[2]}" -eq 100 ]; }; }; } ||
            { [ "$first" -eq 203 ] && [ "$second" -eq 0 ] && [ "${blocks[2]}" -eq 113 ]; }; then return 1; fi
        printf '%s.%s.%s.%s' "${blocks[@]}"
        return 0
    fi
    [[ "$value" =~ ^[0-9A-Fa-f:]{2,39}$ && "$value" != *:::* ]] || return 1
    [[ "$value" != :* || "$value" = ::* ]] && [[ "$value" != *: || "$value" = *:: ]] || return 1
    if [[ "$value" = *::* ]]; then
        part=${value#*::}; [[ "$part" != *::* ]] || return 1
        IFS=: read -r -a left <<< "${value%%::*}"
        IFS=: read -r -a right <<< "$part"
        missing=$((8-${#left[@]}-${#right[@]})); [ "$missing" -gt 0 ] || return 1
        parts=("${left[@]}")
        for ((i=0;i<missing;i++)); do parts+=(0); done
        parts+=("${right[@]}")
    else
        IFS=: read -r -a parts <<< "$value"
        [ "${#parts[@]}" -eq 8 ] && [[ "$value" != :* && "$value" != *: ]] || return 1
    fi
    for i in 0 1 2 3 4 5 6 7; do
        part=${parts[i]}; [[ "$part" =~ ^[0-9A-Fa-f]{1,4}$ ]] || return 1
        parts[i]=$((16#$part))
    done
    first=${parts[0]}; second=${parts[1]}
    [ "$first" -ge 8192 ] && [ "$first" -le 16383 ] || return 1
    [ "$first" -ne 8193 ] || [ "$second" -ne 3512 ] || return 1
    for part in "${parts[@]}"; do printf -v part '%x' "$part"; result+="${result:+:}$part"; done
    printf '%s' "$result"
}

location_interface_valid() {
    [[ "$1" =~ ^[A-Za-z0-9_.:-]{1,32}$ ]] || return 1
    case "$1" in lo|*[wW][aA][rR][pP]*|[wW][gG]*|[aA][wW][gG]*|[tT][uU][nN]*|[tT][aA][pP]*) return 1 ;; esac
    [ "$(cat "/sys/class/net/$1/type" 2>/dev/null)" = 1 ]
}

# 只读 main 默认路由；不改 WARP、路由表或系统代理。
location_select_route() {
    local family routes device address key preferred fallback_device="" fallback_family=""
    LOCATION_QUERY_MODE=""; LOCATION_QUERY_IP=""; LOCATION_QUERY_INTERFACE=""; LOCATION_QUERY_FAMILY=""
    for family in 4 6; do
        routes=""
        if has ip; then
            routes=$(ip -"$family" route show table main default 2>/dev/null | awk '
                !/linkdown/ {dev="";metric=0;src="-";for(i=1;i<=NF;i++){if($i=="dev")dev=$(i+1);if($i=="metric")metric=$(i+1);if($i=="src")src=$(i+1)} if(dev!="")print metric,dev,src}' | sort -sn)
        fi
        if [ -z "$routes" ] && [ "$family" = 4 ] && [ -r /proc/net/route ]; then
            routes=$(awk 'NR>1 && $2=="00000000" && $8=="00000000" && $4 ~ /[13579bBdDfF]$/ {print $7,$1,"-"}' /proc/net/route | sort -sn)
        fi
        while read -r key device preferred; do
            location_interface_valid "$device" || continue
            if [ -z "$fallback_device" ]; then fallback_device=$device; fallback_family=$family; fi
            if has ip; then
                while read -r address; do
                    key=$(location_ip_key "$address") || continue
                    LOCATION_QUERY_MODE=ip; LOCATION_QUERY_IP=$key; LOCATION_QUERY_INTERFACE=$device; LOCATION_QUERY_FAMILY=$family
                    return 0
                done < <(ip -"$family" -o address show dev "$device" scope global 2>/dev/null | awk -v preferred="$preferred" '
                    !/ tentative | dadfailed | deprecated / {split($4,a,"/");if(a[1]==preferred)print a[1];else other=other a[1] "\n"} END {printf "%s",other}')
            fi
            # 每种地址族只使用首选普通默认接口，不拿备用网卡的位置替代 NAT 出口。
            break
        done <<< "$routes"
    done
    [ -n "$fallback_device" ] || return 1
    LOCATION_QUERY_MODE=interface; LOCATION_QUERY_INTERFACE=$fallback_device; LOCATION_QUERY_FAMILY=$fallback_family
}

location_country_valid() {
    [[ "$1" =~ ^[A-Z]{2}$ ]] || return 1
    case ' AD AE AF AG AI AL AM AO AQ AR AS AT AU AW AX AZ BA BB BD BE BF BG BH BI BJ BL BM BN BO BQ BR BS BT BV BW BY BZ CA CC CD CF CG CH CI CK CL CM CN CO CR CU CV CW CX CY CZ DE DJ DK DM DO DZ EC EE EG EH ER ES ET FI FJ FK FM FO FR GA GB GD GE GF GG GH GI GL GM GN GP GQ GR GS GT GU GW GY HK HM HN HR HT HU ID IE IL IM IN IO IQ IR IS IT JE JM JO JP KE KG KH KI KM KN KP KR KW KY KZ LA LB LC LI LK LR LS LT LU LV LY MA MC MD ME MF MG MH MK ML MM MN MO MP MQ MR MS MT MU MV MW MX MY MZ NA NC NE NF NG NI NL NO NP NR NU NZ OM PA PE PF PG PH PK PL PM PN PR PS PT PW PY QA RE RO RS RU RW SA SB SC SD SE SG SH SI SJ SK SL SM SN SO SR SS ST SV SX SY SZ TC TD TF TG TH TJ TK TL TM TN TO TR TT TV TW TZ UA UG UM US UY UZ VA VC VE VG VI VN VU WF WS XK YE YT ZA ZM ZW ' in
        *" $1 "*) return 0 ;;
    esac
    return 1
}

location_region_name_valid() {
    local LC_ALL=C control=$'\xc2[\x80-\x9f]'
    [[ "${#1}" -le 128 && ! "$1" =~ [[:cntrl:]] && ! "$1" =~ $control ]]
}

# 提取 JSON 根对象的字符串字段，ASN 可允许数字；不增加 jq/Python 依赖。
location_json_string() {
    LC_ALL=C awk -v wanted="$1" -v numeric="${2:-0}" '
    function hex(s,    n,i,d) {
        n=0
        for (i=1;i<=length(s);i++) {
            d=index("0123456789abcdef",tolower(substr(s,i,1)))-1
            if (d<0) return -1
            n=n*16+d
        }
        return n
    }
    function utf8(c) {
        if (c<128) return sprintf("%c",c)
        if (c<2048) return sprintf("%c%c",192+int(c/64),128+c%64)
        if (c<65536) return sprintf("%c%c%c",224+int(c/4096),128+int(c/64)%64,128+c%64)
        return sprintf("%c%c%c%c",240+int(c/262144),128+int(c/4096)%64,128+int(c/64)%64,128+c%64)
    }
    function string_value(allow_control,    out,c,code,low) {
        out=""; string_ok=0
        for (pos++;pos<=length(data);pos++) {
            c=substr(data,pos,1)
            if (c=="\"") { pos++; string_ok=1; return out }
            if (c=="\\") {
                c=substr(data,++pos,1)
                if (c=="u") {
                    if (length(substr(data,pos+1,4))!=4) return ""
                    code=hex(substr(data,pos+1,4)); pos+=4
                    if (code<0) return ""
                    if (code>=55296 && code<=56319) {
                        if (substr(data,pos+1,2)!="\\u") return ""
                        low=hex(substr(data,pos+3,4))
                        if (low<56320 || low>57343) return ""
                        code=65536+(code-55296)*1024+low-56320; pos+=6
                    } else if (code>=56320 && code<=57343) return ""
                    if (code<32 || (code>=127 && code<=159)) {
                        if (!allow_control) return ""
                        out=out " "
                    } else out=out utf8(code)
                } else if (c=="\"" || c=="\\" || c=="/") out=out c
                else if (c=="b" || c=="f" || c=="n" || c=="r" || c=="t") {
                    if (!allow_control) return ""
                    out=out " "
                } else return ""
            } else {
                if (c ~ /[[:cntrl:]]/) return ""
                out=out c
            }
        }
        return ""
    }
    { data=data $0 "\n" }
    END {
        if (data !~ /^[[:space:]]*\{/ || data !~ /\}[[:space:]]*$/) exit 1
        pos=1; depth=0
        while (pos<=length(data)) {
            c=substr(data,pos,1)
            if (c=="\"") {
                value=string_value(1)
                if (!string_ok) exit 1
                if (depth==1 && value==wanted) {
                    while (substr(data,pos,1) ~ /[[:space:]]/) pos++
                    if (substr(data,pos,1)==":") {
                        pos++
                        while (substr(data,pos,1) ~ /[[:space:]]/) pos++
                        if (substr(data,pos,1)!="\"") {
                            if (!numeric || !match(substr(data,pos),/^[0-9]+/)) exit 1
                            value=substr(data,pos,RLENGTH)
                            if (substr(data,pos+RLENGTH) !~ /^[[:space:]]*[,}]/) exit 1
                            printf "%s",value; exit 0
                        }
                        value=string_value()
                        if (!string_ok) exit 1
                        printf "%s",value; exit 0
                    }
                }
                continue
            }
            if (c=="{" || c=="[") depth++
            else if (c=="}" || c=="]") depth--
            pos++
        }
        exit 1
    }'
}

location_parse() {
    local response=$1 country region="" name="" status
    if [ "${5:-}" = success ]; then
        status=$(printf '%s' "$response" | location_json_string status) || return 1
        [ "$status" = success ] || return 1
    fi
    country=$(printf '%s' "$response" | location_json_string "$2" | LC_ALL=C tr '[:lower:]' '[:upper:]')
    location_country_valid "$country" || return 1
    [ -z "$3" ] || region=$(printf '%s' "$response" | location_json_string "$3")
    [[ "$region" =~ ^[A-Za-z0-9_-]{1,16}$ ]] || region=""
    [ -z "$4" ] || name=$(printf '%s' "$response" | location_json_string "$4")
    location_region_name_valid "$name" || name=""
    LOCATION_NEXT_COUNTRY=$country; LOCATION_NEXT_REGION=$region; LOCATION_NEXT_REGION_NAME=$name
}

# 国家、地区和缓存时间一次原子保存，失败保留整组旧位置。
location_cache_save() {
    local tmp reset=${10:-0}
    umask 077
    tmp=$(mktemp "${AGENT_ENV}.XXXXXX") || return 1
    if [ -f "$AGENT_ENV" ]; then
        awk -v reset="$reset" '!/^(COUNTRY|REGION|REGION_NAME|LOCATION_TS|LOCATION_SOURCE|LOCATION_ATTEMPT_TS|LOCATION_POLICY|LOCATION_IP|LOCATION_INTERFACE|LOCATION_METHOD)=/ && !(reset==1 && /^LAST_REPORTED_DOMAIN=/)' "$AGENT_ENV" > "$tmp" || { rm -f "$tmp"; return 1; }
    fi
    if ! printf 'COUNTRY=%s\nREGION=%s\nREGION_NAME=%s\nLOCATION_TS=%s\nLOCATION_SOURCE=%s\nLOCATION_ATTEMPT_TS=%s\nLOCATION_POLICY=native-v1\nLOCATION_IP=%s\nLOCATION_INTERFACE=%s\nLOCATION_METHOD=%s\n' "$1" "$2" "$3" "$4" "$5" "$6" "$7" "$8" "$9" >> "$tmp"; then
        rm -f "$tmp"; return 1
    fi
    if [ "$reset" = 1 ]; then printf 'LAST_REPORTED_DOMAIN=\n' >> "$tmp" || { rm -f "$tmp"; return 1; }; fi
    if ! chmod 600 "$tmp" || ! mv -f "$tmp" "$AGENT_ENV"; then
        rm -f "$tmp"; return 1
    fi
}

location_verify_response() {
    local response=$1 value key owners="" asn field known=0
    value=$(printf '%s' "$response" | location_json_string "$2") || return 1
    key=$(location_ip_key "$value") || return 1
    if [ "$LOCATION_QUERY_MODE" = ip ] && [ "$key" != "$LOCATION_QUERY_IP" ]; then return 1; fi
    asn=$(printf '%s' "$response" | location_json_string asn 1)
    if [[ "$asn" =~ ^[0-9]{1,10}$ ]] && [ "$((10#$asn))" -gt 0 ] && [ "$((10#$asn))" -le 4294967295 ]; then known=1; fi
    for field in org as isp organization asn_organization; do
        value=$(printf '%s' "$response" | location_json_string "$field")
        case "$value" in ''|Unknown|unknown|null|None|none|N/A|n/a) continue ;; esac
        owners+=" $value"; known=1
    done
    if [[ "$owners" =~ [Cc][Ll][Oo][Uu][Dd][Ff][Ll][Aa][Rr][Ee] ]] ||
        [[ "$asn" =~ (^|[^0-9])13335([^0-9]|$) ]] ||
        [[ "$owners" =~ [Aa][Ss][[:space:]]*13335([^0-9]|$) ]]; then return 1; fi
    [ "$known" = 1 ] || return 1
    LOCATION_NEXT_IP=$key
}

location_fetch() {
    local url=$1 response rc LC_ALL=C
    local -a binding=()
    shift
    [ "${STOP:-0}" != 1 ] || return 1
    if [ "$LOCATION_QUERY_MODE" = interface ]; then
        binding=("-$LOCATION_QUERY_FAMILY" --interface "if!$LOCATION_QUERY_INTERFACE")
    fi
    # head 另设读取上限，兼容旧 curl 对无 Content-Length 响应的限制不足。
    response=$(
        exec 7>&- 9>&-
        set -o pipefail
        curl -q -fsS --proxy '' --noproxy '*' --connect-timeout 3 -m 6 --max-filesize 4096 -A "tunel/$TUNEL_VERSION" "${binding[@]}" "$@" "$url" 2>/dev/null | head -c 4097
    ); rc=$?
    [ "$rc" = 0 ] && [ "${#response}" -le 4096 ] || return 1
    printf '%s' "$response"
}

# 指定真实公网 IP 查询；NAT 只绑定普通接口发现出口，不放宽为 WARP 默认路由。
location_refresh() {
    local now age provider response endpoint source="" reset=${LOCATION_NEEDS_REPORT:-0} route_ok=0
    location_select_route && route_ok=1
    now=$(date +%s)
    age=$((now-10#${LOCATION_TS:-0}))
    if [ "${LOCATION_VERIFIED:-0}" = 1 ] && [ -n "${LOCATION_SOURCE:-}" ] && [ "$age" -ge 0 ] && [ "$age" -lt 86400 ] &&
        [ "$route_ok" = 1 ] && [ "$LOCATION_INTERFACE" = "$LOCATION_QUERY_INTERFACE" ] && [ "$LOCATION_METHOD" = "$LOCATION_QUERY_MODE" ] &&
        { [ "$LOCATION_QUERY_MODE" != ip ] || [ "$LOCATION_IP" = "$LOCATION_QUERY_IP" ]; }; then return 0; fi
    age=$((now-10#${LOCATION_ATTEMPT_TS:-0}))
    if [ "${LOCATION_ATTEMPT_TS:-0}" != 0 ] && [ "$age" -ge 0 ] && [ "$age" -lt 300 ]; then return 0; fi
    age=$((now-10#$LOCATION_MEMORY_ATTEMPT_TS))
    if [ "$LOCATION_MEMORY_ATTEMPT_TS" != 0 ] && [ "$age" -ge 0 ] && [ "$age" -lt 300 ]; then return 0; fi
    LOCATION_MEMORY_ATTEMPT_TS=$now
    for provider in ipinfo ip.sb ip-api ip-api-http worker; do
        [ "${STOP:-0}" != 1 ] || return 0
        [ "$route_ok" = 1 ] || break
        resource_maintenance "$(date +%s)"
        case "$provider" in
            ipinfo)
                endpoint='https://ipinfo.io/json'
                [ "$LOCATION_QUERY_MODE" != ip ] || endpoint="https://ipinfo.io/$LOCATION_QUERY_IP/json"
                response=$(location_fetch "$endpoint") || continue
                location_verify_response "$response" ip || continue
                location_parse "$response" country '' region || continue ;;
            ip.sb)
                endpoint='https://api.ip.sb/geoip'
                [ "$LOCATION_QUERY_MODE" != ip ] || endpoint+="/$LOCATION_QUERY_IP"
                response=$(location_fetch "$endpoint") || continue
                location_verify_response "$response" ip || continue
                location_parse "$response" country_code region_code region || continue ;;
            ip-api|ip-api-http)
                if [ "$provider" = ip-api ]; then endpoint='https://ip-api.com/json'
                else endpoint='http://ip-api.com/json'; fi
                [ "$LOCATION_QUERY_MODE" != ip ] || endpoint+="/$LOCATION_QUERY_IP"
                response=$(location_fetch "$endpoint") || continue
                location_verify_response "$response" query || continue
                location_parse "$response" countryCode region regionName success || continue ;;
            worker)
                [ "$LOCATION_QUERY_MODE" = interface ] || continue
                [ -n "$REPORT_URL" ] && [ -n "$REPORT_TOKEN" ] || continue
                response=$(location_fetch "${REPORT_URL%/api/report}/api/location" -H "Authorization: Bearer $REPORT_TOKEN") || continue
                location_verify_response "$response" ip || continue
                location_parse "$response" country region regionName || continue ;;
        esac
        source=$provider; [ "$source" != ip-api-http ] || source=ip-api
        break
    done
    [ "${STOP:-0}" != 1 ] || return 0
    now=$(date +%s)
    if [ -z "$source" ]; then
        location_cache_save "${COUNTRY:-}" "${REGION:-}" "${REGION_NAME:-}" "${LOCATION_TS:-0}" "${LOCATION_SOURCE:-}" "$now" "${LOCATION_IP:-}" "${LOCATION_INTERFACE:-}" "${LOCATION_METHOD:-}" "$reset" || return 0
        LOCATION_ATTEMPT_TS=$now; LOCATION_POLICY=native-v1; LOCATION_NEEDS_REPORT=0
        [ "$reset" != 1 ] || LAST_REPORTED_DOMAIN=""
        if [ "$reset" = 1 ] && [ -n "${DOMAIN:-}" ]; then nodes_refresh || true; fi
        return 0
    fi
    if [ "${LOCATION_VERIFIED:-0}" != 1 ] || [ "$COUNTRY" != "$LOCATION_NEXT_COUNTRY" ] || [ "$REGION" != "$LOCATION_NEXT_REGION" ] || [ "$REGION_NAME" != "$LOCATION_NEXT_REGION_NAME" ]; then reset=1; fi
    location_cache_save "$LOCATION_NEXT_COUNTRY" "$LOCATION_NEXT_REGION" "$LOCATION_NEXT_REGION_NAME" "$now" "$source" "$now" "$LOCATION_NEXT_IP" "$LOCATION_QUERY_INTERFACE" "$LOCATION_QUERY_MODE" "$reset" || return 0
    COUNTRY=$LOCATION_NEXT_COUNTRY; REGION=$LOCATION_NEXT_REGION; REGION_NAME=$LOCATION_NEXT_REGION_NAME
    LOCATION_TS=$now; LOCATION_SOURCE=$source; LOCATION_ATTEMPT_TS=$now; LOCATION_POLICY=native-v1
    LOCATION_IP=$LOCATION_NEXT_IP; LOCATION_INTERFACE=$LOCATION_QUERY_INTERFACE; LOCATION_METHOD=$LOCATION_QUERY_MODE
    LOCATION_VERIFIED=1; LOCATION_NEEDS_REPORT=0
    [ "$reset" != 1 ] || LAST_REPORTED_DOMAIN=""
    [ -z "${DOMAIN:-}" ] || nodes_refresh || true
}

# 发送失败仅对 5xx/000 重试，不修改已上报标记，下一轮可补发。
report_node() {
    agent_load
    location_refresh
    [ -n "$REPORT_URL" ] || return 0
    local body resp code now link attempt delay verified=false
    [ -n "$REPORT_TOKEN" ] && [ -n "$DOMAIN" ] || { agent_log ERR "上报配置缺少 token 或域名"; return 1; }
    umask 077
    body=$(mktemp) || return 1; resp=$(mktemp) || { rm -f "$body"; return 1; }
    now=$(date +%s)
    link=$(vmess_link "$DOMAIN" "$UUID" "$WS_PATH" "${CFIP:-$DOMAIN}" "$(node_display_name)")
    [ "${LOCATION_VERIFIED:-0}" != 1 ] || verified=true
    printf '{"id":"%s","name":"%s","mode":"%s","link":"%s","host":"%s","addr":"%s","port":443,"uuid":"%s","path":"%s","country":"%s","region":"%s","regionName":"%s","locationVerified":%s,"net":"ws","tls":true,"sni":"%s","version":"%s","ts":%s}' \
        "$(json_escape "$NODE_ID")" "$(json_escape "$NODE_NAME")" "$MODE" "$(json_escape "$link")" "$DOMAIN" "$(json_escape "${CFIP:-$DOMAIN}")" "$UUID" "$(json_escape "$WS_PATH")" "${COUNTRY:-}" "${REGION:-}" "$(json_escape "${REGION_NAME:-}")" "$verified" "$DOMAIN" "$TUNEL_VERSION" "$now" > "$body"
    for attempt in 0 1 2 3; do
        [ "${STOP:-0}" != 1 ] || break
        resource_maintenance "$(date +%s)"
        code=$(exec 9>&-; curl -sS -m 15 --max-filesize 65536 -o "$resp" -w '%{http_code}' -X POST -H "Authorization: Bearer $REPORT_TOKEN" -H 'Content-Type: application/json' --data-binary "@$body" "$REPORT_URL" 9>&- 2>/dev/null)
        code=${code:-000}
        case "$code" in
            200)
                # skipped 也算成功，服务端已保存相同节点。
                env_set "$AGENT_ENV" LAST_REPORT_TS "$(date +%s)"
                env_set "$AGENT_ENV" LAST_REPORTED_DOMAIN "$DOMAIN"
                LAST_REPORTED_DOMAIN=$DOMAIN
                agent_log INFO "上报成功: $NODE_ID / $DOMAIN"
                rm -f "$body" "$resp"; return 0 ;;
            401) agent_log ERR "上报 token 被拒绝"; break ;;
            4*) agent_log ERR "上报 HTTP $code: $(head -c 200 "$resp")"; break ;;
            5*|000)
                # 三段退避抑制短时错误，预算耗尽仍保留待补发身份。
                if [ "$attempt" -eq 3 ]; then break; fi
                case "$attempt" in 0) delay=5 ;; 1) delay=15 ;; 2) delay=45 ;; esac
                agent_log WARN "上报 HTTP $code，${delay}s 后重试"
                agent_sleep "$delay" || break ;;
            *) agent_log ERR "上报返回非预期 HTTP $code"; break ;;
        esac
    done
    agent_log ERR "上报失败: $NODE_ID / $DOMAIN（保留待补发状态）"
    rm -f "$body" "$resp"
    return 1
}

# 注销只在卸载时调用，网络失败记录后继续本地清理。
report_delete() {
    agent_load
    [ -n "$REPORT_URL" ] && [ -n "$NODE_ID" ] || return 0
    local body resp code
    umask 077
    body=$(mktemp) || return 1; resp=$(mktemp) || { rm -f "$body"; return 1; }
    printf '{"id":"%s"}' "$(json_escape "$NODE_ID")" > "$body"
    code=$(exec 9>&-; curl -sS -m 15 --max-filesize 65536 -o "$resp" -w '%{http_code}' -X POST -H "Authorization: Bearer $REPORT_TOKEN" -H 'Content-Type: application/json' --data-binary "@$body" "${REPORT_URL%/api/report}/api/node/delete" 2>/dev/null)
    rm -f "$body" "$resp"
    if [ "$code" = 200 ]; then agent_log INFO "节点已注销: $NODE_ID"; else agent_log WARN "注销失败 HTTP ${code:-000}，请在 Worker 面板删除节点"; return 1; fi
}

# 所有等待最多五秒一段，TERM 可以尽快停止守护的退避和重试。
agent_sleep() {
    local left=$1 chunk
    while [ "$left" -gt 0 ]; do
        [ "${STOP:-0}" != 1 ] || return 1
        resource_maintenance "$(date +%s)"
        chunk=5; [ "$left" -ge 5 ] || chunk=$left
        sleep "$chunk" 9>&-; left=$((left-chunk))
    done
    [ "${STOP:-0}" != 1 ]
}

# 自动随机分配用 pick_free_port；显式冲突只有交互场景再问一次。
install_port_pick() {
    local pref=${1:-} p
    if [ -n "$pref" ] && { ! valid_port "$pref" || check_port "$(norm_port "$pref")"; }; then
        echo "错误: 端口不可用: $pref" >&2
        if [ -n "$NONINTERACTIVE" ] || [ ! -t 0 ]; then return 4; fi
        pref=$(ask "请输入新端口（回车随机）: " "")
    fi
    p=$(pick_free_port "$pref") || { echo "错误: 未找到可用端口" >&2; return 4; }
    printf '%s' "$p"
}

# 持续守护必须有 curl 和 flock，依赖失败使用规定退出码 3。
dependencies_ensure() {
    install_soft curl || return 3
    if ! has flock; then
        if [ "$TUNEL_SYSTEM" = 1 ]; then install_soft util-linux || return 3
        else echo "错误: 用户/便携模式缺少依赖 flock，请预装 util-linux 后重试。" >&2; return 3; fi
    fi
    local tool
    for tool in curl tar base64 sha256sum flock nohup awk sed grep tr; do
        has "$tool" || { echo "错误: 缺少依赖 $tool" >&2; return 3; }
    done
}

# 保存本次安装身份；上报配置可沿用旧值，未指定的检查周期统一为两小时。
install_env_write() {
    local key val
    env_set "$AGENT_ENV" MODE "$MODE"
    env_set "$AGENT_ENV" PORT "$PORT"
    env_set "$AGENT_ENV" UUID "$UUID"
    env_set "$AGENT_ENV" PATH "$WS_PATH"
    env_set "$AGENT_ENV" DOMAIN "$DOMAIN"
    CORE_LOGS=1
    [ "${NO_AGENT:-0}" != 1 ] || CORE_LOGS=0
    env_set "$AGENT_ENV" CORE_LOGS "$CORE_LOGS" || return 1
    for key in NAME CFIP NODE_ID REPORT_URL REPORT_TOKEN CHECK WATCH; do
        case "$key" in
            NAME) val=${OPT_NAME:-}; key=NODE_NAME ;; CFIP) val=${OPT_CFIP:-} ;;
            NODE_ID) val=${OPT_NODE_ID:-} ;; REPORT_URL) val=${OPT_REPORT_URL:-} ;; REPORT_TOKEN) val=${OPT_REPORT_TOKEN:-} ;;
            CHECK) val=${OPT_CHECK:-$DEFAULT_CHECK_INTERVAL}; key=CHECK_INTERVAL ;;
            WATCH) val=${OPT_WATCH:-$DEFAULT_CHECK_INTERVAL}; key=WATCH_INTERVAL ;;
        esac
        [ -z "$val" ] || env_set "$AGENT_ENV" "$key" "$val" || return 1
    done
    # 重装即使固定域名没变，UUID/PATH 已变，必须保留待上报标记。
    env_set "$AGENT_ENV" LAST_REPORTED_DOMAIN ""
    env_set "$AGENT_ENV" LAST_DOMAIN_TS "$(date +%s)"
    agent_load
}

# quick/fixed 共用安装顺序，避免两套分支权限与服务参数不一致。
install_tunnel() {
    local newmode=$1 pref=${2:-} domain=${3:-} cred=${4:-} chosen rc
    chosen=$(install_port_pick "$pref") || return $?
    dependencies_ensure || return 3
    agent_env_ensure || return 1
    install_cloudflared && install_singbox_core || return 3
    echo "正在停止旧服务并准备隧道配置…"
    # 先停 agent 再替换隧道，防止监视线程上传中间配置。
    svc_remove "$SVC_AGENT" "$SVC_AGENT"
    # 清理旧无 init 自启，--no-agent 才不会在下次开机又被旧钩子装回。
    boot_hook_remove
    svc_stop "$SVC_ARGO" "$SVC_ARGO"; svc_stop "$SVC_SB" "$SVC_SB"
    MODE=$newmode; PORT=$chosen; DOMAIN=$domain; UUID=$(rand_uuid); WS_PATH="/vmess-$(rand_token)"
    install_env_write || return 1
    metrics_port_ensure || return $?
    if [ "$MODE" = fixed ]; then
        if [[ "$cred" == *TunnelSecret* ]]; then
            # 本地 JSON 模式需要更新 ingress 指向本次新端口。
            argo_write_creds "$cred" "$DOMAIN" "$PORT" || { echo "错误: JSON 凭据缺少 TunnelID/TunnelSecret" >&2; return 1; }
            rm -f "$ARGO_TOKEN_FILE"
        else
            # token 模式不把密钥写进任何世界可读的服务文件。
            umask 077; printf '%s\n' "$cred" > "$ARGO_TOKEN_FILE"; chmod 600 "$ARGO_TOKEN_FILE"
            rm -f "$TUNNEL_JSON" "$TUNNEL_YML"
        fi
    else
        rm -f "$ARGO_TOKEN_FILE" "$TUNNEL_JSON" "$TUNNEL_YML"
    fi
    echo "正在生成 sing-box 配置: $SB_CFG"
    sb_write_config "$PORT" "$UUID" "$WS_PATH" || return 1
    echo "正在启动 sing-box 服务…"
    sb_service_up || return 1
    : > "$ARGO_LOG"
    echo "正在启动 cloudflared 服务…"
    argo_service_configure || return 1
    echo "正在获取隧道域名…"
    wait_new_domain "" 90 >/dev/null || { agent_log ERR "隧道域名获取失败，请检查 /quicktunnel 与 $ARGO_LOG"; return 5; }
    domain=$WAIT_DOMAIN
    DOMAIN=$domain; env_set "$AGENT_ENV" DOMAIN "$DOMAIN"; nodes_refresh
    rc=0
    if install_self; then
        # 首次成功安装立即上报，守护启动只会补发失败或不同的域名。
        report_node || true
        # 没有上报配置也守护独立隧道，同时负责文本日志限量。
        if [ "${NO_AGENT:-0}" != 1 ]; then agent_start || rc=$?; fi
    else
        rc=3
    fi
    # 节点已生成就统一展示，脚本落地或守护失败仍保留原退出码。
    if [ "$rc" = 0 ]; then echo "隧道安装完成（$MODE）"
    else echo "隧道已建立，但脚本或守护初始化失败（退出码 $rc），请查看上方错误。" >&2; fi
    show_node
    return "$rc"
}

# 保留菜单调用签名，非交互命令将全部参数提前校验。
install_quick() { install_tunnel quick "${1:-}"; }

# 固定隧道凭据既支持 token，也支持菜单粘贴 JSON。
install_fixed() {
    [[ "$2" =~ ^[A-Za-z0-9.-]{1,253}$ ]] && [ -n "$3" ] || { echo "错误: 固定隧道必须提供域名与凭据" >&2; return 2; }
    install_tunnel fixed "${1:-}" "$2" "$3"
}

# 重启后 quick 必须拿到不同的域名；fixed 的域名天然保持不变。
argo_restart_controlled() {
    [ "${STOP:-0}" != 1 ] || return 1
    local old=$DOMAIN d
    : > "$ARGO_LOG"
    svc_restart "$SVC_ARGO" "$SVC_ARGO" || { agent_log ERR "cloudflared 重启失败"; return 1; }
    [ "$MODE" != fixed ] || old=""
    wait_new_domain "$old" 60 >/dev/null || { agent_log ERR "重启后获取新域名超时"; return 5; }
    d=$WAIT_DOMAIN
    DOMAIN=$d
    env_set "$AGENT_ENV" DOMAIN "$DOMAIN" && env_set "$AGENT_ENV" LAST_DOMAIN_TS "$(date +%s)" || {
        agent_log ERR "新域名保存失败: $AGENT_ENV"; return 1
    }
    nodes_refresh || { agent_log ERR "新域名节点文件更新失败: $NODE_DIR"; return 1; }
    agent_log INFO "隧道已重建，当前域名: $DOMAIN"
    return 0
}

# 手动重启是一条受控操作，允许强制上报固定域名。
tunnel_refresh_domain() {
    agent_env_ensure || return 1
    [ -n "$MODE" ] || { echo "错误: 请先安装隧道" >&2; return 1; }
    argo_restart_controlled || return $?
    report_node || return 1
    show_node
}

# 检查时间独立于配置，删除 state 后下一轮立即检查连接。
agent_state_load() {
    LAST_CHECK_TS=$(env_get "$AGENT_STATE" LAST_CHECK_TS); LAST_CHECK_TS=${LAST_CHECK_TS:-0}
    LAST_WATCH_TS=$(env_get "$AGENT_STATE" LAST_WATCH_TS); LAST_WATCH_TS=${LAST_WATCH_TS:-0}
    [[ "$LAST_CHECK_TS" =~ ^[0-9]{1,12}$ ]] || LAST_CHECK_TS=0
    [[ "$LAST_WATCH_TS" =~ ^[0-9]{1,12}$ ]] || LAST_WATCH_TS=0
    AGENT_STATE_SAVED_CHECK_TS=""; AGENT_STATE_SAVED_WATCH_TS=""; AGENT_STATE_RETRY_AFTER=0
    if [ -f "$AGENT_STATE" ]; then
        AGENT_STATE_SAVED_CHECK_TS=$LAST_CHECK_TS
        AGENT_STATE_SAVED_WATCH_TS=$LAST_WATCH_TS
    fi
}

# 时间未变化时不写盘；变化时一次原子保存，写失败也不每五秒反复创建临时文件。
agent_state_save() {
    local now tmp
    if [ -f "$AGENT_STATE" ] && [ "$LAST_CHECK_TS" = "${AGENT_STATE_SAVED_CHECK_TS:-}" ] && [ "$LAST_WATCH_TS" = "${AGENT_STATE_SAVED_WATCH_TS:-}" ]; then return 0; fi
    now=${1:-$(date +%s)}
    [ "$now" -ge "${AGENT_STATE_RETRY_AFTER:-0}" ] || return 0
    AGENT_STATE_RETRY_AFTER=$((now+RESOURCE_MAINTENANCE_INTERVAL))
    umask 077
    tmp=$(mktemp "$TMP_DIR/agent-state.XXXXXX") || return 1
    if ! printf 'LAST_CHECK_TS=%s\nLAST_WATCH_TS=%s\n' "$LAST_CHECK_TS" "$LAST_WATCH_TS" > "$tmp" || ! chmod 600 "$tmp" || ! mv -f "$tmp" "$AGENT_STATE"; then
        rm -f "$tmp"
        return 1
    fi
    AGENT_STATE_SAVED_CHECK_TS=$LAST_CHECK_TS
    AGENT_STATE_SAVED_WATCH_TS=$LAST_WATCH_TS
    AGENT_STATE_RETRY_AFTER=0
    return 0
}

# 每轮只判断一次连接，任一失败直接交给隧道重建，不重试探测。
remote_probe_once() {
    [ "${STOP:-0}" != 1 ] || return 1
    if ! svc_running "$SVC_ARGO" "$SVC_ARGO"; then
        agent_log WARN "cloudflared 未运行"; return 1
    fi
    if [ -z "$DOMAIN" ]; then
        agent_log WARN "当前隧道没有域名"; return 1
    fi
    if ! edge_ready; then
        agent_log WARN "CF 连接未就绪"; return 1
    fi
    if ws_probe "https://$DOMAIN$WS_PATH"; then return 0; fi
    probe_log 远端
    return 1
}

# 启动时先确保依赖，再从当前进程获取域名；已有相同上报不写 Worker。
agent_startup() {
    agent_env_ensure || return 1
    [[ "$MODE" = quick || "$MODE" = fixed ]] && valid_port "$PORT" || { agent_log ERR "守护缺少已安装的隧道配置"; return 1; }
    if ! svc_running "$SVC_SB" "$SVC_SB"; then svc_restart "$SVC_SB" "$SVC_SB" || sb_service_up || return 1; fi
    if ! svc_running "$SVC_ARGO" "$SVC_ARGO"; then
        : > "$ARGO_LOG"
        svc_restart "$SVC_ARGO" "$SVC_ARGO" || argo_service_configure || return 1
    fi
    local d
    wait_new_domain "" 90 >/dev/null || { agent_log ERR "守护启动未取得域名，下一轮自检继续恢复"; return 0; }
    d=$WAIT_DOMAIN
    [ "${STOP:-0}" != 1 ] || return 0
    if [ "$d" != "$DOMAIN" ]; then
        agent_log INFO "启动域名变化: $DOMAIN -> $d"
        DOMAIN=$d; env_set "$AGENT_ENV" DOMAIN "$DOMAIN"; env_set "$AGENT_ENV" LAST_DOMAIN_TS "$(date +%s)"
        nodes_refresh
    fi
    location_refresh
    if [ "$DOMAIN" != "$LAST_REPORTED_DOMAIN" ]; then report_node || true; fi
}

# 自定义同步周期早于连接检查时，仅同步当前域名与待补发的变化。
agent_watch() {
    local now=$1 d
    if [ "$MODE" = quick ]; then
        d=$(domain_from_metrics 9>&-)
        if [ -n "$d" ] && [ "$d" != "$DOMAIN" ]; then
            agent_log INFO "域名变化: $DOMAIN -> $d"
            DOMAIN=$d; env_set "$AGENT_ENV" DOMAIN "$DOMAIN"; env_set "$AGENT_ENV" LAST_DOMAIN_TS "$now"
            nodes_refresh; WATCH_EMPTY_WARNED=0
        elif [ -z "$d" ]; then
            # 监视仅告警不恢复，避免短暂 metrics 不可用导致反复重启。
            if [ "${WATCH_EMPTY_WARNED:-0}" != 1 ]; then agent_log WARN "本机 metrics 暂无域名，等待远端自检"; WATCH_EMPTY_WARNED=1; fi
        else
            WATCH_EMPTY_WARNED=0
        fi
    fi
    # 上报失败不会更新 LAST_REPORTED_DOMAIN，这里只补发已知变更，不是心跳。
    if [ -n "$DOMAIN" ] && [ "$DOMAIN" != "$LAST_REPORTED_DOMAIN" ]; then report_node || true; fi
    LAST_WATCH_TS=$now
}

# 每两小时检查一次，连接失败直接重启 cloudflared，取得新域名后上报。
agent_check() {
    local now=$1 d
    LAST_CHECK_TS=$now; LAST_WATCH_TS=$now
    core_tmp_cleanup || true
    # 自动拉起的 cloudflared 可能已有新域名，先读取当前进程再检查外网连接。
    if svc_running "$SVC_ARGO" "$SVC_ARGO"; then
        d=$(get_domain 9>&-)
        if [ -n "$d" ] && [ "$d" != "$DOMAIN" ]; then
            agent_log INFO "域名变化: $DOMAIN -> $d"
            DOMAIN=$d; env_set "$AGENT_ENV" DOMAIN "$DOMAIN"; env_set "$AGENT_ENV" LAST_DOMAIN_TS "$now"
            nodes_refresh
        fi
    fi
    if remote_probe_once; then
        location_refresh
        # 连接正常时仅补发已知变化，不重复上传相同节点。
        if [ "$DOMAIN" != "$LAST_REPORTED_DOMAIN" ]; then report_node || true; fi
        return 0
    fi
    [ "${STOP:-0}" != 1 ] || return 1
    agent_log WARN "CF 连接检查失败，立即重建隧道"
    # 源服务停止或不通时一并拉起，保持原端口、UUID 和路径。
    if ! svc_running "$SVC_SB" "$SVC_SB"; then
        svc_restart "$SVC_SB" "$SVC_SB" || sb_service_up || agent_log ERR "sing-box 启动失败"
        agent_sleep 3 || return 1
    elif ! ws_probe "http://127.0.0.1:$PORT$WS_PATH"; then
        probe_log 本地
        svc_restart "$SVC_SB" "$SVC_SB" || agent_log ERR "sing-box 重启失败"
        agent_sleep 3 || return 1
    fi
    if ! argo_restart_controlled; then
        agent_log ERR "本轮隧道重建未完成，下一轮按 ${CHECK_INTERVAL}s 周期检查"
        return 1
    fi
    [ "${STOP:-0}" != 1 ] || return 1
    location_refresh
    # 新域名取得后立即同步，不再对新域名重复执行外网探测。
    if [ "$DOMAIN" != "$LAST_REPORTED_DOMAIN" ]; then
        if ! report_node; then
            agent_log WARN "新域名已取得，但上报失败，保留待补发状态"
        fi
    fi
    return 0
}

# 锁 FD 必须在整个守护生命周期持有，单独 flock 命令的临时重定向会过早释放。
agent_lock_acquire() {
    runtime_dirs_ensure || return 1
    has flock || { agent_log ERR "缺少 flock，无法启动单实例守护"; return 3; }
    exec 9>"$AGENT_LOCK" || { echo "错误: 无法创建守护锁 $AGENT_LOCK" >&2; return 1; }
    flock -n 9 || { exec 9>&-; return 10; }
}

# once 复用启动与连接检查路径，手动检查时也按单次失败立即重建。
agent_once() {
    local rc
    STOP=0; trap 'STOP=1' TERM INT
    agent_lock_acquire; rc=$?
    if [ "$rc" = 10 ]; then trap - TERM INT; return 0
    elif [ "$rc" != 0 ]; then trap - TERM INT; return "$rc"; fi
    agent_state_load
    resource_maintenance "$(date +%s)"
    if agent_startup; then
        agent_check "$(date +%s)"; rc=$?
        agent_state_save
    else rc=1; fi
    exec 9>&-
    trap - TERM INT
    return "$rc"
}

# 主循环供系统守护和容器前台共用，锁与退出处理由调用者持有。
agent_loop_body() {
    local now
    WATCH_EMPTY_WARNED=0
    agent_state_load
    RESOURCE_LAST_MAINTENANCE_TS=0
    resource_maintenance "$(date +%s)"
    agent_startup || return 1
    agent_log INFO "CF 连接检查启动: 每 ${CHECK_INTERVAL}s 检查，失败立即重建并上报新域名"
    while [ "$STOP" != 1 ]; do
        now=$(date +%s)
        resource_maintenance "$now"
        if [ "$((now-LAST_CHECK_TS))" -ge "$CHECK_INTERVAL" ]; then
            agent_check "$now"
        elif [ "$WATCH_INTERVAL" -gt 0 ] && [ "$((now-LAST_WATCH_TS))" -ge "$WATCH_INTERVAL" ]; then
            agent_watch "$now"
        fi
        agent_state_save "$now" || agent_log WARN "守护状态保存失败，将稍后重试: $AGENT_STATE"
        agent_sleep 5 || break
    done
    agent_log INFO "守护停止"
}

# 系统/后台入口只保持 agent，容器 run 则负责整个安装的生命周期。
agent_loop() {
    local rc
    STOP=0; trap 'STOP=1' TERM INT
    agent_lock_acquire; rc=$?
    if [ "$rc" = 10 ]; then trap - TERM INT; return 0
    elif [ "$rc" != 0 ]; then trap - TERM INT; return "$rc"; fi
    agent_loop_body; rc=$?
    exec 9>&-
    trap - TERM INT
    return "$rc"
}

# 前台停止时取消自己的长下载，PID/starttime 防止误伤其他命令。
run_request_stop() {
    STOP=1
    if [ -n "${RUN_FETCH_PID:-}" ] && [ -n "${RUN_FETCH_START:-}" ] && [ "$(proc_start_time "$RUN_FETCH_PID")" = "$RUN_FETCH_START" ]; then
        kill "$RUN_FETCH_PID" 2>/dev/null || true
    fi
}

# 前台仅接管本安装 PID 文件记录的组件，EXIT 也覆盖启动失败的清理。
run_cleanup() {
    [ "${RUN_ACTIVE:-0}" = 1 ] || return 0
    run_request_stop
    RUN_ACTIVE=0
    svc_stop "$SVC_ARGO" "$SVC_ARGO" || true
    svc_stop "$SVC_SB" "$SVC_SB" || true
    local pid start mode
    if [ -f "$RUN_DIR/$SVC_AGENT.pid" ]; then
        read -r pid start mode < "$RUN_DIR/$SVC_AGENT.pid"
        [ "$pid" != "$$" ] || [ "$start" != "$RUN_START_TIME" ] || rm -f "$RUN_DIR/$SVC_AGENT.pid"
    fi
    exec 9>&-
    exec 7>&-
}

# 容器 ENTRYPOINT 不注册后台 agent，获得单实例锁后一直运行至 TERM/INT。
run_foreground() {
    local rc pid start mode oldmp
    [ "$ENV_INIT" = none ] || { echo "错误: run 用于无 init/便携环境；系统服务请使用 tunel agent start。" >&2; return 1; }
    if [ ! -s "$AGENT_ENV" ] && [ ! -s "$NODE_DIR/quick.env" ] && [ ! -s "$NODE_DIR/fixed.env" ]; then
        echo "错误: run 需要已安装配置，请先执行 quick/fixed 并持久保存工作目录。" >&2; return 1
    fi
    dependencies_ensure || return 3
    agent_env_ensure || return 1
    [[ "$MODE" = quick || "$MODE" = fixed ]] && valid_port "$PORT" && [ -x "$SB_BIN" ] && [ -x "$CF_BIN" ] && [ -s "$SB_CFG" ] || {
        echo "错误: run 缺少有效的已安装隧道配置或核心，请先执行 quick/fixed。" >&2; return 1
    }
    # 生命周期锁先阻止两个 run 同时修改 ctl/PID，核心进程不会继承此 FD。
    exec 7>"$RUN_DIR/cf-tunel-run.lock" || { echo "错误: 无法创建前台锁 $RUN_DIR/cf-tunel-run.lock" >&2; return 1; }
    flock -n 7 || { exec 7>&-; echo "错误: 同一安装已有前台 run 运行。" >&2; return 1; }
    if [ -f "$RUN_DIR/$SVC_AGENT.pid" ]; then
        read -r pid start mode < "$RUN_DIR/$SVC_AGENT.pid"
        if [ "$mode" = run ] && [ -n "$start" ] && [ "$(proc_start_time "$pid")" = "$start" ]; then
            exec 7>&-; echo "错误: 同一安装已有前台 run 运行。" >&2; return 1
        fi
    fi
    install_self || { exec 7>&-; return 3; }
    # 重写 ctl 后再停同树旧 agent，避免继承旧控制脚本中不安全的 PID 行为。
    svc_wrapper "$SVC_AGENT" "\"$SELF_INSTALL\" agent loop" || { exec 7>&-; return 1; }
    svc_none_install "$SVC_AGENT" "$LOG_DIR" no-start || { exec 7>&-; return 1; }
    svc_stop "$SVC_AGENT" "$SVC_AGENT" || { exec 7>&-; return 1; }
    agent_lock_acquire; rc=$?
    if [ "$rc" = 10 ]; then exec 7>&-; echo "错误: 同一安装已有守护持有锁 $AGENT_LOCK，无法启动前台 run。" >&2; return 1
    elif [ "$rc" != 0 ]; then exec 7>&-; return "$rc"; fi
    RUN_START_TIME=$(proc_start_time "$$")
    [ -n "$RUN_START_TIME" ] || { exec 9>&-; exec 7>&-; echo "错误: 无法从 /proc 记录前台进程身份。" >&2; return 1; }
    RUN_ACTIVE=1; STOP=0
    trap 'run_request_stop' TERM INT
    trap 'run_cleanup' EXIT
    printf '%s %s run\n' "$$" "$RUN_START_TIME" > "$RUN_DIR/$SVC_AGENT.pid" || { run_cleanup; trap - EXIT TERM INT; return 1; }
    oldmp=$MP
    metrics_port_ensure || { rc=$?; run_cleanup; trap - EXIT TERM INT; return "$rc"; }
    if [ -z "$oldmp" ] || [ "$oldmp" != "$MP" ]; then svc_stop "$SVC_ARGO" "$SVC_ARGO" || true; fi
    # 先生成安全的核心控制器再复用启动逻辑，已运行组件会保持原域名。
    svc_wrapper "$SVC_SB" "\"$SB_BIN\" run -c \"$SB_CFG\"" && svc_none_install "$SVC_SB" "$LOG_DIR" no-start || {
        run_cleanup; trap - EXIT TERM INT; return 1
    }
    if [ "$MODE" = quick ]; then
        svc_wrapper "$SVC_ARGO" "/bin/sh -c 'exec \"$CF_BIN\" $(argo_quick_args "$PORT") >> \"$ARGO_LOG\" 2>&1'"
    elif [ -s "$ARGO_TOKEN_FILE" ]; then
        svc_wrapper "$SVC_ARGO" "/bin/sh -c 'exec \"$CF_BIN\" $(argo_token_args) >> \"$ARGO_LOG\" 2>&1'"
    elif [ -s "$TUNNEL_JSON" ] && [ -s "$TUNNEL_YML" ]; then
        svc_wrapper "$SVC_ARGO" "/bin/sh -c 'exec \"$CF_BIN\" $(argo_config_args) >> \"$ARGO_LOG\" 2>&1'"
    else
        echo "错误: 固定隧道凭据文件缺失。" >&2
        run_cleanup; trap - EXIT TERM INT; return 1
    fi
    rc=$?
    if [ "$rc" != 0 ] || ! svc_none_install "$SVC_ARGO" "$LOG_DIR" no-start; then
        run_cleanup; trap - EXIT TERM INT; return 1
    fi
    agent_log INFO "前台 run 启动: $WORK_DIR"
    agent_loop_body; rc=$?
    run_cleanup
    trap - EXIT TERM INT
    return "$rc"
}

# 服务首次配置或从旧 quick 升级时重写 metrics 参数，已有服务 start 不更换域名。
agent_start() {
    local oldmp rc
    dependencies_ensure || return 3
    agent_env_ensure || return 1
    [ -x "$SELF_INSTALL" ] || install_self || return 3
    [ -n "$MODE" ] || { echo "错误: 请先安装隧道" >&2; return 1; }
    oldmp=$MP
    metrics_port_ensure || return $?
    if [ -z "$oldmp" ] || [ "$oldmp" != "$MP" ]; then
        # 旧服务没 metrics 或端口失效，需要一次受控替换；只有域名变化才会上报。
        svc_stop "$SVC_ARGO" "$SVC_ARGO"
        sb_service_up && argo_service_configure || return 1
    fi
    if [ "$ENV_INIT" = none ]; then
        # @reboot 先启动依赖，再启动守护，不能指望 nohup 自动跨重启保留进程。
        "$BIN_DIR/$SVC_SB-ctl" start 9>&- >/dev/null 2>&1 || sb_service_up || return 1
        "$BIN_DIR/$SVC_ARGO-ctl" start 9>&- >/dev/null 2>&1 || argo_service_configure || return 1
        boot_hook_install || return 1
    fi
    svc_install "$SVC_AGENT" "$SVC_AGENT" "tunel agent (self-check / report)" "\"$SELF_INSTALL\" agent loop" "$LOG_DIR" always "network-online.target $SVC_SB.service $SVC_ARGO.service"
}

# 状态只展示服务与非敏感配置，不在终端泄露 REPORT_TOKEN。
agent_status() {
    printf 'sing-box: %s\ncloudflared: %s\nagent: %s\n' "$(svc_state "$SVC_SB" "$SVC_SB")" "$(svc_state "$SVC_ARGO" "$SVC_ARGO")" "$(svc_state "$SVC_AGENT" "$SVC_AGENT")"
    if [ -f "$AGENT_ENV" ]; then
        printf '域名: %s\nCF 连接检查: 每 %ss，失败立即重建并上报新域名\n上次成功上报: %s\n' "$(env_get "$AGENT_ENV" DOMAIN)" "$(env_get "$AGENT_ENV" CHECK_INTERVAL)" "$(env_get "$AGENT_ENV" LAST_REPORT_TS)"
    fi
    if [ "$TUNEL_SYSTEM" != 1 ]; then
        printf '便携目录: %s\n' "$TUNEL_HOME"
        echo -e "${yellow}便携模式不安装开机钩子；容器入口使用 $SELF_INSTALL run${re}"
    elif [ "$ENV_INIT" = none ]; then
        echo -e "${yellow}当前环境无 init；容器入口使用 $SELF_INSTALL run，并持久保存 $WORK_DIR${re}"
    fi
}

# 节点详情读取权威配置；老安装没配置时仅显示已有链接，等待 agent 迁移。
show_node() {
    if [ -s "$AGENT_ENV" ]; then
        agent_load
        printf '模式: %s\n域名: %s\n本地端口: 127.0.0.1:%s\nUUID: %s\n路径: %s\n' "$MODE" "$DOMAIN" "$PORT" "$UUID" "$WS_PATH"
        [ -z "$COUNTRY" ] || printf '国家/地区: %s\n' "$(node_display_name)"
        if [ -n "$DOMAIN" ]; then printf '节点链接:\n%s\n' "$(vmess_link "$DOMAIN" "$UUID" "$WS_PATH" "${CFIP:-$DOMAIN}" "$(node_display_name)")"; fi
    elif [ -f "$NODE_DIR/quick.txt" ]; then cat "$NODE_DIR/quick.txt"
    elif [ -f "$NODE_DIR/fixed.txt" ]; then cat "$NODE_DIR/fixed.txt"
    else echo "尚未安装任何节点"; fi
    agent_status
}

# 所有键先验证再写，避免一半成功一半失败；身份相关变更强制下一次启动补发。
config_update() {
    [ "$#" -gt 0 ] || { usage_error "config 需要 K=V 参数"; return 2; }
    local pair key val force=0
    local -a pairs=()
    for pair in "$@"; do
        [[ "$pair" == *=* ]] || { usage_error "config 需要 K=V: $pair"; return 2; }
        key=${pair%%=*}; val=${pair#*=}
        [ "$key" != NODE_NAME ] || val=$(node_name_clean "$val")
        setting_valid "$key" "$val" || { usage_error "配置不合法或不在白名单: $key"; return 2; }
        pairs+=("$key=$val")
        case "$key" in REPORT_URL|REPORT_TOKEN|NODE_NAME|CFIP) force=1 ;; esac
    done
    agent_env_ensure || return 1
    svc_stop "$SVC_AGENT" "$SVC_AGENT"
    for pair in "${pairs[@]}"; do env_set "$AGENT_ENV" "${pair%%=*}" "${pair#*=}" || return 1; done
    [ "$force" != 1 ] || env_set "$AGENT_ENV" LAST_REPORTED_DOMAIN ""
    agent_start
}

# 菜单配置与 CLI 使用相同验证与持久化，不把 token 展示到状态页。
menu_agent_config() {
    agent_env_ensure || return 1
    local url token name
    url=$(ask "上报 URL: " "$REPORT_URL")
    token=$(ask "REPORT_TOKEN: " "$REPORT_TOKEN")
    name=$(node_name_clean "$(ask "节点名称: " "$NODE_NAME")")
    setting_valid REPORT_URL "$url" && setting_valid REPORT_TOKEN "$token" && setting_valid NODE_NAME "$name" || { echo "错误: 上报配置不合法" >&2; return 2; }
    config_update "REPORT_URL=$url" "REPORT_TOKEN=$token" "NODE_NAME=$name" || return $?
    report_node || true
}

# 注销失败不阻断本地卸载，先停止 agent 避免清理过程中重新上报。
uninstall_all() {
    svc_stop "$SVC_AGENT" "$SVC_AGENT"
    report_delete || true
    svc_remove "$SVC_AGENT" "$SVC_AGENT"
    svc_remove "$SVC_ARGO" "$SVC_ARGO"
    svc_remove "$SVC_SB" "$SVC_SB"
    boot_hook_remove
    rm -f "$AGENT_LOCK" "$RUN_DIR/cf-tunel-run.lock" "$SELF_INSTALL"
    rm -rf "$LOG_DIR" "$WORK_DIR"
    if [ "$TUNEL_SYSTEM" != 1 ]; then
        # 只移除空壳目录，用户放在 bin/run/根目录中的其他文件保留。
        rmdir "$BIN_DIR" "$RUN_DIR" "$TUNEL_HOME" 2>/dev/null || true
    fi
    echo "已卸载 tunel（守护、sing-box、cloudflared、配置及日志）"
}

# 保留原菜单 1–5 的用途，增加配置与守护日志两个入口。
main_menu() {
    local c p d cred yn
    if [ ! -t 0 ]; then help; return 2; fi
    while true; do
        clear_screen
        printf 'tunel · VMess-WS 隧道 (%s)\n' "$TUNEL_VERSION"
        echo "1. 安装临时隧道 (quick tunnel)"
        echo "2. 安装固定隧道 (token / 凭据 JSON)"
        echo "3. 重启临时隧道并更新域名"
        echo "4. 查看节点 / 服务状态"
        echo "5. 卸载"
        echo "6. 配置自动上报 / 安装守护"
        echo "7. 守护状态与最近日志"
        echo "0. 退出"
        env_line
        c=$(ask "请选择: " "0")
        case "$c" in
            1)
                if install_paths_preflight menu-install; then
                    env_detect
                    p=$(ask "本地端口（回车随机）: " ""); install_quick "$p"
                fi ;;
            2)
                if install_paths_preflight menu-install; then
                    env_detect
                    d=$(ask "绑定域名: " ""); cred=$(ask "隧道 token 或 JSON 全文: " "")
                    p=$(ask "本地端口（回车随机）: " ""); install_fixed "$p" "$d" "$cred"
                fi ;;
            3) tunnel_refresh_domain ;;
            4) show_node ;;
            5) yn=$(ask "确认卸载? (y/N): " N); case "$yn" in [Yy]*) uninstall_all; return ;; esac ;;
            6) menu_agent_config ;;
            7) agent_status; tail -n 30 "$AGENT_LOG" 2>/dev/null ;;
            0) return 0 ;;
            *) echo "无效的输入" ;;
        esac
        press_any_key_to_continue
    done
}

# 主入口：只读子命令无需 root，所有写系统目录的动作先检查权限。
main() {
    parse_args "$@" || return $?
    install_paths_preflight || return $?
    env_detect
    case "$COMMAND" in
        help|version|node|report|restart|uninstall|menu|quick|fixed|run)
            [ "${#POSITIONAL[@]}" = 0 ] || { usage_error "$COMMAND 不接受位置参数"; return 2; } ;;
        agent)
            [ "${#POSITIONAL[@]}" = 1 ] || { usage_error "agent 需要一个动作"; return 2; }
            case "${POSITIONAL[0]}" in start|stop|restart|status|log|once|loop) : ;; *) usage_error "未知 agent 动作: ${POSITIONAL[0]}"; return 2 ;; esac ;;
        config) [ "${#POSITIONAL[@]}" -gt 0 ] || { usage_error "config 需要 K=V"; return 2; } ;;
    esac
    case "$COMMAND" in help) help; return ;; version) echo "$TUNEL_VERSION"; return ;; esac
    [ -z "$TUNEL_PATH_ERROR" ] || { echo "错误: $TUNEL_PATH_ERROR" >&2; return 2; }
    portable_paths_valid || return 2
    case "$COMMAND" in
        node) show_node; return ;;
        agent)
            # 状态和日志不写配置，因此可在普通账户下按系统权限读取。
            case "${POSITIONAL[0]}" in status) agent_status; return ;; log) tail -n 100 -f "$AGENT_LOG"; return ;; esac ;;
    esac
    if [ "$TUNEL_SYSTEM" = 1 ] && [ "$EUID" != 0 ]; then
        echo "错误: 系统安装需要 root，普通用户请使用 TUNEL_HOME 专用目录。" >&2; return 1
    fi
    case "$COMMAND" in uninstall|menu) : ;; *) runtime_dirs_ensure || return $? ;; esac
    case "$COMMAND" in
        menu) main_menu ;;
        quick) install_quick "$OPT_PORT" ;;
        fixed)
            local cred=$OPT_TOKEN
            [ -z "$OPT_JSON_FILE" ] || cred=$(cat "$OPT_JSON_FILE")
            # --json-file 不能被误识别为 token，否则部署失败也无法解释。
            [[ -z "$OPT_JSON_FILE" || "$cred" == *TunnelSecret* ]] || { echo "错误: JSON 凭据缺少 TunnelSecret" >&2; return 2; }
            install_fixed "$OPT_PORT" "$OPT_DOMAIN" "$cred" ;;
        report) report_node || return 6 ;;
        restart) tunnel_refresh_domain ;;
        run) run_foreground ;;
        config) config_update "${POSITIONAL[@]}" ;;
        uninstall)
            local yn
            if [ -n "$NONINTERACTIVE" ]; then uninstall_all
            else yn=$(ask "确认卸载? (y/N): " N); case "$yn" in [Yy]*) uninstall_all ;; *) return 0 ;; esac; fi ;;
        agent)
            case "${POSITIONAL[0]}" in
                start) agent_start ;; stop) svc_stop "$SVC_AGENT" "$SVC_AGENT" ;;
                restart) svc_stop "$SVC_AGENT" "$SVC_AGENT"; agent_start ;;
                once) dependencies_ensure && agent_once ;; loop) dependencies_ensure && agent_loop ;;
            esac ;;
    esac
}

main "$@"
