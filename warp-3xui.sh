#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_VERSION="1.3.1"
PROJECT_ID="warp-egress-manager"
LEGACY_PROJECT_ID="warp-3xui-safe"
PROJECT_NAME="WARP Egress Manager"
DEFAULT_PORT="40000"
DEFAULT_PROTOCOL="MASQUE"
DEFAULT_EGRESS_MODE="AUTO"
CONFIG_DIR="${WARPM_CONFIG_DIR:-${WARP3XUI_CONFIG_DIR:-/etc/warp-manager}}"
CONFIG_FILE="${CONFIG_DIR}/config.env"
PROXY_ENV_FILE="${CONFIG_DIR}/proxy.env"
PROXYCHAINS_FILE="${CONFIG_DIR}/proxychains.conf"
LEGACY_CONFIG_DIR="/etc/warp-3xui"
LEGACY_CONFIG_FILE="${LEGACY_CONFIG_DIR}/config.env"
MANAGER_PATH="${WARPM_MANAGER_PATH:-${WARP3XUI_MANAGER_PATH:-/usr/local/sbin/warpm}}"
LEGACY_MANAGER_PATH="/usr/local/sbin/warp3xui"
CLOUDFLARE_BASE_DEFAULT="https://warp-3xui-download.xinian5216.workers.dev"
LEGACY_CLOUDFLARE_BASE="https://xray-manager-download.xinian5216.workers.dev"
WARP_PACKAGE_R2_PREFIX="packages/cloudflare-warp/deb"
TRACE_URL="https://www.cloudflare.com/cdn-cgi/trace"
TRACE_V4_URL="https://1.1.1.1/cdn-cgi/trace"
TRACE_V6_URL="https://[2606:4700:4700::1111]/cdn-cgi/trace"
GOOGLE_TEST_URL="https://www.google.com/generate_204"
YOUTUBE_REGION_URL="https://www.youtube.com/premium"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m'

PORT="${DEFAULT_PORT}"
TUNNEL_PROTOCOL="${DEFAULT_PROTOCOL}"
EGRESS_MODE="${DEFAULT_EGRESS_MODE}"
UPDATE_REPO="xinian5216/warp-egress-manager"
UPDATE_SOURCE="${WARPM_UPDATE_SOURCE:-${WARP3XUI_UPDATE_SOURCE:-github}}"
CLOUDFLARE_BASE="${WARPM_CLOUDFLARE_URL:-${WARP3XUI_CLOUDFLARE_URL:-${CLOUDFLARE_BASE_DEFAULT}}}"
CLIENT_INSTALL_SOURCE="unknown"
NEW_INSTALL=0

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
WARP Egress Manager

用法：
  sudo bash warp-3xui.sh                 交互菜单
  sudo bash warp-3xui.sh install [选项]  安装并配置本地 WARP SOCKS5
  sudo warpm status                       查看状态与出口
  sudo warpm test [--strict]              完整验证（strict 遇到 CN 退出非 0）
  warpm env                               输出当前 Shell 代理环境变量
  warpm proxy-info                        显示 SOCKS5、ProxyChains 与命令示例
  warpm run -- COMMAND [ARG...]           让支持 ALL_PROXY 的单条命令经 WARP
  warpm curl [-4|-6] [CURL_ARG...]        用 WARP 执行 curl，可严格选地址族
  sudo warpm reconnect                    重新连接并验证
  sudo warpm rotate                       重建 WARP 注册并验证
  sudo warpm update-client                更新客户端（官方源失败时回退 R2）
  sudo warpm set-egress MODE              切换 IPv4/IPv6/双栈验收与 Xray 示例
  sudo warpm self-update [选项]           更新本管理脚本
  sudo warpm integrations                 生成通用代理与可选 3x-ui/Xray 示例
  sudo warpm uninstall                    卸载

install 选项：
  --port PORT             本地 SOCKS5 端口，默认 40000
  --protocol auto|masque|wireguard
                          隧道协议，默认 MASQUE；auto 会在失败时回退
  --egress auto|ipv4|ipv6|dual
                          WARP 出口验收与 curl/Xray 地址族；auto 补齐单栈
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
  不添加 IPv4/IPv6 默认路由，不接管 SSH、管理面板或其他系统流量。
  出口模式只影响验收、warpm curl 默认值和 Xray 示例，不会给网卡改地址或替换原生出口。
EOF
}

require_root() {
    [[ ${EUID} -eq 0 ]] || die "请使用 root 或 sudo 运行。"
}

warp_cli() {
    warp-cli --accept-tos "$@"
}

load_config() {
    local config_to_read="" key value
    if [[ -r "${CONFIG_FILE}" ]]; then
        config_to_read="${CONFIG_FILE}"
    elif [[ -r "${LEGACY_CONFIG_FILE}" ]]; then
        config_to_read="${LEGACY_CONFIG_FILE}"
    fi
    if [[ -n "${config_to_read}" ]]; then
        # 该文件由本脚本生成，只允许固定键值；不直接 source，避免执行任意内容。
        while IFS='=' read -r key value; do
            case "${key}" in
                PORT) PORT="${value}" ;;
                TUNNEL_PROTOCOL) TUNNEL_PROTOCOL="${value}" ;;
                EGRESS_MODE) EGRESS_MODE="${value}" ;;
                UPDATE_REPO) UPDATE_REPO="${value}" ;;
                UPDATE_SOURCE) UPDATE_SOURCE="${value}" ;;
                CLOUDFLARE_BASE) CLOUDFLARE_BASE="${value}" ;;
                CLIENT_INSTALL_SOURCE) CLIENT_INSTALL_SOURCE="${value}" ;;
            esac
        done < "${config_to_read}"
    elif [[ -r "${PROXY_ENV_FILE}" ]]; then
        # 非 root 用户只需读取公开的本机代理端口。
        while IFS='=' read -r key value; do
            case "${key}" in
                WARP_PROXY_PORT) PORT="${value}" ;;
                WARP_EGRESS_MODE) EGRESS_MODE="${value}" ;;
            esac
        done < "${PROXY_ENV_FILE}"
    fi
    if [[ "${CLOUDFLARE_BASE%/}" == "${LEGACY_CLOUDFLARE_BASE}" ]]; then
        CLOUDFLARE_BASE="${CLOUDFLARE_BASE_DEFAULT}"
    fi
    [[ -z "${WARP3XUI_UPDATE_SOURCE:-}" ]] \
        || UPDATE_SOURCE="${WARP3XUI_UPDATE_SOURCE}"
    [[ -z "${WARPM_UPDATE_SOURCE:-}" ]] \
        || UPDATE_SOURCE="${WARPM_UPDATE_SOURCE}"
    [[ -z "${WARP3XUI_CLOUDFLARE_URL:-}" ]] \
        || CLOUDFLARE_BASE="${WARP3XUI_CLOUDFLARE_URL}"
    [[ -z "${WARPM_CLOUDFLARE_URL:-}" ]] \
        || CLOUDFLARE_BASE="${WARPM_CLOUDFLARE_URL}"
    case "${UPDATE_SOURCE}" in
        github|cloudflare) ;;
        *) die "无效更新来源：${UPDATE_SOURCE}" ;;
    esac
}

normalize_arch() {
    case "${1,,}" in
        x86_64|amd64) printf '%s' "amd64" ;;
        aarch64|arm64) printf '%s' "arm64" ;;
        *) printf '%s' "${1,,}" ;;
    esac
}

validate_codename() {
    [[ "$1" =~ ^[a-z0-9][a-z0-9._-]*$ ]] \
        || die "系统代号包含不安全字符：$1"
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

normalize_egress_mode() {
    case "${1,,}" in
        auto) printf '%s' "AUTO" ;;
        ipv4|4|v4) printf '%s' "IPV4" ;;
        ipv6|6|v6) printf '%s' "IPV6" ;;
        dual|both|46) printf '%s' "DUAL" ;;
        *) die "出口模式只能是 auto、ipv4、ipv6 或 dual。" ;;
    esac
}

egress_mode_label() {
    case "${EGRESS_MODE}" in
        IPV4) printf '%s' "WARP IPv4" ;;
        IPV6) printf '%s' "WARP IPv6" ;;
        DUAL) printf '%s' "WARP IPv4 + IPv6" ;;
        AUTO) printf '%s' "自动补齐" ;;
        *) printf '%s' "未知" ;;
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
    local family="$1" proxy="${2:-}" output url="${TRACE_URL}"
    local -a args=(--fail --silent --show-error --max-time 12)
    case "${family}" in
        4) args+=(-4); url="${TRACE_V4_URL}" ;;
        6) args+=(-6); url="${TRACE_V6_URL}" ;;
    esac
    [[ -z "${proxy}" ]] || args+=(--socks5-hostname "${proxy}")
    output="$(curl "${args[@]}" "${url}" 2>/dev/null || true)"
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

ensure_effective_egress_mode() {
    EGRESS_MODE="$(normalize_egress_mode "${EGRESS_MODE}")"
    [[ "${EGRESS_MODE}" == "AUTO" ]] || return 0

    if [[ -z "${DIRECT_V4+x}" || -z "${DIRECT_V6+x}" ]]; then
        detect_connectivity
    fi
    if [[ -n "${DIRECT_V4}" && -n "${DIRECT_V6}" ]]; then
        EGRESS_MODE="DUAL"
    elif [[ -n "${DIRECT_V6}" ]]; then
        EGRESS_MODE="IPV4"
    elif [[ -n "${DIRECT_V4}" ]]; then
        EGRESS_MODE="IPV6"
    else
        die "无法根据原生网络自动选择 WARP 出口。"
    fi
    log "自动选择：$(egress_mode_label)。原生出口不会被替换。"
}

create_cloudflare_curl_config() {
    local output="$1"
    local inherited="${WARPM_AUTH_CURL_CONFIG:-}"
    local token="${WARPM_INSTALL_TOKEN:-${WARP3XUI_INSTALL_TOKEN:-}}"

    if [[ -n "${inherited}" && -r "${inherited}" ]]; then
        cp -- "${inherited}" "${output}"
        chmod 600 "${output}"
        return 0
    fi
    if [[ -z "${token}" && -r /dev/tty ]]; then
        printf 'Cloudflare 安装密钥（用于 R2 兜底）：' >/dev/tty
        IFS= read -r -s token </dev/tty || true
        printf '\n' >/dev/tty
    fi
    [[ -n "${token}" ]] || return 1
    [[ "${token}" != *$'\n'* && "${token}" != *$'\r'* && "${token}" != *'"'* ]] \
        || die "Cloudflare 安装密钥包含非法字符。"
    {
        printf 'header = "Authorization: Bearer %s"\n' "${token}"
        printf '%s\n' 'fail' 'silent' 'show-error' 'location'
        printf '%s\n' 'connect-timeout = 15' 'max-time = 300' 'retry = 3'
    } > "${output}"
    chmod 600 "${output}"
    unset token WARPM_INSTALL_TOKEN WARP3XUI_INSTALL_TOKEN 2>/dev/null || true
}

try_install_cloudflare_repo() {
    local -a repo_probe=(--fail --silent --show-error --location --max-time 15)
    if [[ -z "${DIRECT_V4:-}" && -n "${DIRECT_V6:-}" ]]; then
        repo_probe+=(-6)
    elif [[ -n "${DIRECT_V4:-}" && -z "${DIRECT_V6:-}" ]]; then
        repo_probe+=(-4)
    fi
    if ! curl "${repo_probe[@]}" https://pkg.cloudflareclient.com/pubkey.gpg \
        --output /dev/null; then
        return 1
    fi
    case "${OS_ID}" in
        debian|ubuntu)
            [[ -n "${OS_CODENAME}" ]] || return 1
            curl -fsSL https://pkg.cloudflareclient.com/pubkey.gpg \
                | gpg --yes --dearmor --output /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg \
                || return 1
            printf 'deb [signed-by=/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg] https://pkg.cloudflareclient.com/ %s main\n' \
                "${OS_CODENAME}" > /etc/apt/sources.list.d/cloudflare-client.list
            apt-get update || return 1
            apt-get install -y cloudflare-warp || return 1
            ;;
        rhel|centos|rocky|almalinux|fedora)
            curl -fsSL https://pkg.cloudflareclient.com/cloudflare-warp-ascii.repo \
                -o /etc/yum.repos.d/cloudflare-warp.repo || return 1
            rpm --import https://pkg.cloudflareclient.com/pubkey.gpg || return 1
            local pm="dnf"
            command -v dnf >/dev/null 2>&1 || pm="yum"
            "${pm}" install -y cloudflare-warp || return 1
            ;;
    esac
    command -v warp-cli >/dev/null 2>&1 || return 1
    CLIENT_INSTALL_SOURCE="official"
}

install_cloudflare_from_r2() {
    local arch package_base temp_dir curl_config package checksum expected actual version
    [[ "${OS_ID}" == "debian" || "${OS_ID}" == "ubuntu" ]] || return 1
    arch="$(normalize_arch "${ARCH}")"
    [[ "${arch}" == "amd64" ]] || {
        warn "R2 官方包镜像当前只同步 amd64，当前架构为 ${ARCH}。"
        return 1
    }
    [[ -n "${OS_CODENAME}" ]] || return 1
    validate_codename "${OS_CODENAME}"

    temp_dir="$(mktemp -d /tmp/warpm-package.XXXXXX)"
    curl_config="${temp_dir}/curl.conf"
    package="${temp_dir}/cloudflare-warp.deb"
    checksum="${temp_dir}/cloudflare-warp.sha256"
    chmod 700 "${temp_dir}"
    if ! create_cloudflare_curl_config "${curl_config}"; then
        rm -rf "${temp_dir}"
        return 1
    fi

    package_base="${CLOUDFLARE_BASE%/}/${WARP_PACKAGE_R2_PREFIX}/${OS_CODENAME}/${arch}/latest"
    if ! curl --config "${curl_config}" "${package_base}/cloudflare-warp.deb" -o "${package}" \
        || ! curl --config "${curl_config}" "${package_base}/cloudflare-warp.sha256" -o "${checksum}"; then
        rm -rf "${temp_dir}"
        return 1
    fi
    expected="$(tr -d '[:space:]' < "${checksum}")"
    actual="$(sha256_file "${package}" 2>/dev/null || true)"
    if [[ -z "${expected}" || "${expected}" != "${actual}" ]]; then
        rm -rf "${temp_dir}"
        warn "R2 中的 WARP 软件包 SHA256 校验失败。"
        return 1
    fi
    version="$(dpkg-deb -f "${package}" Version 2>/dev/null || true)"
    [[ -n "${version}" ]] || {
        rm -rf "${temp_dir}"
        return 1
    }
    log "正在安装 R2 镜像中的 Cloudflare 官方包 ${version}。"
    if ! apt-get install -y "${package}"; then
        rm -rf "${temp_dir}"
        return 1
    fi
    rm -rf "${temp_dir}"
    command -v warp-cli >/dev/null 2>&1 || return 1
    CLIENT_INSTALL_SOURCE="r2"
}

install_cloudflare_package() {
    detect_os
    if try_install_cloudflare_repo; then
        ok "已通过 Cloudflare 官方软件源安装 WARP。"
    else
        warn "Cloudflare 官方软件源不可用，尝试 Worker + 私有 R2 官方包镜像。"
        install_cloudflare_from_r2 \
            || die "官方软件源与 R2 镜像均不可用。R2 兜底仅支持已同步的 Debian/Ubuntu amd64；也可使用 NAT64、临时代理或离线官方包。"
        ok "已通过 R2 镜像安装 Cloudflare 官方 WARP 包。"
    fi
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
    local attempts="${1:-20}" i
    for ((i=1; i<=attempts; i++)); do
        if proxy_capabilities_ready; then
            return 0
        fi
        sleep 1
    done
    return 1
}

proxy_family_ready() {
    local trace
    trace="$(trace_value "$1" "127.0.0.1:${PORT}")"
    grep -Eq '^warp=(on|plus)$' <<<"${trace}"
}

proxy_capabilities_ready() {
    case "${EGRESS_MODE}" in
        IPV4) proxy_family_ready 4 ;;
        IPV6) proxy_family_ready 6 ;;
        DUAL) proxy_family_ready 4 && proxy_family_ready 6 ;;
        *) return 1 ;;
    esac
}

connect_with_fallback() {
    local requested="$1"
    if [[ "${requested}" == "AUTO" ]]; then
        log "先尝试 MASQUE。"
        configure_proxy_mode "MASQUE"
        if wait_for_proxy 15; then
            TUNNEL_PROTOCOL="MASQUE"
            return 0
        fi
        warn "MASQUE 未通过验证，回退 WireGuard。"
        configure_proxy_mode "WireGuard"
        wait_for_proxy 20 || return 1
        TUNNEL_PROTOCOL="WireGuard"
        return 0
    fi

    configure_proxy_mode "${requested}"
    wait_for_proxy 20 || return 1
    TUNNEL_PROTOCOL="${requested}"
}

save_config() {
    install -d -m 755 "${CONFIG_DIR}"
    {
        printf 'PORT=%s\n' "${PORT}"
        printf 'TUNNEL_PROTOCOL=%s\n' "${TUNNEL_PROTOCOL}"
        printf 'EGRESS_MODE=%s\n' "${EGRESS_MODE}"
        printf 'UPDATE_REPO=%s\n' "${UPDATE_REPO}"
        printf 'UPDATE_SOURCE=%s\n' "${UPDATE_SOURCE}"
        printf 'CLOUDFLARE_BASE=%s\n' "${CLOUDFLARE_BASE%/}"
        printf 'CLIENT_INSTALL_SOURCE=%s\n' "${CLIENT_INSTALL_SOURCE}"
    } > "${CONFIG_FILE}"
    chmod 600 "${CONFIG_FILE}"
    render_generic_proxy_files
}

render_generic_proxy_files() {
    install -d -m 755 "${CONFIG_DIR}"
    {
        printf 'WARP_PROXY_HOST=127.0.0.1\n'
        printf 'WARP_PROXY_PORT=%s\n' "${PORT}"
        printf 'WARP_PROXY_URL=socks5h://127.0.0.1:%s\n' "${PORT}"
        printf 'WARP_EGRESS_MODE=%s\n' "${EGRESS_MODE}"
    } > "${PROXY_ENV_FILE}"
    cat > "${PROXYCHAINS_FILE}" <<EOF
strict_chain
proxy_dns
remote_dns_subnet 224
tcp_read_time_out 15000
tcp_connect_time_out 8000

[ProxyList]
socks5 127.0.0.1 ${PORT}
EOF
    chmod 644 "${PROXY_ENV_FILE}" "${PROXYCHAINS_FILE}"
}

print_proxy_env() {
    load_config
    validate_port "${PORT}"
    printf "export ALL_PROXY='socks5h://127.0.0.1:%s'\n" "${PORT}"
    printf "export all_proxy='socks5h://127.0.0.1:%s'\n" "${PORT}"
    printf "export NO_PROXY='localhost,127.0.0.1,::1'\n"
    printf "export no_proxy='localhost,127.0.0.1,::1'\n"
}

show_proxy_info() {
    load_config
    validate_port "${PORT}"
    printf 'SOCKS5：127.0.0.1:%s\n' "${PORT}"
    printf 'URL：socks5h://127.0.0.1:%s\n' "${PORT}"
    printf '环境变量：warpm env\n'
    printf '单条命令：warpm run -- curl https://www.cloudflare.com/cdn-cgi/trace\n'
    printf 'ProxyChains：%s\n' "${PROXYCHAINS_FILE}"
}

run_via_warp() {
    load_config
    validate_port "${PORT}"
    [[ "${1:-}" == "--" ]] && shift
    (($#)) || die "run 后需要提供命令；示例：warpm run -- curl https://example.com"
    export ALL_PROXY="socks5h://127.0.0.1:${PORT}"
    export all_proxy="${ALL_PROXY}"
    export NO_PROXY="localhost,127.0.0.1,::1"
    export no_proxy="${NO_PROXY}"
    exec "$@"
}

curl_via_warp() {
    load_config
    validate_port "${PORT}"
    EGRESS_MODE="$(normalize_egress_mode "${EGRESS_MODE}")"
    local family="auto"
    local -a proxy_args=(--socks5-hostname "127.0.0.1:${PORT}")
    case "${EGRESS_MODE}" in
        IPV4) family="4" ;;
        IPV6) family="6" ;;
    esac
    case "${1:-}" in
        -4|--ipv4) family="4"; shift ;;
        -6|--ipv6) family="6"; shift ;;
    esac
    (($#)) || die "curl 后需要提供 URL 或其他 curl 参数。"
    case "${family}" in
        4) proxy_args=(--ipv4 --socks5 "127.0.0.1:${PORT}") ;;
        6) proxy_args=(--ipv6 --socks5 "127.0.0.1:${PORT}") ;;
    esac
    exec curl "${proxy_args[@]}" "$@"
}

install_manager() {
    local source_path
    source_path="$(readlink -f "${BASH_SOURCE[0]}")"
    if [[ "${source_path}" != "${MANAGER_PATH}" ]]; then
        install -m 755 "${source_path}" "${MANAGER_PATH}"
    fi
    if [[ "${LEGACY_MANAGER_PATH}" != "${MANAGER_PATH}" ]]; then
        ln -sfn "${MANAGER_PATH}" "${LEGACY_MANAGER_PATH}"
    fi
}

render_outbound_json() {
    local tag="$1" strategy="$2"
    cat <<EOF
{
  "tag": "${tag}",
  "protocol": "socks",
  "settings": {
    "address": "127.0.0.1",
    "port": ${PORT}
  },
  "targetStrategy": "${strategy}"
}
EOF
}

selected_outbound_tag() {
    case "${EGRESS_MODE}" in
        IPV4) printf '%s' "warp-ipv4" ;;
        IPV6) printf '%s' "warp-ipv6" ;;
        DUAL) printf '%s' "warp-auto" ;;
        *) die "无法为 ${EGRESS_MODE} 选择 Xray 出站。" ;;
    esac
}

render_snippets() {
    local selected_tag selected_file
    ensure_effective_egress_mode
    selected_tag="$(selected_outbound_tag)"
    selected_file="${CONFIG_DIR}/xray-outbound-${selected_tag#warp-}.json"
    install -d -m 755 "${CONFIG_DIR}"

    render_outbound_json "warp-ipv4" "ForceIPv4" \
        > "${CONFIG_DIR}/xray-outbound-ipv4.json"
    render_outbound_json "warp-ipv6" "ForceIPv6" \
        > "${CONFIG_DIR}/xray-outbound-ipv6.json"
    render_outbound_json "warp-auto" "UseIP" \
        > "${CONFIG_DIR}/xray-outbound-auto.json"

    case "${EGRESS_MODE}" in
        IPV4)
            jq -s '.' "${CONFIG_DIR}/xray-outbound-ipv4.json" \
                > "${CONFIG_DIR}/xray-outbounds.json"
            ;;
        IPV6)
            jq -s '.' "${CONFIG_DIR}/xray-outbound-ipv6.json" \
                > "${CONFIG_DIR}/xray-outbounds.json"
            ;;
        DUAL)
            jq -s '.' \
                "${CONFIG_DIR}/xray-outbound-ipv4.json" \
                "${CONFIG_DIR}/xray-outbound-ipv6.json" \
                "${CONFIG_DIR}/xray-outbound-auto.json" \
                > "${CONFIG_DIR}/xray-outbounds.json"
            ;;
    esac
    cp -- "${selected_file}" "${CONFIG_DIR}/xray-outbound.json"

    cat > "${CONFIG_DIR}/xray-routing-rule-tcp.json" <<EOF
{
  "type": "field",
  "domain": ["geosite:google"],
  "network": "tcp",
  "outboundTag": "${selected_tag}",
  "ruleTag": "Google via $(egress_mode_label)"
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
    jq -s '.' \
        "${CONFIG_DIR}/xray-routing-rule-tcp.json" \
        "${CONFIG_DIR}/xray-routing-rule-udp-block.json" \
        > "${CONFIG_DIR}/xray-routing-rules.json"
    chmod 600 "${CONFIG_DIR}"/*.json
    ok "可选 Xray/3x-ui 示例已生成：${CONFIG_DIR}/xray-outbounds.json"
    log "当前建议路由标签：${selected_tag}（$(egress_mode_label)）。"
}

render_integrations() {
    load_config
    render_generic_proxy_files
    render_snippets
    ok "通用代理环境与 ProxyChains 示例已生成在 ${CONFIG_DIR}/。"
}

extract_youtube_region() {
    local body
    local -a proxy_args=(--socks5-hostname "127.0.0.1:${PORT}")
    case "${EGRESS_MODE}" in
        IPV4) proxy_args=(--ipv4 --socks5 "127.0.0.1:${PORT}") ;;
        IPV6) proxy_args=(--ipv6 --socks5 "127.0.0.1:${PORT}") ;;
    esac
    body="$(curl --fail --silent --show-error --location --max-time 20 \
        "${proxy_args[@]}" "${YOUTUBE_REGION_URL}" 2>/dev/null || true)"
    grep -oE '"(countryCode|GL|INNERTUBE_CONTEXT_GL)":"[A-Z]{2}"' <<<"${body}" \
        | head -n1 | sed -E 's/.*:"([A-Z]{2})"/\1/' || true
}

test_warp_family() {
    local family="$1" label trace warp_state warp_ip location
    if [[ "${family}" == "4" ]]; then label="IPv4"; else label="IPv6"; fi
    trace="$(trace_value "${family}" "127.0.0.1:${PORT}")"
    warp_state="$(awk -F= '$1=="warp"{print $2}' <<<"${trace}")"
    warp_ip="$(awk -F= '$1=="ip"{print $2}' <<<"${trace}")"
    location="$(awk -F= '$1=="loc"{print $2}' <<<"${trace}")"

    if [[ "${warp_state}" =~ ^(on|plus)$ && -n "${warp_ip}" ]]; then
        if [[ "${family}" == "4" && "${warp_ip}" == *:* ]]; then
            warn "WARP ${label} 验收返回了非 IPv4 地址：${warp_ip}"
            return 1
        fi
        if [[ "${family}" == "6" && "${warp_ip}" != *:* ]]; then
            warn "WARP ${label} 验收返回了非 IPv6 地址：${warp_ip}"
            return 1
        fi
        ok "WARP ${label} 出口：${warp_ip}（${location:-地区未知}，${warp_state}）"
        return 0
    fi
    warn "WARP ${label} 出口不可用。"
    return 1
}

test_warp() {
    local strict="${1:-0}" google_code yt_region listen_line failures=0
    local -a proxy_args=(--socks5-hostname "127.0.0.1:${PORT}")
    ensure_effective_egress_mode

    case "${EGRESS_MODE}" in
        IPV4) test_warp_family 4 || ((failures+=1)) ;;
        IPV6) test_warp_family 6 || ((failures+=1)) ;;
        DUAL)
            test_warp_family 4 || ((failures+=1))
            test_warp_family 6 || ((failures+=1))
            ;;
    esac

    case "${EGRESS_MODE}" in
        IPV4) proxy_args=(--ipv4 --socks5 "127.0.0.1:${PORT}") ;;
        IPV6) proxy_args=(--ipv6 --socks5 "127.0.0.1:${PORT}") ;;
    esac

    google_code="$(curl --silent --output /dev/null --write-out '%{http_code}' --max-time 15 \
        "${proxy_args[@]}" "${GOOGLE_TEST_URL}" 2>/dev/null || true)"
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
    ensure_effective_egress_mode
    printf '\n%s v%s\n' "${PROJECT_NAME}" "${SCRIPT_VERSION}"
    printf '项目标识：%s\n' "${PROJECT_ID}"
    printf '代理地址：127.0.0.1:%s\n' "${PORT}"
    printf '隧道协议：%s\n' "${TUNNEL_PROTOCOL}"
    printf '可选出口：%s\n' "$(egress_mode_label)"
    printf '客户端安装来源：%s\n' "${CLIENT_INSTALL_SOURCE}"
    printf '旧版兼容标识：%s\n\n' "${LEGACY_PROJECT_ID}"
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
            --egress) [[ $# -ge 2 ]] || die "--egress 缺少值"; EGRESS_MODE="$(normalize_egress_mode "$2")"; shift 2 ;;
            --license-file) [[ $# -ge 2 ]] || die "--license-file 缺少值"; LICENSE_FILE="$2"; shift 2 ;;
            --repo) [[ $# -ge 2 ]] || die "--repo 缺少值"; UPDATE_REPO="$2"; shift 2 ;;
            --non-interactive) NON_INTERACTIVE=1; shift ;;
            *) die "未知 install 选项：$1" ;;
        esac
    done
    validate_port "${PORT}"
    [[ "${TUNNEL_PROTOCOL}" =~ ^(AUTO|MASQUE|WireGuard)$ ]] || TUNNEL_PROTOCOL="$(normalize_protocol "${TUNNEL_PROTOCOL}")"
    EGRESS_MODE="$(normalize_egress_mode "${EGRESS_MODE}")"
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

    interactive_egress_options
}

interactive_egress_options() {
    local default_choice input
    case "${EGRESS_MODE}" in
        IPV4) default_choice=1 ;;
        IPV6) default_choice=2 ;;
        DUAL) default_choice=3 ;;
        *) default_choice=4 ;;
    esac
    cat <<'EOF'
WARP 出口验收与可选 Xray 地址族：
  1. IPv4（IPv6-only 补 IPv4；warpm curl 默认 -4）
  2. IPv6（IPv4-only 补 IPv6；warpm curl 默认 -6）
  3. IPv4 + IPv6（两族都验收，普通 SOCKS 应用自行选择）
  4. 自动（单栈补另一族，双栈提供两族）
EOF
    printf '请选择 [%s]：' "${default_choice}"
    read -r input
    case "${input:-${default_choice}}" in
        1) EGRESS_MODE="IPV4" ;;
        2) EGRESS_MODE="IPV6" ;;
        3) EGRESS_MODE="DUAL" ;;
        4) EGRESS_MODE="AUTO"; ensure_effective_egress_mode ;;
        *) die "无效选项。" ;;
    esac
}

set_egress_mode() {
    require_root
    load_config
    detect_connectivity
    if [[ -n "${1:-}" ]]; then
        EGRESS_MODE="$(normalize_egress_mode "$1")"
        [[ $# -eq 1 ]] || die "set-egress 只接受一个出口模式。"
    else
        ensure_effective_egress_mode
        interactive_egress_options
    fi
    ensure_effective_egress_mode
    save_config
    render_integrations
    ok "已切换为 $(egress_mode_label)。系统默认路由和原生出口没有变化。"
    if command -v warp-cli >/dev/null 2>&1; then
        test_warp 0 || warn "配置已保存，但所选出口尚未全部通过验收。"
    fi
}

do_install() {
    require_root
    load_config
    parse_install_args "$@"
    log "安装基础依赖。"
    install_base_dependencies
    detect_connectivity
    ensure_effective_egress_mode
    if (( NON_INTERACTIVE == 0 )); then
        interactive_options
    fi
    ensure_effective_egress_mode
    NEW_INSTALL=1
    log "安装 Cloudflare 官方稳定版 WARP 客户端。"
    install_cloudflare_package
    ensure_registration
    apply_license "${LICENSE_KEY}"
    log "配置 Local Proxy；不会修改系统默认路由。"
    connect_with_fallback "${TUNNEL_PROTOCOL}" || die "WARP 代理无法连接。可改用 --protocol auto 重试。"
    proxy_capabilities_ready || die "所选 WARP IPv4/IPv6 出口未通过验证。"
    save_config
    install_manager
    render_snippets
    NEW_INSTALL=0
    test_warp 0 || warn "主体已安装，但仍有验收项需要查看。请运行：sudo warpm test --strict"
    ok "安装完成：$(egress_mode_label)。原生出口和系统默认路由保持不变。"
    log "直接使用：warpm proxy-info；warpm run -- COMMAND；warpm curl URL"
    log "可选 Xray/3x-ui 示例：${CONFIG_DIR}/xray-outbounds.json"
}

do_reconnect() {
    require_root
    load_config
    ensure_effective_egress_mode
    connect_with_fallback "${TUNNEL_PROTOCOL}" || die "重连失败。"
    proxy_capabilities_ready || die "重连后所选 WARP 出口仍不可用。"
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
    detect_connectivity
    install_cloudflare_package
    save_config
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
    local output="$1" temp_dir curl_config checksum expected actual script_path checksum_path
    CLOUDFLARE_BASE="${CLOUDFLARE_BASE%/}"
    temp_dir="$(mktemp -d /tmp/warpm-cloudflare.XXXXXX)"
    curl_config="${temp_dir}/curl.conf"
    checksum="${temp_dir}/warpm.sha256"
    chmod 700 "${temp_dir}"
    create_cloudflare_curl_config "${curl_config}" \
        || { rm -rf "${temp_dir}"; die "没有 Cloudflare 安装密钥。"; }

    script_path="releases/warpm/warpm.sh"
    checksum_path="releases/warpm/warpm.sha256"
    if ! curl --config "${curl_config}" "${CLOUDFLARE_BASE}/${script_path}" -o "${output}" \
        || ! curl --config "${curl_config}" "${CLOUDFLARE_BASE}/${checksum_path}" -o "${checksum}"; then
        warn "新发布路径不可用，尝试旧版兼容路径。"
        script_path="releases/warp3xui/warp-3xui.sh"
        checksum_path="releases/warp3xui/warp-3xui.sha256"
    fi
    if [[ ! -s "${output}" || ! -s "${checksum}" ]] \
        && { ! curl --config "${curl_config}" "${CLOUDFLARE_BASE}/${script_path}" -o "${output}" \
            || ! curl --config "${curl_config}" "${CLOUDFLARE_BASE}/${checksum_path}" -o "${checksum}"; }; then
        rm -rf "${temp_dir}"
        die "从 Cloudflare 下载管理脚本或 SHA256 失败。"
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
    temp_file="$(mktemp /tmp/warpm-update.XXXXXX)"
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
    grep -q 'PROJECT_ID="warp-egress-manager"' "${temp_file}" || die "更新文件不是本项目脚本。"
    new_version="$(version_from_file "${temp_file}")"
    [[ -n "${new_version}" ]] || die "无法读取新脚本版本。"
    cp -a "${MANAGER_PATH}" "${MANAGER_PATH}.bak" 2>/dev/null || true
    install -m 755 "${temp_file}" "${MANAGER_PATH}"
    if [[ "${LEGACY_MANAGER_PATH}" != "${MANAGER_PATH}" ]]; then
        ln -sfn "${MANAGER_PATH}" "${LEGACY_MANAGER_PATH}"
    fi
    rm -f "${temp_file}"
    save_config
    ok "管理脚本已更新：${SCRIPT_VERSION} -> ${new_version}。主命令：warpm。"
}

remove_generated_files() {
    local dir="$1"
    rm -f \
        "${dir}/config.env" \
        "${dir}/proxy.env" \
        "${dir}/proxychains.conf" \
        "${dir}/xray-outbound.json" \
        "${dir}/xray-outbound-ipv4.json" \
        "${dir}/xray-outbound-ipv6.json" \
        "${dir}/xray-outbound-auto.json" \
        "${dir}/xray-outbounds.json" \
        "${dir}/xray-routing-rule-tcp.json" \
        "${dir}/xray-routing-rule-udp-block.json" \
        "${dir}/xray-routing-rules.json" 2>/dev/null || true
    rmdir "${dir}" 2>/dev/null || true
}

do_uninstall() {
    require_root
    load_config
    printf '确认卸载 WARP Egress Manager 和 cloudflare-warp 软件包？[y/N] '
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
    rm -f "${MANAGER_PATH}" "${MANAGER_PATH}.bak" "${LEGACY_MANAGER_PATH}"
    remove_generated_files "${CONFIG_DIR}"
    [[ "${LEGACY_CONFIG_DIR}" == "${CONFIG_DIR}" ]] || remove_generated_files "${LEGACY_CONFIG_DIR}"
    ok "已卸载。脚本从未修改系统默认路由，因此无需恢复 SSH 路由。"
}

show_menu() {
    require_root
    load_config
    local choice
    while true; do
        cat <<EOF

WARP Egress Manager v${SCRIPT_VERSION}
1. 安装/重新配置
2. 状态与完整验证
3. 切换 IPv4/IPv6 WARP 出口
4. 查看代理地址与使用示例
5. 重新连接
6. 重建 WARP 注册
7. 更新 Cloudflare WARP 客户端（支持 R2 兜底）
8. 生成通用代理与可选 Xray/3x-ui 示例
9. 更新本管理脚本
10. 卸载
0. 退出
EOF
        printf '请选择 [0-10]：'
        read -r choice || return 0
        case "${choice}" in
            1) do_install ;;
            2) show_status ;;
            3) set_egress_mode ;;
            4) show_proxy_info ;;
            5) do_reconnect ;;
            6) do_rotate ;;
            7) update_client ;;
            8) render_integrations ;;
            9) self_update ;;
            10) do_uninstall; return 0 ;;
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
        set-egress) set_egress_mode "$@" ;;
        env) print_proxy_env ;;
        proxy-info|proxy) show_proxy_info ;;
        run) run_via_warp "$@" ;;
        curl) curl_via_warp "$@" ;;
        self-update) self_update "$@" ;;
        integrations|snippets) require_root; render_integrations ;;
        uninstall) do_uninstall ;;
        version|--version|-v) printf '%s\n' "${SCRIPT_VERSION}" ;;
        help|--help|-h) usage ;;
        *) usage; die "未知命令：${command}" ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
