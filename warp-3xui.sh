#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_VERSION="1.1.1"
PROJECT_NAME="warp-3xui-safe"
DEFAULT_PORT="40000"
DEFAULT_PROTOCOL="MASQUE"
CONFIG_DIR="/etc/warp-3xui"
CONFIG_FILE="${CONFIG_DIR}/config.env"
MANAGER_PATH="/usr/local/sbin/warp3xui"
CLOUDFLARE_BASE_DEFAULT="https://warp-3xui-download.xinian5216.workers.dev"
LEGACY_CLOUDFLARE_BASE="https://xray-manager-download.xinian5216.workers.dev"
TRACE_URL="https://www.cloudflare.com/cdn-cgi/trace"
GOOGLE_TEST_URL="https://www.google.com/generate_204"
YOUTUBE_REGION_URL="https://www.youtube.com/premium"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m'

PORT="${DEFAULT_PORT}"
TUNNEL_PROTOCOL="${DEFAULT_PROTOCOL}"
UPDATE_REPO="xinian5216/warp-3xui-safe"
UPDATE_SOURCE="${WARP3XUI_UPDATE_SOURCE:-github}"
CLOUDFLARE_BASE="${WARP3XUI_CLOUDFLARE_URL:-${CLOUDFLARE_BASE_DEFAULT}}"
NEW_INSTALL=0
LAST_TRACE=""

log() { printf '%b\n' "${CYAN}[信息]${NC} $*"; }
ok() { printf '%b\n' "${GREEN}[成功]${NC} $*"; }
warn() { printf '%b\n' "${YELLOW}[注意]${NC} $*" >&2; }
die() {
    printf '%b\n' "${RED}[失败]${NC} $*" >&2
    if (( NEW_INSTALL == 1 )) && command -v warp-cli >/dev/null 2>&1; then
        warn "为保护 SSH，正在断开尚未通过验证的 WARP 连接。"
        warp_cli disconnect >/dev/null 2>&1 || true
    fi
    exit 1
}

on_error() {
    local exit_code=$?
    warn "命令执行失败（行号 ${BASH_LINENO[0]:-未知}，退出码 ${exit_code}）。"
    if (( NEW_INSTALL == 1 )) && command -v warp-cli >/dev/null 2>&1; then
        warn "为保护 SSH，正在断开尚未通过验证的 WARP 连接。"
        warp_cli disconnect >/dev/null 2>&1 || true
    fi
    exit "${exit_code}"
}
trap on_error ERR

usage() {
    cat <<'EOF'
WARP for 3x-ui 安全管理脚本

用法：
  sudo bash warp-3xui.sh                 交互菜单
  sudo bash warp-3xui.sh install [选项]  安装并配置本地 WARP SOCKS5
  sudo warp3xui status                   查看状态与出口
  sudo warp3xui test [--strict]          完整验证（strict 遇到 CN 退出非 0）
  sudo warp3xui reconnect                重新连接并验证
  sudo warp3xui rotate                   重建 WARP 注册并验证
  sudo warp3xui update-client            更新 Cloudflare WARP 客户端
  sudo warp3xui self-update [选项]       更新本管理脚本
  sudo warp3xui snippets                 重新生成 3x-ui/Xray 示例
  sudo warp3xui uninstall                卸载

install 选项：
  --port PORT             本地 SOCKS5 端口，默认 40000
  --protocol auto|masque|wireguard
                          隧道协议，默认 MASQUE；auto 会在失败时回退
  --license-file PATH     可选，从本地权限受控文件读取官方 WARP+ Key
  --repo OWNER/REPO       私有仓库名，用于后续 gh 自更新
  --non-interactive       不询问，使用给定值/默认值

self-update 选项：
  --file PATH             从本地脚本文件更新
  --url HTTPS_URL         从 URL 更新（私有仓库 URL 需要自行鉴权）
  --repo OWNER/REPO       使用已登录的 gh 从私有仓库更新
  --cloudflare            从 Cloudflare Worker + 私有 R2 更新
  --github                从已登录的 gh 更新

安全保证：
  本脚本只启用 127.0.0.1 上的 WARP Local Proxy，不启用系统 WARP 模式，
  不添加 IPv4/IPv6 默认路由，不接管 SSH、3x-ui 面板或其他系统流量。
EOF
}

require_root() {
    [[ ${EUID} -eq 0 ]] || die "请使用 root 或 sudo 运行。"
}

warp_cli() {
    warp-cli --accept-tos "$@"
}

load_config() {
    if [[ -r "${CONFIG_FILE}" ]]; then
        # 该文件由本脚本生成，只允许固定键值；不直接 source，避免执行任意内容。
        local key value
        while IFS='=' read -r key value; do
            case "${key}" in
                PORT) PORT="${value}" ;;
                TUNNEL_PROTOCOL) TUNNEL_PROTOCOL="${value}" ;;
                UPDATE_REPO) UPDATE_REPO="${value}" ;;
                UPDATE_SOURCE) UPDATE_SOURCE="${value}" ;;
                CLOUDFLARE_BASE) CLOUDFLARE_BASE="${value}" ;;
            esac
        done < "${CONFIG_FILE}"
    fi
    if [[ "${CLOUDFLARE_BASE%/}" == "${LEGACY_CLOUDFLARE_BASE}" ]]; then
        CLOUDFLARE_BASE="${CLOUDFLARE_BASE_DEFAULT}"
    fi
    [[ -z "${WARP3XUI_UPDATE_SOURCE:-}" ]] \
        || UPDATE_SOURCE="${WARP3XUI_UPDATE_SOURCE}"
    [[ -z "${WARP3XUI_CLOUDFLARE_URL:-}" ]] \
        || CLOUDFLARE_BASE="${WARP3XUI_CLOUDFLARE_URL}"
    case "${UPDATE_SOURCE}" in
        github|cloudflare) ;;
        *) die "无效更新来源：${UPDATE_SOURCE}" ;;
    esac
}

validate_port() {
    [[ "${1}" =~ ^[0-9]+$ ]] || die "端口必须是数字。"
    (( 1 <= 10#${1} && 10#${1} <= 65535 )) || die "端口必须在 1-65535 之间。"
}

normalize_protocol() {
    case "${1,,}" in
        auto) printf '%s' "AUTO" ;;
        masque) printf '%s' "MASQUE" ;;
        wireguard|wg) printf '%s' "WireGuard" ;;
        *) die "协议只能是 auto、masque 或 wireguard。" ;;
    esac
}

detect_os() {
    [[ -r /etc/os-release ]] || die "无法读取 /etc/os-release。"
    # shellcheck disable=SC1091
    . /etc/os-release
    OS_ID="${ID:-unknown}"
    OS_VERSION="${VERSION_ID:-unknown}"
    OS_CODENAME="${VERSION_CODENAME:-}"
    if [[ -z "${OS_CODENAME}" ]] && command -v lsb_release >/dev/null 2>&1; then
        OS_CODENAME="$(lsb_release -sc)"
    fi
    ARCH="$(uname -m)"
}

install_base_dependencies() {
    detect_os
    log "系统：${OS_ID} ${OS_VERSION} (${ARCH})"
    case "${OS_ID}" in
        debian|ubuntu)
            export DEBIAN_FRONTEND=noninteractive
            apt-get update
            apt-get install -y ca-certificates curl gnupg lsb-release iproute2 jq
            ;;
        rhel|centos|rocky|almalinux|fedora)
            local pm="dnf"
            command -v dnf >/dev/null 2>&1 || pm="yum"
            "${pm}" install -y ca-certificates curl gnupg2 iproute jq
            ;;
        *)
            die "暂不支持 ${OS_ID} ${OS_VERSION}。支持 Debian、Ubuntu、RHEL、CentOS、Rocky、AlmaLinux、Fedora。"
            ;;
    esac
}

trace_value() {
    local family="$1" proxy="${2:-}" output
    local -a args=(--fail --silent --show-error --max-time 12)
    case "${family}" in
        4) args+=(-4) ;;
        6) args+=(-6) ;;
    esac
    [[ -z "${proxy}" ]] || args+=(--socks5-hostname "${proxy}")
    output="$(curl "${args[@]}" "${TRACE_URL}" 2>/dev/null || true)"
    printf '%s' "${output}"
}

detect_connectivity() {
    local t4 t6
    t4="$(trace_value 4)"
    t6="$(trace_value 6)"
    if [[ -n "${t4}" && -n "${t6}" ]]; then
        NETWORK_TYPE="双栈 IPv4 + IPv6"
    elif [[ -n "${t4}" ]]; then
        NETWORK_TYPE="仅 IPv4（或 IPv6 不可用）"
    elif [[ -n "${t6}" ]]; then
        NETWORK_TYPE="仅 IPv6（或 IPv4 不可用）"
    else
        die "IPv4 与 IPv6 均无法访问 Cloudflare 检测地址，请先检查 VPS 网络和 DNS。"
    fi
    DIRECT_V4="$(awk -F= '$1=="ip"{print $2}' <<<"${t4}")"
    DIRECT_V6="$(awk -F= '$1=="ip"{print $2}' <<<"${t6}")"
    log "检测到：${NETWORK_TYPE}"
    [[ -z "${DIRECT_V4}" ]] || log "原生 IPv4：${DIRECT_V4}"
    [[ -z "${DIRECT_V6}" ]] || log "原生 IPv6：${DIRECT_V6}"
}

install_cloudflare_repo() {
    detect_os
    case "${OS_ID}" in
        debian|ubuntu)
            [[ -n "${OS_CODENAME}" ]] || die "无法识别 Debian/Ubuntu 代号。"
            curl -fsSL https://pkg.cloudflareclient.com/pubkey.gpg \
                | gpg --yes --dearmor --output /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg
            printf 'deb [signed-by=/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg] https://pkg.cloudflareclient.com/ %s main\n' \
                "${OS_CODENAME}" > /etc/apt/sources.list.d/cloudflare-client.list
            apt-get update
            apt-get install -y cloudflare-warp
            ;;
        rhel|centos|rocky|almalinux|fedora)
            curl -fsSL https://pkg.cloudflareclient.com/cloudflare-warp-ascii.repo \
                -o /etc/yum.repos.d/cloudflare-warp.repo
            rpm --import https://pkg.cloudflareclient.com/pubkey.gpg
            local pm="dnf"
            command -v dnf >/dev/null 2>&1 || pm="yum"
            "${pm}" install -y cloudflare-warp
            ;;
    esac
    command -v warp-cli >/dev/null 2>&1 || die "cloudflare-warp 安装后仍找不到 warp-cli。"
    systemctl enable --now warp-svc.service
}

registration_exists() {
    warp_cli registration show >/dev/null 2>&1
}

ensure_registration() {
    if registration_exists; then
        log "现有 WARP 注册有效，继续使用。"
    else
        log "正在创建 WARP 注册……"
        warp_cli registration new
    fi
}

apply_license() {
    local license="${1:-}"
    [[ -n "${license}" ]] || return 0
    log "正在绑定官方 WARP+ Key……"
    warp_cli registration license "${license}"
}

set_protocol() {
    local protocol="$1"
    [[ "${protocol}" != "AUTO" ]] || protocol="MASQUE"
    warp_cli tunnel protocol set "${protocol}"
}

configure_proxy_mode() {
    local protocol="$1"
    validate_port "${PORT}"

    # connect 前先断开，且 mode proxy 必须成功；绝不以 warp/warp+doh 模式连接。
    warp_cli disconnect >/dev/null 2>&1 || true
    warp_cli mode proxy
    if ! warp_cli proxy port "${PORT}"; then
        # 兼容部分旧版 CLI。
        warp-cli --accept-tos set-proxy-port "${PORT}"
    fi
    set_protocol "${protocol}"
    warp_cli connect
}

wait_for_proxy() {
    local attempts="${1:-20}" i trace
    for ((i=1; i<=attempts; i++)); do
        trace="$(trace_value auto "127.0.0.1:${PORT}")"
        if grep -Eq '^warp=(on|plus)$' <<<"${trace}"; then
            printf '%s' "${trace}"
            return 0
        fi
        sleep 1
    done
    return 1
}

connect_with_fallback() {
    local requested="$1" trace
    if [[ "${requested}" == "AUTO" ]]; then
        log "先尝试 MASQUE。"
        configure_proxy_mode "MASQUE"
        if trace="$(wait_for_proxy 15)"; then
            TUNNEL_PROTOCOL="MASQUE"
            LAST_TRACE="${trace}"
            return 0
        fi
        warn "MASQUE 未通过验证，回退 WireGuard。"
        configure_proxy_mode "WireGuard"
        trace="$(wait_for_proxy 20)" || return 1
        TUNNEL_PROTOCOL="WireGuard"
        LAST_TRACE="${trace}"
        return 0
    fi

    configure_proxy_mode "${requested}"
    trace="$(wait_for_proxy 20)" || return 1
    TUNNEL_PROTOCOL="${requested}"
    LAST_TRACE="${trace}"
}

save_config() {
    install -d -m 700 "${CONFIG_DIR}"
    {
        printf 'PORT=%s\n' "${PORT}"
        printf 'TUNNEL_PROTOCOL=%s\n' "${TUNNEL_PROTOCOL}"
        printf 'UPDATE_REPO=%s\n' "${UPDATE_REPO}"
        printf 'UPDATE_SOURCE=%s\n' "${UPDATE_SOURCE}"
        printf 'CLOUDFLARE_BASE=%s\n' "${CLOUDFLARE_BASE%/}"
    } > "${CONFIG_FILE}"
    chmod 600 "${CONFIG_FILE}"
}

install_manager() {
    local source_path
    source_path="$(readlink -f "${BASH_SOURCE[0]}")"
    if [[ "${source_path}" != "${MANAGER_PATH}" ]]; then
        install -m 755 "${source_path}" "${MANAGER_PATH}"
    fi
}

render_snippets() {
    install -d -m 700 "${CONFIG_DIR}"
    cat > "${CONFIG_DIR}/xray-outbound.json" <<EOF
{
  "tag": "warp-google",
  "protocol": "socks",
  "settings": {
    "address": "127.0.0.1",
    "port": ${PORT}
  }
}
EOF
    cat > "${CONFIG_DIR}/xray-routing-rule-tcp.json" <<'EOF'
{
  "type": "field",
  "domain": ["geosite:google"],
  "network": "tcp",
  "outboundTag": "warp-google",
  "ruleTag": "Google via WARP"
}
EOF
    cat > "${CONFIG_DIR}/xray-routing-rule-udp-block.json" <<'EOF'
{
  "type": "field",
  "domain": ["geosite:google"],
  "network": "udp",
  "outboundTag": "blocked",
  "ruleTag": "Block Google QUIC leak"
}
EOF
    chmod 600 "${CONFIG_DIR}"/*.json
    ok "3x-ui/Xray 示例已生成在 ${CONFIG_DIR}/。"
}

extract_youtube_region() {
    local body
    body="$(curl --fail --silent --show-error --location --max-time 20 \
        --socks5-hostname "127.0.0.1:${PORT}" "${YOUTUBE_REGION_URL}" 2>/dev/null || true)"
    grep -oE '"(countryCode|GL|INNERTUBE_CONTEXT_GL)":"[A-Z]{2}"' <<<"${body}" \
        | head -n1 | sed -E 's/.*:"([A-Z]{2})"/\1/' || true
}

test_warp() {
    local strict="${1:-0}" trace warp_state warp_ip location google_code yt_region listen_line failures=0
    trace="$(trace_value auto "127.0.0.1:${PORT}")"
    warp_state="$(awk -F= '$1=="warp"{print $2}' <<<"${trace}")"
    warp_ip="$(awk -F= '$1=="ip"{print $2}' <<<"${trace}")"
    location="$(awk -F= '$1=="loc"{print $2}' <<<"${trace}")"

    if [[ "${warp_state}" =~ ^(on|plus)$ ]]; then
        ok "WARP 隧道：${warp_state}"
        log "WARP 出口 IP：${warp_ip:-未知}"
        log "Cloudflare 出口地区：${location:-未知}"
    else
        warn "WARP trace 未返回 on/plus。"
        ((failures+=1))
    fi

    google_code="$(curl --silent --output /dev/null --write-out '%{http_code}' --max-time 15 \
        --socks5-hostname "127.0.0.1:${PORT}" "${GOOGLE_TEST_URL}" 2>/dev/null || true)"
    if [[ "${google_code}" == "204" ]]; then
        ok "Google 经 WARP 连通：HTTP 204"
    else
        warn "Google 连通测试未得到 204（实际 ${google_code:-无响应}）。"
        ((failures+=1))
    fi

    yt_region="$(extract_youtube_region)"
    if [[ -n "${yt_region}" ]]; then
        log "Google/YouTube 页面地区：${yt_region}（启发式结果）"
        if [[ "${yt_region}" == "CN" ]]; then
            warn "该 WARP 出口仍被 Google 识别为中国大陆（送中）。"
            ((failures+=1))
        fi
    else
        warn "Google 页面未暴露可解析的地区码，不能据此断言是否送中。"
    fi

    listen_line="$(ss -H -lntp 2>/dev/null | awk -v p=":${PORT}" '$4 ~ p"$" {print $4; exit}')"
    if [[ "${listen_line}" == "127.0.0.1:${PORT}" || "${listen_line}" == "[::1]:${PORT}" ]]; then
        ok "SOCKS5 仅监听本机：${listen_line}"
    else
        warn "未确认代理仅监听 loopback（检测值：${listen_line:-无}）。"
        ((failures+=1))
    fi

    if ip -4 route show default 2>/dev/null | grep -qE 'dev (CloudflareWARP|wgcf)'; then
        warn "发现 IPv4 默认路由指向 WARP，这不应由本脚本产生。"
        ((failures+=1))
    else
        ok "IPv4 默认路由未被 WARP 接管。"
    fi
    if ip -6 route show default 2>/dev/null | grep -qE 'dev (CloudflareWARP|wgcf)'; then
        warn "发现 IPv6 默认路由指向 WARP，这不应由本脚本产生。"
        ((failures+=1))
    else
        ok "IPv6 默认路由未被 WARP 接管。"
    fi

    if (( strict == 1 && failures > 0 )); then
        return 1
    fi
    (( failures == 0 ))
}

show_status() {
    load_config
    printf '\n%s v%s\n' "${PROJECT_NAME}" "${SCRIPT_VERSION}"
    printf '代理地址：127.0.0.1:%s\n' "${PORT}"
    printf '隧道协议：%s\n\n' "${TUNNEL_PROTOCOL}"
    if command -v warp-cli >/dev/null 2>&1; then
        warp_cli status || true
        printf '\n'
        warp_cli settings 2>/dev/null | grep -Ei 'mode|proxy|protocol' || true
    else
        warn "尚未安装 cloudflare-warp。"
        return 1
    fi
    printf '\n'
    test_warp 0 || true
}

parse_install_args() {
    NON_INTERACTIVE=0
    LICENSE_FILE=""
    while (($#)); do
        case "$1" in
            --port) [[ $# -ge 2 ]] || die "--port 缺少值"; PORT="$2"; shift 2 ;;
            --protocol) [[ $# -ge 2 ]] || die "--protocol 缺少值"; TUNNEL_PROTOCOL="$(normalize_protocol "$2")"; shift 2 ;;
            --license-file) [[ $# -ge 2 ]] || die "--license-file 缺少值"; LICENSE_FILE="$2"; shift 2 ;;
            --repo) [[ $# -ge 2 ]] || die "--repo 缺少值"; UPDATE_REPO="$2"; shift 2 ;;
            --non-interactive) NON_INTERACTIVE=1; shift ;;
            *) die "未知 install 选项：$1" ;;
        esac
    done
    validate_port "${PORT}"
    [[ "${TUNNEL_PROTOCOL}" =~ ^(AUTO|MASQUE|WireGuard)$ ]] || TUNNEL_PROTOCOL="$(normalize_protocol "${TUNNEL_PROTOCOL}")"
    LICENSE_KEY=""
    if [[ -n "${LICENSE_FILE}" ]]; then
        [[ -r "${LICENSE_FILE}" ]] || die "无法读取 WARP+ Key 文件：${LICENSE_FILE}"
        IFS= read -r LICENSE_KEY < "${LICENSE_FILE}"
        [[ -n "${LICENSE_KEY}" ]] || die "WARP+ Key 文件为空。"
    fi
}

interactive_options() {
    printf '本地 SOCKS5 端口 [%s]：' "${PORT}"
    read -r input
    [[ -z "${input}" ]] || PORT="${input}"
    validate_port "${PORT}"

    cat <<'EOF'
隧道协议：
  1. MASQUE（推荐，Cloudflare 当前默认）
  2. WireGuard
  3. 自动（MASQUE 失败后尝试 WireGuard）
EOF
    printf '请选择 [1]：'
    read -r input
    case "${input:-1}" in
        1) TUNNEL_PROTOCOL="MASQUE" ;;
        2) TUNNEL_PROTOCOL="WireGuard" ;;
        3) TUNNEL_PROTOCOL="AUTO" ;;
        *) die "无效选项。" ;;
    esac
}

do_install() {
    require_root
    load_config
    parse_install_args "$@"
    if (( NON_INTERACTIVE == 0 )); then
        interactive_options
    fi
    NEW_INSTALL=1
    log "安装基础依赖。"
    install_base_dependencies
    detect_connectivity
    log "安装 Cloudflare 官方稳定版 WARP 客户端。"
    install_cloudflare_repo
    ensure_registration
    apply_license "${LICENSE_KEY}"
    log "配置 Local Proxy；不会修改系统默认路由。"
    local trace
    connect_with_fallback "${TUNNEL_PROTOCOL}" || die "WARP 代理无法连接。可改用 --protocol auto 重试。"
    trace="${LAST_TRACE}"
    grep -Eq '^warp=(on|plus)$' <<<"${trace}" || die "WARP 未通过 trace 验证。"
    save_config
    install_manager
    render_snippets
    NEW_INSTALL=0
    test_warp 0 || warn "主体已安装，但仍有验收项需要查看。请运行：sudo warp3xui test --strict"
    ok "安装完成。3x-ui 的 SOCKS 出站填写 127.0.0.1:${PORT}。"
}

do_reconnect() {
    require_root
    load_config
    local trace
    connect_with_fallback "${TUNNEL_PROTOCOL}" || die "重连失败。"
    trace="${LAST_TRACE}"
    grep -Eq '^warp=(on|plus)$' <<<"${trace}" || die "重连后 WARP 未开启。"
    test_warp 0 || true
}

do_rotate() {
    require_root
    load_config
    warn "重建注册通常不能选择国家，只可能更换 WARP 出口。"
    warp_cli disconnect >/dev/null 2>&1 || true
    warp_cli registration delete >/dev/null 2>&1 || true
    warp_cli registration new
    do_reconnect
}

update_client() {
    require_root
    load_config
    detect_os
    case "${OS_ID}" in
        debian|ubuntu)
            apt-get update
            apt-get install -y --only-upgrade cloudflare-warp
            ;;
        rhel|centos|rocky|almalinux|fedora)
            local pm="dnf"
            command -v dnf >/dev/null 2>&1 || pm="yum"
            "${pm}" upgrade -y cloudflare-warp
            ;;
        *) die "不支持的系统。" ;;
    esac
    systemctl restart warp-svc.service
    do_reconnect
}

version_from_file() {
    sed -nE 's/^SCRIPT_VERSION="([0-9]+\.[0-9]+\.[0-9]+)"$/\1/p' "$1" | head -n1
}

sha256_file() {
    local file="$1"
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "${file}" | awk '{print $1}'
    elif command -v openssl >/dev/null 2>&1; then
        openssl dgst -sha256 "${file}" | awk '{print $NF}'
    else
        return 1
    fi
}

download_cloudflare_update() {
    local output="$1" token="${WARP3XUI_INSTALL_TOKEN:-}" temp_dir curl_config checksum expected actual
    CLOUDFLARE_BASE="${CLOUDFLARE_BASE%/}"
    if [[ -z "${token}" && -r /dev/tty ]]; then
        printf 'Cloudflare 安装密钥：' >/dev/tty
        IFS= read -r -s token </dev/tty || true
        printf '\n' >/dev/tty
    fi
    [[ -n "${token}" ]] || die "没有 Cloudflare 安装密钥。"
    [[ "${token}" != *$'\n'* && "${token}" != *$'\r'* && "${token}" != *'"'* ]] \
        || die "Cloudflare 安装密钥包含非法字符。"

    temp_dir="$(mktemp -d /tmp/warp3xui-cloudflare.XXXXXX)"
    curl_config="${temp_dir}/curl.conf"
    checksum="${temp_dir}/warp-3xui.sha256"
    chmod 700 "${temp_dir}"
    {
        printf 'header = "Authorization: Bearer %s"\n' "${token}"
        printf '%s\n' 'fail' 'silent' 'show-error' 'location'
        printf '%s\n' 'connect-timeout = 15' 'max-time = 180' 'retry = 3'
    } > "${curl_config}"
    chmod 600 "${curl_config}"
    unset token WARP3XUI_INSTALL_TOKEN 2>/dev/null || true

    if ! curl --config "${curl_config}" \
        "${CLOUDFLARE_BASE}/releases/warp3xui/warp-3xui.sh" \
        -o "${output}"; then
        rm -rf "${temp_dir}"
        die "从 Cloudflare 下载管理脚本失败。"
    fi
    if ! curl --config "${curl_config}" \
        "${CLOUDFLARE_BASE}/releases/warp3xui/warp-3xui.sha256" \
        -o "${checksum}"; then
        rm -rf "${temp_dir}"
        die "从 Cloudflare 下载 SHA256 失败。"
    fi

    expected="$(tr -d '[:space:]' < "${checksum}")"
    actual="$(sha256_file "${output}" 2>/dev/null || true)"
    rm -rf "${temp_dir}"
    [[ -n "${expected}" && "${expected}" == "${actual}" ]] \
        || die "Cloudflare 更新文件 SHA256 校验失败。"
}

self_update() {
    require_root
    load_config
    local source_type="" source_value="" temp_file new_version
    while (($#)); do
        case "$1" in
            --file|--url|--repo)
                [[ $# -ge 2 ]] || die "$1 缺少值"
                source_type="${1#--}"; source_value="$2"; shift 2
                ;;
            --cloudflare) source_type="cloudflare"; shift ;;
            --github) source_type="repo"; source_value="${UPDATE_REPO}"; shift ;;
            *) die "未知 self-update 选项：$1" ;;
        esac
    done
    if [[ -z "${source_type}" ]]; then
        case "${UPDATE_SOURCE}" in
            cloudflare) source_type="cloudflare" ;;
            github) source_type="repo"; source_value="${UPDATE_REPO}" ;;
            *) die "未知更新来源：${UPDATE_SOURCE}" ;;
        esac
    fi
    temp_file="$(mktemp /tmp/warp3xui-update.XXXXXX)"
    case "${source_type}" in
        file) cp -- "${source_value}" "${temp_file}" ;;
        url) curl -fsSL "${source_value}" -o "${temp_file}" ;;
        repo)
            command -v gh >/dev/null 2>&1 || die "私有仓库更新需要已登录的 gh；也可用 --file。"
            gh api -H 'Accept: application/vnd.github.raw+json' \
                "repos/${source_value}/contents/warp-3xui.sh?ref=main" > "${temp_file}"
            UPDATE_REPO="${source_value}"
            UPDATE_SOURCE="github"
            ;;
        cloudflare)
            download_cloudflare_update "${temp_file}"
            UPDATE_SOURCE="cloudflare"
            ;;
    esac
    bash -n "${temp_file}"
    grep -q 'PROJECT_NAME="warp-3xui-safe"' "${temp_file}" || die "更新文件不是本项目脚本。"
    new_version="$(version_from_file "${temp_file}")"
    [[ -n "${new_version}" ]] || die "无法读取新脚本版本。"
    cp -a "${MANAGER_PATH}" "${MANAGER_PATH}.bak" 2>/dev/null || true
    install -m 755 "${temp_file}" "${MANAGER_PATH}"
    rm -f "${temp_file}"
    save_config
    ok "管理脚本已更新：${SCRIPT_VERSION} -> ${new_version}。备份为 ${MANAGER_PATH}.bak。"
}

do_uninstall() {
    require_root
    load_config
    printf '确认卸载 WARP for 3x-ui 和 cloudflare-warp 软件包？[y/N] '
    read -r answer
    [[ "${answer,,}" == "y" ]] || { log "已取消。"; return 0; }
    warp_cli disconnect >/dev/null 2>&1 || true
    warp_cli registration delete >/dev/null 2>&1 || true
    detect_os
    case "${OS_ID}" in
        debian|ubuntu)
            apt-get remove -y cloudflare-warp
            rm -f /etc/apt/sources.list.d/cloudflare-client.list
            ;;
        rhel|centos|rocky|almalinux|fedora)
            local pm="dnf"
            command -v dnf >/dev/null 2>&1 || pm="yum"
            "${pm}" remove -y cloudflare-warp
            rm -f /etc/yum.repos.d/cloudflare-warp.repo
            ;;
    esac
    rm -f "${MANAGER_PATH}" "${MANAGER_PATH}.bak"
    rm -f "${CONFIG_FILE}" "${CONFIG_DIR}"/*.json 2>/dev/null || true
    rmdir "${CONFIG_DIR}" 2>/dev/null || true
    ok "已卸载。脚本从未修改系统默认路由，因此无需恢复 SSH 路由。"
}

show_menu() {
    require_root
    load_config
    local choice
    while true; do
        cat <<EOF

WARP for 3x-ui v${SCRIPT_VERSION}
1. 安装/重新配置
2. 状态与完整验证
3. 重新连接
4. 重建 WARP 注册
5. 更新 Cloudflare WARP 客户端
6. 生成 3x-ui 配置示例
7. 更新本管理脚本
8. 卸载
0. 退出
EOF
        printf '请选择 [0-8]：'
        read -r choice || return 0
        case "${choice}" in
            1) do_install ;;
            2) show_status ;;
            3) do_reconnect ;;
            4) do_rotate ;;
            5) update_client ;;
            6) render_snippets ;;
            7) self_update ;;
            8) do_uninstall; return 0 ;;
            0) return 0 ;;
            *) warn "无效选项，请重新输入。" ;;
        esac
        printf '\n按 Enter 返回主菜单……'
        read -r _ || return 0
    done
}

main() {
    local command="${1:-menu}"
    [[ $# -eq 0 ]] || shift
    case "${command}" in
        menu) show_menu ;;
        install) do_install "$@" ;;
        status) require_root; show_status ;;
        test)
            require_root; load_config
            if [[ "${1:-}" == "--strict" ]]; then test_warp 1; else test_warp 0; fi
            ;;
        reconnect|restart) do_reconnect ;;
        rotate) do_rotate ;;
        update-client) update_client ;;
        self-update) self_update "$@" ;;
        snippets) require_root; load_config; render_snippets ;;
        uninstall) do_uninstall ;;
        version|--version|-v) printf '%s\n' "${SCRIPT_VERSION}" ;;
        help|--help|-h) usage ;;
        *) usage; die "未知命令：${command}" ;;
    esac
}

main "$@"
