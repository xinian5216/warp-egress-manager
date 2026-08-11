#!/usr/bin/env bash
set -Eeuo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
test_dir="$(mktemp -d /tmp/warpm-modes.XXXXXX)"
trap 'rm -rf "${test_dir}"' EXIT

export WARPM_CONFIG_DIR="${test_dir}/config"
# Source path is resolved from the repository at runtime.
# shellcheck disable=SC1091
source "${repo_dir}/warp-3xui.sh"

assert_equal() {
    [[ "$1" == "$2" ]] || {
        printf 'expected %s, got %s\n' "$2" "$1" >&2
        exit 1
    }
}

assert_equal "$(normalize_arch x86_64)" "amd64"
assert_equal "$(normalize_arch amd64)" "amd64"
assert_equal "$(normalize_arch aarch64)" "arm64"
validate_codename bookworm
validate_codename ubuntu-24.04

# Consumed by functions from the sourced manager script.
# shellcheck disable=SC2034
DIRECT_V4=""
# shellcheck disable=SC2034
DIRECT_V6="2001:db8::10"
EGRESS_MODE="AUTO"
ensure_effective_egress_mode
assert_equal "${EGRESS_MODE}" "IPV4"

# shellcheck disable=SC2034
DIRECT_V4="192.0.2.10"
# shellcheck disable=SC2034
DIRECT_V6=""
EGRESS_MODE="AUTO"
ensure_effective_egress_mode
assert_equal "${EGRESS_MODE}" "IPV6"

# shellcheck disable=SC2034
DIRECT_V4="192.0.2.10"
# shellcheck disable=SC2034
DIRECT_V6="2001:db8::10"
EGRESS_MODE="AUTO"
ensure_effective_egress_mode
assert_equal "${EGRESS_MODE}" "DUAL"

# shellcheck disable=SC2034
PORT="40000"
EGRESS_MODE="DUAL"
CLIENT_INSTALL_SOURCE="r2"
save_config
render_integrations >/dev/null
jq -e '. == 40000' <(awk -F= '$1 == "WARP_PROXY_PORT" {print $2}' "${PROXY_ENV_FILE}") >/dev/null
grep -Fq 'socks5 127.0.0.1 40000' "${PROXYCHAINS_FILE}"
grep -Fq 'CLIENT_INSTALL_SOURCE=r2' "${CONFIG_FILE}"
print_proxy_env | grep -Fq "ALL_PROXY='socks5h://127.0.0.1:40000'"
jq -e 'length == 3' "${CONFIG_DIR}/xray-outbounds.json" >/dev/null
jq -e 'map(.targetStrategy) == ["ForceIPv4", "ForceIPv6", "UseIP"]' \
    "${CONFIG_DIR}/xray-outbounds.json" >/dev/null
jq -e '.[0].outboundTag == "warp-auto"' \
    "${CONFIG_DIR}/xray-routing-rules.json" >/dev/null

EGRESS_MODE="IPV4"
render_snippets >/dev/null
jq -e 'length == 1 and .[0].tag == "warp-ipv4"' \
    "${CONFIG_DIR}/xray-outbounds.json" >/dev/null
jq -e '.outboundTag == "warp-ipv4"' \
    "${CONFIG_DIR}/xray-routing-rule-tcp.json" >/dev/null

printf 'Mode tests passed\n'
