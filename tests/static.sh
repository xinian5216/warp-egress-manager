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
grep -Fq 'releases/warpm/warpm.sha256' "${script}"
grep -Fq 'releases/warpm/warpm.sha256' "${bootstrap}"
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
grep -Fq 'install_cloudflare_from_r2' "${script}"
grep -Fq 'packages/cloudflare-warp/deb' "${script}"
grep -Fq 'schedule:' "${repo_dir}/.github/workflows/sync-warp-packages.yml"
grep -Fq 'cloudflare-warp.deb' "${repo_dir}/.github/workflows/sync-warp-packages.yml"
grep -Fq 'ARCHIVE_KEEP_VERSIONS: "2"' "${repo_dir}/.github/workflows/sync-warp-packages.yml"
grep -Fq 'retain_recent_archives' "${repo_dir}/.github/workflows/sync-warp-packages.yml"
grep -Fq 'x-warpm-package-layout: archive-pointer-v1' \
    "${repo_dir}/.github/workflows/sync-warp-packages.yml"
grep -Fq 'latest}/version' "${repo_dir}/.github/workflows/sync-warp-packages.yml"
if grep -Fq '"s3://${R2_BUCKET}/${latest}/cloudflare-warp.deb"' \
    "${repo_dir}/.github/workflows/sync-warp-packages.yml"; then
    echo "Redundant latest package upload found" >&2
    exit 1
fi
# Match the literal workflow variables, not shell-expanded values.
# shellcheck disable=SC2016
grep -Fq 'aws s3 rm "s3://${R2_BUCKET}/${delete_prefix}"' "${repo_dir}/.github/workflows/sync-warp-packages.yml"
# shellcheck disable=SC2016
if grep -Fq 'aws s3 rm "s3://${R2_BUCKET}/packages/cloudflare-warp"' \
    "${repo_dir}/.github/workflows/sync-warp-packages.yml"; then
    echo "Broad R2 package deletion found" >&2
    exit 1
fi

menu_runner=(bash "${script}")
if (( EUID != 0 )); then
    menu_runner=(sudo -n bash "${script}")
fi
menu_output="$(printf '99\n\n0\n' | "${menu_runner[@]}" 2>&1)"
[[ "$(grep -c 'WARP Egress Manager v' <<<"${menu_output}")" -eq 2 ]]
grep -q '无效选项，请重新输入' <<<"${menu_output}"

if grep -Eq 'ip( -[46])? route (add|replace).*default.*(WARP|wgcf)' "${script}"; then
    echo "Unsafe WARP default route mutation found" >&2
    exit 1
fi

jq -e . "${repo_dir}/examples/xray-outbound.json" >/dev/null
jq -e . "${repo_dir}/examples/xray-routing-rules.json" >/dev/null

echo "Static checks passed"
