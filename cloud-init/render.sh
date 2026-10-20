#!/usr/bin/env bash
# Renders a vCluster Platform MachineConfigTemplate that installs NVIDIA nvml-mock on a
# node from cloud-init, so the node reports simulated GPUs with no nvml-mock DaemonSet.
#
#   ./render.sh                       # b200, 1 GPU per node, nvml-mock 0.5.0
#   PROFILE=h100 GPU_COUNT=8 ./render.sh
#   NAME=hgx-b200 GPU_COUNT=8 ./render.sh   # named for a server type (see docs/metal3-b200.md)
#   PROFILES="b200 a100 gb300" NAME=nvidia-gpu-server ./render.sh
#
# With PROFILES, one template carries every listed profile and each node picks one at
# boot from its vcluster.com/accelerator property (the first profile if that value isn't
# listed), with that profile's own GPU count unless nvml-mock.vcluster.com/gpu-count is
# set. So a NodeType says "accelerator: gb300" and gets a 4-GPU GB300 tray.
#
# Writes machine-config-templates/<NAME>.yaml (default nvml-mock-<profile>). Needs helm, yq (v4),
# curl, gzip and base64. The profile and MIG tables come from the nvml-mock chart
# itself, so they match what the DaemonSet install would mount.
set -euo pipefail

PROFILES="${PROFILES:-}"
PROFILE="${PROFILE:-${PROFILES%% *}}"
PROFILE="${PROFILE:-b200}"
GPU_COUNT="${GPU_COUNT:-1}"
NVML_MOCK_VERSION="${NVML_MOCK_VERSION:-0.5.0}"
NAME="${NAME:-nvml-mock-${PROFILE}}"
CHART_REF="ghcr.io/nvidia/k8s-test-infra/chart/nvml-mock"
IMAGE="ghcr.io/nvidia/nvml-mock:${NVML_MOCK_VERSION}"

here="$(cd "$(dirname "$0")" && pwd)"
out_dir="${here}/machine-config-templates"
out="${out_dir}/${NAME}.yaml"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

fetch_chart() {
  if helm pull "oci://${CHART_REF}" --version "$NVML_MOCK_VERSION" -d "$work" >/dev/null 2>&1; then
    return
  fi
  # Some helm setups send stale ghcr credentials and get a 403; the chart is public,
  # so fetch it with an anonymous token instead.
  local token digest
  token="$(curl -fsS "https://ghcr.io/token?scope=repository:${CHART_REF#ghcr.io/}:pull" | yq -r .token)"
  digest="$(curl -fsS -H "Authorization: Bearer $token" \
    -H "Accept: application/vnd.oci.image.manifest.v1+json" \
    "https://ghcr.io/v2/${CHART_REF#ghcr.io/}/manifests/${NVML_MOCK_VERSION}" \
    | yq -r '.layers[] | select(.mediaType == "application/vnd.cncf.helm.chart.content.v1.tar+gzip") | .digest')"
  curl -fsSL -H "Authorization: Bearer $token" \
    "https://ghcr.io/v2/${CHART_REF#ghcr.io/}/blobs/${digest}" -o "$work/nvml-mock-${NVML_MOCK_VERSION}.tgz"
}

fetch_chart

# Renders one profile into $work/<profile>/: config.yaml, mig-profiles.yaml, and
# profile.env (its driver version and natural GPU count).
render_profile() {
  local p="$1" count_args=() d="$work/$1"
  mkdir -p "$d"
  [ -z "$PROFILES" ] && count_args=(--set "gpu.count=${GPU_COUNT}")
  helm template nvml-mock "$work"/nvml-mock-*.tgz --namespace mokka -f "$here/values.yaml" \
    --set "gpu.profile=${p}" ${count_args[@]+"${count_args[@]}"} > "$d/out.yaml"
  yq -r 'select(.kind == "ConfigMap" and .metadata.name == "nvml-mock-config") | .data["config.yaml"]' \
    "$d/out.yaml" > "$d/config.yaml"
  yq -r 'select(.kind == "ConfigMap" and .metadata.name == "nvml-mock-mig-profiles") | .data["mig-profiles.yaml"]' \
    "$d/out.yaml" > "$d/mig-profiles.yaml"
  local env_q='select(.kind == "DaemonSet") | .spec.template.spec | (.initContainers // []) + .containers | .[].env[]? | select(.name == "NAME") | .value'
  local dv gc
  dv="$(yq -r "${env_q/NAME/DRIVER_VERSION}" "$d/out.yaml" | head -1)"
  gc="$(yq -r "${env_q/NAME/GPU_COUNT}" "$d/out.yaml" | head -1)"
  [ -s "$d/config.yaml" ] && [ -s "$d/mig-profiles.yaml" ] && [ -n "$dv" ] && [ -n "$gc" ] \
    || { echo "render.sh: could not read profile $p from the chart" >&2; exit 1; }
  printf 'DRIVER_VERSION=%s\nDEFAULT_GPU_COUNT=%s\n' "$dv" "$gc" > "$d/profile.env"
}

if [ -n "$PROFILES" ]; then
  for p in $PROFILES; do render_profile "$p"; done
else
  render_profile "$PROFILE"
  cp "$work/$PROFILE/config.yaml" "$work/$PROFILE/mig-profiles.yaml" "$work/"
  driver_version="$(sed -n 's/^DRIVER_VERSION=//p' "$work/$PROFILE/profile.env")"
fi

profile_upper="$(echo "$PROFILE" | tr "[:lower:]" "[:upper:]")"
gzb64() { gzip -9 -n -c "$1" | base64 | tr -d '\n'; }
indent() { sed 's/^/          /' "$1"; }

# Plain files are emitted inside a Go template; a stray "{{" would be evaluated.
if grep -l '{{' "$here"/files/* >/dev/null 2>&1; then
  echo "render.sh: files/ must not contain {{" >&2; exit 1
fi

if [ -n "$PROFILES" ]; then
  summary="profiles ${PROFILES}, picked by vcluster.com/accelerator; each profile's own GPU count"
  display="nvml-mock simulated GPU server - $(echo "$PROFILES" | tr "[:lower:]" "[:upper:]" | sed 's/ /, /g') (cloud-init)"
else
  summary="profile ${PROFILE}, ${GPU_COUNT} GPU per node"
  display="nvml-mock simulated ${profile_upper} (cloud-init)"
fi
mock_env() {
  cat <<ENV
          MOCK_IB=sysfs
          MOCK_IB_PING_FABRIC=0
          MOCK_NVML_CONFIG=/etc/nvml-mock/config.yaml
          MOCK_NVML_OVERRIDES=/var/lib/nvml-mock/driver/config/overrides.yaml
          MOCK_NVML_KMSG=/dev/kmsg
          MOCK_MIG_PROFILES_CONFIG=/etc/nvml-mock/mig/mig-profiles.yaml
          MOCK_IB_PING_SOCKET=/var/lib/nvml-mock/run/mock-ib.sock
          MOCK_IB_ROOT=/var/lib/nvml-mock/ib
          MOCK_PCI_ROOT=/var/lib/nvml-mock
ENV
}

mkdir -p "$out_dir"
{
cat <<YAML
# Generated by cloud-init/render.sh (${summary};
# nvml-mock ${NVML_MOCK_VERSION}). Edit files/ and re-run instead of editing this.
#
# Attach to a node with the property
#   vcluster.com/user-data-template-config: ${NAME}
# on a tenant cluster's Auto Nodes pool (properties) or on a NodeType. Optional per-node
# GPU count override: property nvml-mock.vcluster.com/gpu-count.
apiVersion: management.loft.sh/v1
kind: MachineConfigTemplate
metadata:
  name: ${NAME}
  labels:
    app.kubernetes.io/part-of: ce-demo-nvml-mock
spec:
  displayName: "${display}"
  owner:
    team: loft-admins
  cloudInitTemplate: |
    #cloud-config
    write_files:
      - path: /etc/nvml-mock/nvml-mock.env
        permissions: "0644"
        content: |
          NVML_MOCK_IMAGE=${IMAGE}
YAML
if [ -n "$PROFILES" ]; then
  default_profile="${PROFILES%% *}"
  cat <<YAML
          NVML_MOCK_PROFILE={{ index .Values.Properties "vcluster.com/accelerator" | default "${default_profile}" }}
          NVML_MOCK_DEFAULT_PROFILE=${default_profile}
          GPU_COUNT={{ index .Values.Properties "nvml-mock.vcluster.com/gpu-count" | default "" }}
YAML
  mock_env
  for p in $PROFILES; do
    printf '      - path: /etc/nvml-mock/profiles/%s/profile.env\n        permissions: "0644"\n        content: |\n' "$p"
    indent "$work/$p/profile.env"
    for f in config.yaml mig-profiles.yaml; do
      printf '      - path: /etc/nvml-mock/profiles/%s/%s\n        permissions: "0644"\n        encoding: gzip+base64\n        content: %s\n' "$p" "$f" "$(gzb64 "$work/$p/$f")"
    done
  done
else
  cat <<YAML
          GPU_COUNT={{ index .Values.Properties "nvml-mock.vcluster.com/gpu-count" | default "${GPU_COUNT}" }}
          DRIVER_VERSION=${driver_version}
YAML
  mock_env
  cat <<YAML
      - path: /etc/nvml-mock/config.yaml
        permissions: "0644"
        encoding: gzip+base64
        content: $(gzb64 "$work/config.yaml")
      - path: /etc/nvml-mock/mig/mig-profiles.yaml
        permissions: "0644"
        encoding: gzip+base64
        content: $(gzb64 "$work/mig-profiles.yaml")
YAML
fi
for f in nvml-mock-install.sh nvml-mock-agent-start.sh nvml-mock-nri-start.sh; do
  printf '      - path: /usr/local/sbin/%s\n        permissions: "0755"\n        content: |\n' "$f"
  indent "$here/files/$f"
done
printf '      - path: /usr/local/sbin/nvml-mock-ctl\n        permissions: "0755"\n        content: |\n'
indent "$here/files/nvml-mock-tool.sh"
for f in nvml-mock-install.service nvml-mock-agent.service nvml-mock-nri.service; do
  printf '      - path: /etc/systemd/system/%s\n        permissions: "0644"\n        content: |\n' "$f"
  indent "$here/files/$f"
done
cat <<'YAML'
    # Runs before the Platform's join command (appended after these). The install
    # unit waits for the join to finish, so it must not block here.
    runcmd:
      - [systemctl, daemon-reload]
      - [systemctl, enable, nvml-mock-install.service, nvml-mock-agent.service, nvml-mock-nri.service]
      - [systemctl, start, --no-block, nvml-mock-install.service]
YAML
} > "$out"

echo "wrote ${out#"$here"/}"
