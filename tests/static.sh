#!/usr/bin/env bash
set -Eeuo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
script="${repo_dir}/warp-3xui.sh"

bash -n "${script}"
bash -n "${repo_dir}/tests/modes.sh"
[[ "$(bash "${script}" version)" == "$(<"${repo_dir}/VERSION")" ]]
bash "${script}" --help | grep -q 'Local Proxy'
bash "${script}" --help | grep -q 'GitHub Proxy'

if grep -Eq 'warp-cli( --accept-tos)? mode (warp|warp\+doh|tunnel_only)' "${script}"; then
    echo "Unsafe global WARP mode found" >&2
    exit 1
fi

grep -Fq 'PROJECT_ID="warp-egress-manager"' "${script}"
grep -Fq 'LEGACY_PROJECT_ID="warp-3xui-safe"' "${script}"
grep -Fq 'UPDATE_REPO="xinian5216/warp-egress-manager"' "${script}"
grep -Fq '/usr/local/sbin/warpm' "${script}"
grep -Fq 'run_via_warp' "${script}"
grep -Fq 'curl_via_warp' "${script}"
grep -Fq "printf 'EGRESS_MODE=%s" "${script}"
# Verify that the literal template placeholder is present.
# shellcheck disable=SC2016
grep -Fq '"targetStrategy": "${strategy}"' "${script}"
grep -Fq 'ForceIPv4' "${script}"
grep -Fq 'ForceIPv6' "${script}"
grep -Fq 'set-egress' "${script}"
grep -Fq 'github_curl()' "${script}"
grep -Fq 'github_raw_url()' "${script}"
grep -Fq 'raw.githubusercontent.com' "${script}"
grep -Fq 'pkg.cloudflareclient.com' "${script}"

# Stable update channel: default self-update must resolve the latest formal
# GitHub Release. Fail closed on any error; there must be no main fallback.
grep -Fq 'releases/latest' "${script}"
grep -Fq 'resolve_latest_release_tag' "${script}"
grep -Fq 'validate_release_tag' "${script}"
grep -Fq 'compare_versions' "${script}"
# Any code path that resolves to main must require the explicit --main flag.
if grep -Eq 'source_value="\$\(github_raw_url\)"' "${script}"; then
    grep -Fq -- '--main' "${script}" || { echo "--main flag missing" >&2; exit 1; }
fi
if grep -Fq 'github_gh()' "${script}"; then
    echo "github_gh should have been removed" >&2
    exit 1
fi
if grep -Eq 'gh[[:space:]]+auth|gh[[:space:]]+api' "${script}"; then
    echo "self-update must not require gh CLI" >&2
    exit 1
fi
if grep -Fq 'command -v gh' "${script}"; then
    echo "self-update must not require gh" >&2
    exit 1
fi
if grep -Fq 'mktemp /tmp/warpm-update' "${script}"; then
    echo "self-update must not stage replacements in /tmp" >&2
    exit 1
fi
# Match the literal template in self_update.
# shellcheck disable=SC2016
grep -Fq 'dirname -- "${MANAGER_PATH}"' "${script}"
grep -Fq 'restore_manager_backup' "${script}"
grep -Fq '.warpm-update.XXXXXX' "${script}"

if awk '/^try_install_cloudflare_repo\(\)/,/^}/' "${script}" | grep -q 'github_curl'; then
    echo "Cloudflare package install must not use github_curl" >&2
    exit 1
fi
if awk '/^trace_value\(\)/,/^}/' "${script}" | grep -q 'github_curl'; then
    echo "Cloudflare trace must not use github_curl" >&2
    exit 1
fi
if awk '/^extract_youtube_region\(\)/,/^}/' "${script}" | grep -q 'github_curl'; then
    echo "YouTube check must not use github_curl" >&2
    exit 1
fi

if grep -Eq '^[[:space:]]*export[[:space:]]+(HTTP_PROXY|HTTPS_PROXY|http_proxy|https_proxy)' "${script}"; then
    echo "Global proxy export found" >&2
    exit 1
fi
if grep -Eq '>(>)?[[:space:]]*/etc/environment' "${script}"; then
    echo "Script writes /etc/environment" >&2
    exit 1
fi
if grep -Fq 'git config --global http.proxy' "${script}"; then
    echo "Script sets git global proxy" >&2
    exit 1
fi
if grep -Eq 'curl[[:space:]]+(-k|--insecure)\b' "${script}"; then
    echo "Insecure curl found" >&2
    exit 1
fi

assert_no_r2_worker() {
    local file="$1" label="$2"
    if grep -niE 'workers\.dev|R2_ACCESS_KEY_ID|R2_SECRET_ACCESS_KEY|warp-3xui-private|install_cloudflare_from_r2|download_cloudflare_update|packages/cloudflare-warp/deb|WARPM_INSTALL_TOKEN' "${file}"; then
        echo "Forbidden R2/Worker dependency in ${label}" >&2
        exit 1
    fi
}

assert_no_r2_worker "${script}" "warp-3xui.sh"
assert_no_r2_worker "${repo_dir}/README.md" "README.md"
shopt -s nullglob
for workflow in "${repo_dir}/.github/workflows/"*.yml "${repo_dir}/.github/workflows/"*.yaml; do
    assert_no_r2_worker "${workflow}" "${workflow#"${repo_dir}/"}"
done
shopt -u nullglob

if [[ -e "${repo_dir}/cloudflare-install.sh" ]]; then
    echo "cloudflare-install.sh should have been removed" >&2
    exit 1
fi
if [[ -d "${repo_dir}/worker" ]]; then
    echo "worker/ should have been removed" >&2
    exit 1
fi
if [[ -e "${repo_dir}/.github/workflows/publish-r2.yml" ]]; then
    echo "publish-r2.yml should have been removed" >&2
    exit 1
fi
if [[ -e "${repo_dir}/.github/workflows/sync-warp-packages.yml" ]]; then
    echo "sync-warp-packages.yml should have been removed" >&2
    exit 1
fi

menu_runner=()
if (( EUID == 0 )); then
    menu_runner=(bash "${script}")
elif command -v sudo >/dev/null 2>&1 && sudo -n true >/dev/null 2>&1; then
    menu_runner=(sudo -n bash "${script}")
fi
if ((${#menu_runner[@]})); then
    menu_output="$(printf '99\n\n0\n' | "${menu_runner[@]}" 2>&1)"
    [[ "$(grep -c 'WARP Egress Manager v' <<<"${menu_output}")" -eq 2 ]]
    grep -q '无效选项，请重新输入' <<<"${menu_output}"
fi

if grep -Eq 'ip( -[46])? route (add|replace).*default.*(WARP|wgcf)' "${script}"; then
    echo "Unsafe WARP default route mutation found" >&2
    exit 1
fi

jq -e . "${repo_dir}/examples/xray-outbound.json" >/dev/null
jq -e . "${repo_dir}/examples/xray-routing-rules.json" >/dev/null

echo "Static checks passed"
