#!/bin/bash
# Installs NVIDIA nvml-mock on this host from its container image, after vCluster's
# join has finished, then hands over to the agent and NRI plugin units.
#
# Waits for the join first because the join replaces containerd and its config.toml
# (and nvml-mock edits both), and because ctr only exists once the join installed it.
set -euo pipefail

. /etc/nvml-mock/nvml-mock.env

MARKER=/var/lib/nvml-mock-install/installed
MNT=/run/nvml-mock-image
NS=nvml-mock

log() { echo "nvml-mock-install: $*"; }

# Multi-profile templates ship every profile under /etc/nvml-mock/profiles and pick one
# from the node's vcluster.com/accelerator. The choice is written to active.env and the
# profile files are linked where the agent and tools look for them.
if [ -d /etc/nvml-mock/profiles ]; then
  profile="${NVML_MOCK_PROFILE:-}"
  if [ -z "$profile" ] || [ ! -d "/etc/nvml-mock/profiles/$profile" ]; then
    log "no simulated profile '${profile}', using ${NVML_MOCK_DEFAULT_PROFILE}"
    profile="$NVML_MOCK_DEFAULT_PROFILE"
  fi
  # shellcheck disable=SC1090
  . "/etc/nvml-mock/profiles/$profile/profile.env"
  ln -sfn "profiles/$profile/config.yaml" /etc/nvml-mock/config.yaml
  mkdir -p /etc/nvml-mock/mig
  ln -sfn "../profiles/$profile/mig-profiles.yaml" /etc/nvml-mock/mig/mig-profiles.yaml
  printf 'NVML_MOCK_ACTIVE_PROFILE=%s\nGPU_COUNT=%s\nDRIVER_VERSION=%s\n' \
    "$profile" "${GPU_COUNT:-$DEFAULT_GPU_COUNT}" "$DRIVER_VERSION" > /etc/nvml-mock/active.env
  log "profile $profile, ${GPU_COUNT:-$DEFAULT_GPU_COUNT} GPUs"
fi

if [ -f "$MARKER" ] && [ "$(cat "$MARKER")" = "$NVML_MOCK_IMAGE" ]; then
  log "already installed ($NVML_MOCK_IMAGE)"
  exit 0
fi

# kubelet.conf is the last thing a vCluster worker join writes.
log "waiting for the node to join"
for _ in $(seq 1 720); do
  if [ -f /etc/kubernetes/kubelet.conf ] && [ -S /run/containerd/containerd.sock ] \
    && systemctl is-active --quiet containerd && systemctl is-active --quiet kubelet \
    && command -v ctr >/dev/null 2>&1; then
    break
  fi
  sleep 5
done
[ -f /etc/kubernetes/kubelet.conf ] || { log "node never joined"; exit 1; }

log "pulling $NVML_MOCK_IMAGE"
pull_args=()
[ -d /etc/containerd/certs.d ] && pull_args+=(--hosts-dir /etc/containerd/certs.d)
for attempt in 1 2 3 4 5; do
  ctr -n "$NS" images pull "${pull_args[@]}" "$NVML_MOCK_IMAGE" >/dev/null && break
  log "pull failed (attempt $attempt), retrying"
  sleep $((attempt * 10))
done

mkdir -p "$MNT"
ctr -n "$NS" images unmount --rm "$MNT" >/dev/null 2>&1 || true
ctr -n "$NS" images mount "$NVML_MOCK_IMAGE" "$MNT" >/dev/null
trap 'ctr -n "$NS" images unmount --rm "$MNT" >/dev/null 2>&1 || true' EXIT

# The agent stages from its own image paths, so the files go to the same paths here.
log "installing binaries and libraries"
install -d /usr/local/bin /usr/local/lib /usr/local/libexec/nvml-mock
for f in node-agent nri-plugin nvml-mock-ctl nvidia-smi check-fabric; do
  [ -e "$MNT/usr/local/bin/$f" ] && cp -a "$MNT/usr/local/bin/$f" /usr/local/bin/
done
# The image ships the libraries as regular files (no .so.1 symlinks) plus .h stubs that
# are not ELF; skip the stubs, and ldconfig's "is not a symbolic link" notes are expected.
for f in "$MNT"/usr/local/lib/libnvidia-ml.so* "$MNT"/usr/local/lib/libcuda.so* \
  "$MNT"/usr/local/lib/libmockfs.so* "$MNT"/usr/local/lib/libibmock*.so*; do
  case "$f" in *.h) continue ;; esac
  cp -a "$f" /usr/local/lib/
done
cp -a "$MNT"/usr/local/libexec/nvml-mock/. /usr/local/libexec/nvml-mock/
if [ -d "$MNT/usr/local/nvml-mock-ib" ]; then
  rm -rf /usr/local/nvml-mock-ib
  cp -a "$MNT/usr/local/nvml-mock-ib" /usr/local/nvml-mock-ib
fi
ldconfig 2>&1 | grep -v "is not a symbolic link" || true

mkdir -p "$(dirname "$MARKER")"
echo "$NVML_MOCK_IMAGE" > "$MARKER"
log "installed; starting the agent"
systemctl start --no-block nvml-mock-agent.service
