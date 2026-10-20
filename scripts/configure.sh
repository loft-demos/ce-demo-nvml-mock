#!/usr/bin/env bash
# Fills the placeholders in platform/ and cloud-init/machine-config-templates/ from an
# env file and writes the result to out/. Set the values for the providers you use; the
# others can stay as the env.example defaults (their templates just won't be usable), one file per object, ready to apply:
#
#   cp env.example env.local && $EDITOR env.local
#   scripts/configure.sh env.local
#   kubectl apply -f out/            # against the vCluster Platform management API
set -euo pipefail

env_file="${1:?usage: scripts/configure.sh <env file>}"
root="$(cd "$(dirname "$0")/.." && pwd)"
out="${OUT_DIR:-$root/out}"

vars=(KUBEVIRT_NODE_PROVIDER MOCK_GPU_NODE_TYPE CPU_NODE_TYPE HEADROOM_NODE_TYPE
  METAL3_NODE_PROVIDER METAL3_CPU_NODE_TYPE METAL3_HEADROOM_NODE_TYPE
  ARGOCD_CONNECTOR TENANT_POD_CIDR TENANT_SERVICE_CIDR GPU_WORKLOAD_REPO_URL)

set -a
# shellcheck disable=SC1090
. "$env_file"
set +a
for v in "${vars[@]}"; do
  [ -n "${!v:-}" ] || { echo "configure.sh: $v is not set in $env_file" >&2; exit 1; }
done

rm -rf "$out" && mkdir -p "$out"
sed_args=()
# Longest names first: METAL3_CPU_NODE_TYPE contains CPU_NODE_TYPE, and so on.
for v in METAL3_CPU_NODE_TYPE METAL3_HEADROOM_NODE_TYPE METAL3_NODE_PROVIDER \
  MOCK_GPU_NODE_TYPE HEADROOM_NODE_TYPE CPU_NODE_TYPE KUBEVIRT_NODE_PROVIDER \
  ARGOCD_CONNECTOR TENANT_POD_CIDR TENANT_SERVICE_CIDR GPU_WORKLOAD_REPO_URL; do
  sed_args+=(-e "s|${v}|${!v}|g")
done

for f in "$root"/platform/argocd-templates/*.yaml "$root"/platform/stacks/*.yaml \
  "$root"/platform/cluster-templates/*.yaml "$root"/cloud-init/machine-config-templates/*.yaml; do
  sed "${sed_args[@]}" "$f" > "$out/$(basename "$f")"
done

if grep -l -E 'KUBEVIRT_NODE_PROVIDER|MOCK_GPU_NODE_TYPE|CPU_NODE_TYPE|HEADROOM_NODE_TYPE|METAL3_NODE_PROVIDER|METAL3_CPU_NODE_TYPE|METAL3_HEADROOM_NODE_TYPE|ARGOCD_CONNECTOR|TENANT_(POD|SERVICE)_CIDR|GPU_WORKLOAD_REPO_URL' "$out"/*.yaml; then
  echo "configure.sh: placeholders left in the files above" >&2; exit 1
fi
echo "wrote $(ls "$out" | wc -l | tr -d ' ') files to ${out#"$root"/}/"
