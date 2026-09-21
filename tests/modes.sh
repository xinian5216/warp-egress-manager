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

assert_equal "$(normalize_protocol masque)" "MASQUE"
assert_equal "$(normalize_protocol auto)" "MASQUE"
assert_equal "$(normalize_protocol wireguard)" "MASQUE"
assert_equal "$(migrate_tunnel_protocol WireGuard)" "MASQUE"
assert_equal "$(migrate_tunnel_protocol AUTO)" "MASQUE"

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

mkdir -p "${CONFIG_DIR}"
cat > "${CONFIG_FILE}" <<'EOF'
PORT=41234
TUNNEL_PROTOCOL=WireGuard
EGRESS_MODE=IPV4
UPDATE_REPO=xinian5216/warp-egress-manager
UPDATE_SOURCE=cloudflare
CLOUDFLARE_BASE=https://example.invalid
CLIENT_INSTALL_SOURCE=r2
EOF
load_config
assert_equal "${PORT}" "41234"
assert_equal "${TUNNEL_PROTOCOL}" "MASQUE"
assert_equal "${EGRESS_MODE}" "IPV4"
save_config
grep -Fq 'PORT=41234' "${CONFIG_FILE}"
grep -Fq 'TUNNEL_PROTOCOL=MASQUE' "${CONFIG_FILE}"
grep -Fq 'EGRESS_MODE=IPV4' "${CONFIG_FILE}"
grep -Fq 'UPDATE_REPO=xinian5216/warp-egress-manager' "${CONFIG_FILE}"
if grep -qE '^(UPDATE_SOURCE|CLOUDFLARE_BASE|CLIENT_INSTALL_SOURCE)=' "${CONFIG_FILE}"; then
    echo "Legacy keys were written back to config.env" >&2
    exit 1
fi

PORT="40000"
EGRESS_MODE="DUAL"
GITHUB_PROXY=""
save_config
render_integrations >/dev/null
jq -e '. == 40000' <(awk -F= '$1 == "WARP_PROXY_PORT" {print $2}' "${PROXY_ENV_FILE}") >/dev/null
grep -Fq 'socks5 127.0.0.1 40000' "${PROXYCHAINS_FILE}"
# Capture into a variable instead of piping to grep -q to avoid a SIGPIPE
# race between print_proxy_env and an early-closing reader.
proxy_env_output="$(print_proxy_env)"
grep -Fq "ALL_PROXY='socks5h://127.0.0.1:40000'" <<<"${proxy_env_output}"
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

is_github_url 'https://github.com/xinian5216/warp-egress-manager' \
    || { echo "github.com URL should match" >&2; exit 1; }
is_github_url 'https://api.github.com/repos/xinian5216/warp-egress-manager/contents/warp-3xui.sh' \
    || { echo "api.github.com URL should match" >&2; exit 1; }
is_github_url 'https://pkg.cloudflareclient.com/pubkey.gpg' \
    && { echo "Cloudflare URL must not be treated as GitHub" >&2; exit 1; }
is_github_url 'https://www.cloudflare.com/cdn-cgi/trace' \
    && { echo "Cloudflare trace URL must not be treated as GitHub" >&2; exit 1; }
is_github_url 'https://www.google.com/generate_204' \
    && { echo "Google URL must not be treated as GitHub" >&2; exit 1; }
is_github_url 'https://www.youtube.com/premium' \
    && { echo "YouTube URL must not be treated as GitHub" >&2; exit 1; }

curl() {
    printf '%s\n' "$*" > "${test_dir}/curl_invocation"
    return 0
}

unset WARPM_GITHUB_PROXY || true
GITHUB_PROXY=""
github_curl -fsSL https://api.github.com/repos/example/example
if grep -F -- '--proxy' "${test_dir}/curl_invocation"; then
    echo "github_curl without proxy leaked --proxy" >&2
    exit 1
fi
grep -Fq 'https://api.github.com/repos/example/example' "${test_dir}/curl_invocation"

WARPM_GITHUB_PROXY='https://example-proxy:8443'
github_curl -fsSL https://api.github.com/repos/example/example
grep -Fq -- '--proxy https://example-proxy:8443' "${test_dir}/curl_invocation"
grep -Fq 'https://api.github.com/repos/example/example' "${test_dir}/curl_invocation"

WARPM_GITHUB_PROXY='https://example-proxy:8443'
trace_value 4 >/dev/null || true
if grep -F -- '--proxy' "${test_dir}/curl_invocation"; then
    echo "Cloudflare trace was sent through GitHub Proxy" >&2
    exit 1
fi
grep -Fq 'https://1.1.1.1/cdn-cgi/trace' "${test_dir}/curl_invocation"

YOUTUBE_REGION_URL='https://www.youtube.com/premium'
EGRESS_MODE="DUAL"
extract_youtube_region >/dev/null || true
if grep -F -- '--proxy' "${test_dir}/curl_invocation"; then
    echo "YouTube check was sent through GitHub Proxy" >&2
    exit 1
fi
grep -Fq 'https://www.youtube.com/premium' "${test_dir}/curl_invocation"

unset -f curl
unset WARPM_GITHUB_PROXY || true
GITHUB_PROXY=""

assert_equal "$(github_raw_url)" \
    "https://raw.githubusercontent.com/xinian5216/warp-egress-manager/main/warp-3xui.sh"
assert_equal "$(github_raw_url 'other/repo')" \
    "https://raw.githubusercontent.com/other/repo/main/warp-3xui.sh"
# Explicit ref (release tag) must be used verbatim; this is the production path.
assert_equal "$(github_raw_url 'xinian5216/warp-egress-manager' warp-3xui.sh 'v1.4.1')" \
    "https://raw.githubusercontent.com/xinian5216/warp-egress-manager/v1.4.1/warp-3xui.sh"

# --- Release tag validation (path-injection guard) ---
validate_release_tag 'v1.4.1'
validate_release_tag 'v2.0.0'
# die() exits, so negative cases must run in a subshell.
for bad in '../../main' 'main' 'refs/heads/main' 'v1.4' 'v1.4.1/xxx' 'v1.4.1/../../x' 'V1.4.1' 'v1.4.1-rc1'; do
    if (validate_release_tag "${bad}") >/dev/null 2>&1; then
        echo "validate_release_tag should reject: ${bad}" >&2
        exit 1
    fi
done

# --- Version comparison ---
assert_equal "$(compare_versions 1.4.0 1.4.1)" '-1'
assert_equal "$(compare_versions 1.4.1 1.4.1)" '0'
assert_equal "$(compare_versions 1.5.0 1.4.1)" '1'
assert_equal "$(compare_versions 1.4.10 1.4.9)" '1'
assert_equal "$(compare_versions 2.0.0 10.0.0)" '-1'
assert_equal "$(compare_versions 1.10.0 1.9.0)" '1'

# --- latest stable release resolution ---
# 1. latest stable -> downloads from the tag, not main.
github_curl() { printf '%s' '{"tag_name":"v1.4.1","draft":false,"prerelease":false}'; }
assert_equal "$(resolve_latest_release_tag 'xinian5216/warp-egress-manager')" 'v1.4.1'
# 2. prerelease -> rejected.
github_curl() { printf '%s' '{"tag_name":"v1.5.0-beta.1","draft":false,"prerelease":true}'; }
if (resolve_latest_release_tag 'xinian5216/warp-egress-manager') >/dev/null 2>&1; then
    echo "prerelease must be rejected" >&2
    exit 1
fi
# 3. draft -> rejected.
github_curl() { printf '%s' '{"tag_name":"v1.4.1","draft":true,"prerelease":false}'; }
if (resolve_latest_release_tag 'xinian5216/warp-egress-manager') >/dev/null 2>&1; then
    echo "draft must be rejected" >&2
    exit 1
fi
# 4. invalid tag -> rejected.
for bad_json in \
    '{"tag_name":"../../main","draft":false,"prerelease":false}' \
    '{"tag_name":"v1.4","draft":false,"prerelease":false}' \
    '{"tag_name":"main","draft":false,"prerelease":false}' \
    '{"tag_name":"v1.4.1/xxx","draft":false,"prerelease":false}'; do
    github_curl() { printf '%s' "${bad_json}"; }
    if (resolve_latest_release_tag 'xinian5216/warp-egress-manager') >/dev/null 2>&1; then
        echo "invalid tag must be rejected: ${bad_json}" >&2
        exit 1
    fi
done
# 5. API failure -> fail closed, no main fallback.
github_curl() { return 22; }
if (resolve_latest_release_tag 'xinian5216/warp-egress-manager') >/dev/null 2>&1; then
    echo "API failure must fail closed" >&2
    exit 1
fi
# 6. no release / 404-ish / empty -> fail closed.
github_curl() { printf '%s' '{"message":"Not Found"}'; }
if (resolve_latest_release_tag 'xinian5216/warp-egress-manager') >/dev/null 2>&1; then
    echo "missing release must fail closed" >&2
    exit 1
fi
github_curl() { printf '%s' 'not json at all'; }
if (resolve_latest_release_tag 'xinian5216/warp-egress-manager') >/dev/null 2>&1; then
    echo "invalid JSON must fail closed" >&2
    exit 1
fi
github_curl() { printf '%s' ''; }
if (resolve_latest_release_tag 'xinian5216/warp-egress-manager') >/dev/null 2>&1; then
    echo "empty payload must fail closed" >&2
    exit 1
fi
# 7. repo name validation still applies to the API path.
github_curl() { printf '%s' '{"tag_name":"v1.4.1","draft":false,"prerelease":false}'; }
if (resolve_latest_release_tag 'not a repo') >/dev/null 2>&1; then
    echo "resolve_latest_release_tag must validate the repo" >&2
    exit 1
fi
# Restore a github_curl that delegates to the curl override (no body output),
# keeping the same proxy decision logic as the script.
unset -f github_curl
github_curl() {
    local proxy
    proxy="$(github_proxy_url)"
    if [[ -n "${proxy}" ]]; then
        curl --proxy "${proxy}" "$@"
    else
        curl "$@"
    fi
}

WARPM_GITHUB_PROXY='http://127.0.0.1:3129'
curl() {
    printf '%s\n' "$*" > "${test_dir}/curl_invocation"
    : > "${test_dir}/curl_out"
    return 0
}
github_curl -fsSL https://api.github.com/repos/example/example
grep -Fq -- '--proxy http://127.0.0.1:3129' "${test_dir}/curl_invocation"
fetch_update_url "$(github_raw_url)" "${test_dir}/curl_out"
grep -Fq -- '--proxy http://127.0.0.1:3129' "${test_dir}/curl_invocation"
grep -Fq 'https://raw.githubusercontent.com/xinian5216/warp-egress-manager/main/warp-3xui.sh' \
    "${test_dir}/curl_invocation"
# Release-tag raw URL is still a GitHub URL, so it must also go through the proxy.
fetch_update_url "$(github_raw_url 'xinian5216/warp-egress-manager' warp-3xui.sh 'v1.4.1')" "${test_dir}/curl_out"
grep -Fq -- '--proxy http://127.0.0.1:3129' "${test_dir}/curl_invocation"
grep -Fq 'https://raw.githubusercontent.com/xinian5216/warp-egress-manager/v1.4.1/warp-3xui.sh' \
    "${test_dir}/curl_invocation"
unset -f curl
unset WARPM_GITHUB_PROXY || true
GITHUB_PROXY=""

WARPM_GITHUB_PROXY='https://example-proxy:8443'
curl() {
    printf '%s\n' "$*" > "${test_dir}/curl_invocation"
    return 0
}
fetch_update_url "$(github_raw_url)" "${test_dir}/curl_out"
grep -Fq -- '--proxy https://example-proxy:8443' "${test_dir}/curl_invocation"
unset -f curl
unset WARPM_GITHUB_PROXY || true
GITHUB_PROXY=""

printf '<!DOCTYPE html>\n<html>\n' > "${test_dir}/html"
html_first="$(grep -m1 -v '^[[:space:]]*$' "${test_dir}/html")"
case "${html_first,,}" in
    '<!doctype html'*|'<html'*) ;;
    *) echo "HTML fixture should look like an HTML error page" >&2; exit 1 ;;
esac
: > "${test_dir}/empty"
[[ ! -s "${test_dir}/empty" ]]
validate_update_payload "${repo_dir}/warp-3xui.sh"

require_root() { :; }
LEGACY_MANAGER_PATH="${MANAGER_PATH}"
MANAGER_PATH="${test_dir}/sbin/warpm"
LEGACY_MANAGER_PATH="${MANAGER_PATH}"
install -d -m 755 "$(dirname -- "${MANAGER_PATH}")"
printf '%s\n' '#!/usr/bin/env bash' 'echo old-warpm' > "${MANAGER_PATH}"
chmod 755 "${MANAGER_PATH}"
self_update --file "${repo_dir}/warp-3xui.sh"
grep -q 'PROJECT_ID="warp-egress-manager"' "${MANAGER_PATH}"
grep -Fq 'echo old-warpm' "${MANAGER_PATH}.bak"
shopt -s nullglob
leftovers=("${test_dir}/sbin"/.warpm-update.*)
shopt -u nullglob
((${#leftovers[@]} == 0)) || {
    echo "update temp file left behind: ${leftovers[*]}" >&2
    exit 1
}

printf '%s\n' '#!/usr/bin/env bash' 'echo old-warpm' > "${MANAGER_PATH}"
chmod 755 "${MANAGER_PATH}"
if (
    mv() {
        local dest="${*: -1}"
        if [[ "${dest}" == "${MANAGER_PATH}" ]]; then
            return 1
        fi
        command mv "$@"
    }
    self_update --file "${repo_dir}/warp-3xui.sh"
); then
    echo "self_update should fail when replace cannot rename" >&2
    exit 1
fi
grep -Fq 'echo old-warpm' "${MANAGER_PATH}"

printf 'Mode tests passed\n'
