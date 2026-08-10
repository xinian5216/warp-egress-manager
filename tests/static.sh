#!/usr/bin/env bash
set -Eeuo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
script="${repo_dir}/warp-3xui.sh"

bash -n "${script}"
[[ "$(bash "${script}" version)" == "$(<"${repo_dir}/VERSION")" ]]
bash "${script}" --help | grep -q 'Local Proxy'

if grep -Eq 'warp-cli( --accept-tos)? mode (warp|warp\+doh|tunnel_only)' "${script}"; then
    echo "Unsafe global WARP mode found" >&2
    exit 1
fi

if grep -Eq 'ip( -[46])? route (add|replace).*default.*(WARP|wgcf)' "${script}"; then
    echo "Unsafe WARP default route mutation found" >&2
    exit 1
fi

jq -e . "${repo_dir}/examples/xray-outbound.json" >/dev/null
jq -e . "${repo_dir}/examples/xray-routing-rules.json" >/dev/null

echo "Static checks passed"
