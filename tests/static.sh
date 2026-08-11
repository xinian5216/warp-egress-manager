#!/usr/bin/env bash
set -Eeuo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
script="${repo_dir}/warp-3xui.sh"
bootstrap="${repo_dir}/cloudflare-install.sh"

bash -n "${script}"
bash -n "${bootstrap}"
[[ "$(bash "${script}" version)" == "$(<"${repo_dir}/VERSION")" ]]
bash "${script}" --help | grep -q 'Local Proxy'

if grep -Eq 'warp-cli( --accept-tos)? mode (warp|warp\+doh|tunnel_only)' "${script}"; then
    echo "Unsafe global WARP mode found" >&2
    exit 1
fi

grep -Fq 'UPDATE_SOURCE="cloudflare"' "${script}"
grep -Fq '/releases/warp3xui/warp-3xui.sha256' "${script}"
grep -Fq '/releases/warp3xui/warp-3xui.sha256' "${bootstrap}"

menu_runner=(bash "${script}")
if (( EUID != 0 )); then
    menu_runner=(sudo -n bash "${script}")
fi
menu_output="$(printf '9\n\n0\n' | "${menu_runner[@]}" 2>&1)"
[[ "$(grep -c 'WARP for 3x-ui v' <<<"${menu_output}")" -eq 2 ]]
grep -q '无效选项，请重新输入' <<<"${menu_output}"

if grep -Eq 'ip( -[46])? route (add|replace).*default.*(WARP|wgcf)' "${script}"; then
    echo "Unsafe WARP default route mutation found" >&2
    exit 1
fi

jq -e . "${repo_dir}/examples/xray-outbound.json" >/dev/null
jq -e . "${repo_dir}/examples/xray-routing-rules.json" >/dev/null

echo "Static checks passed"
