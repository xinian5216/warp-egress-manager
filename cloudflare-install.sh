#!/usr/bin/env bash
set -Eeuo pipefail

BASE_URL="${WARPM_CLOUDFLARE_URL:-${WARP3XUI_CLOUDFLARE_URL:-https://warp-3xui-download.xinian5216.workers.dev}}"
BASE_URL="${BASE_URL%/}"

if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
    echo "请使用 root 权限运行：sudo bash $0"
    exit 1
fi

for command_name in curl bash; do
    if ! command -v "${command_name}" >/dev/null 2>&1; then
        echo "缺少必要命令：${command_name}"
        exit 1
    fi
done

read -rsp "安装密钥: " INSTALL_TOKEN </dev/tty
echo
[[ -n "${INSTALL_TOKEN}" ]] || { echo "安装密钥不能为空"; exit 1; }
[[ "${INSTALL_TOKEN}" != *$'\n'* && "${INSTALL_TOKEN}" != *$'\r'* && "${INSTALL_TOKEN}" != *'"'* ]] \
    || { echo "安装密钥包含非法字符"; exit 1; }

WORK_DIR="$(mktemp -d /tmp/warpm-install.XXXXXX)"
CURL_CONFIG="${WORK_DIR}/curl.conf"
SCRIPT_FILE="${WORK_DIR}/warpm.sh"
CHECKSUM_FILE="${WORK_DIR}/warpm.sha256"

cleanup() {
    rm -rf "${WORK_DIR}"
    unset INSTALL_TOKEN WARPM_INSTALL_TOKEN WARP3XUI_INSTALL_TOKEN 2>/dev/null || true
}
trap cleanup EXIT INT TERM
chmod 700 "${WORK_DIR}"

{
    printf 'header = "Authorization: Bearer %s"\n' "${INSTALL_TOKEN}"
    printf '%s\n' 'fail' 'silent' 'show-error' 'location'
    printf '%s\n' 'connect-timeout = 15' 'max-time = 180' 'retry = 3'
} > "${CURL_CONFIG}"
chmod 600 "${CURL_CONFIG}"
unset INSTALL_TOKEN

echo "正在通过 Cloudflare 下载 WARP Egress Manager……"
if ! curl --config "${CURL_CONFIG}" \
        "${BASE_URL}/releases/warpm/warpm.sh" -o "${SCRIPT_FILE}" \
    || ! curl --config "${CURL_CONFIG}" \
        "${BASE_URL}/releases/warpm/warpm.sha256" -o "${CHECKSUM_FILE}"; then
    echo "新发布路径不可用，尝试旧版兼容路径……"
    rm -f "${SCRIPT_FILE}" "${CHECKSUM_FILE}"
    curl --config "${CURL_CONFIG}" \
        "${BASE_URL}/releases/warp3xui/warp-3xui.sh" -o "${SCRIPT_FILE}"
    curl --config "${CURL_CONFIG}" \
        "${BASE_URL}/releases/warp3xui/warp-3xui.sha256" -o "${CHECKSUM_FILE}"
fi

EXPECTED="$(tr -d '[:space:]' < "${CHECKSUM_FILE}")"
if command -v sha256sum >/dev/null 2>&1; then
    ACTUAL="$(sha256sum "${SCRIPT_FILE}" | awk '{print $1}')"
elif command -v openssl >/dev/null 2>&1; then
    ACTUAL="$(openssl dgst -sha256 "${SCRIPT_FILE}" | awk '{print $NF}')"
else
    echo "无法校验安装脚本：缺少 sha256sum 或 openssl"
    exit 1
fi
[[ -n "${EXPECTED}" && "${EXPECTED}" == "${ACTUAL}" ]] \
    || { echo "安装脚本 SHA256 校验失败"; exit 1; }

bash -n "${SCRIPT_FILE}"
grep -q 'PROJECT_ID="warp-egress-manager"' "${SCRIPT_FILE}" \
    || { echo "下载内容不是 WARP Egress Manager"; exit 1; }

echo "校验通过，开始安装……"
WARPM_UPDATE_SOURCE=cloudflare \
WARPM_CLOUDFLARE_URL="${BASE_URL}" \
WARPM_AUTH_CURL_CONFIG="${CURL_CONFIG}" \
bash "${SCRIPT_FILE}" install "$@"

echo
echo "以后直接运行：sudo warpm（旧命令 sudo warp3xui 仍兼容）"
