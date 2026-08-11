#!/usr/bin/env bash
set -Eeuo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
script="${repo_dir}/warp-3xui.sh"
bootstrap="${repo_dir}/cloudflare-install.sh"

bash -n "${script}"
bash -n "${bootstrap}"
bash -n "${repo_dir}/tests/modes.sh"
[[ "$(bash "${script}" version)" == "$(<"${repo_dir}/VERSION")" ]]
bash "${script}" --help | grep -q 'Local Proxy'

if grep -Eq 'warp-cli( --accept-tos)? mode (warp|warp\+doh|tunnel_only)' "${script}"; then
    echo "Unsafe global WARP mode found" >&2
    exit 1
fi

grep -Fq 'UPDATE_SOURCE="cloudflare"' "${script}"
grep -Fq 'warp-3xui-download.xinian5216.workers.dev' "${script}"
grep -Fq 'warp-3xui-download.xinian5216.workers.dev' "${bootstrap}"
if grep -Fq 'xray-manager-private' "${repo_dir}/.github/workflows/publish-r2.yml"; then
    echo "Shared xray-manager R2 bucket found in warp publish workflow" >&2
    exit 1
fi
grep -Fq 'R2_BUCKET: warp-3xui-private' "${repo_dir}/.github/workflows/publish-r2.yml"
grep -Fq 'public/install.sh' "${repo_dir}/.github/workflows/publish-r2.yml"
grep -Fq '/releases/warp3xui/warp-3xui.sha256' "${script}"
grep -Fq '/releases/warp3xui/warp-3xui.sha256' "${bootstrap}"
grep -Fq 'PROJECT_ID="warp-3xui-safe"' "${script}"
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

menu_runner=(bash "${script}")
if (( EUID != 0 )); then
    menu_runner=(sudo -n bash "${script}")
fi
menu_output="$(printf '10\n\n0\n' | "${menu_runner[@]}" 2>&1)"
[[ "$(grep -c 'WARP Safe Manager v' <<<"${menu_output}")" -eq 2 ]]
grep -q '无效选项，请重新输入' <<<"${menu_output}"

if grep -Eq 'ip( -[46])? route (add|replace).*default.*(WARP|wgcf)' "${script}"; then
    echo "Unsafe WARP default route mutation found" >&2
    exit 1
fi

jq -e . "${repo_dir}/examples/xray-outbound.json" >/dev/null
jq -e . "${repo_dir}/examples/xray-routing-rules.json" >/dev/null

echo "Static checks passed"
