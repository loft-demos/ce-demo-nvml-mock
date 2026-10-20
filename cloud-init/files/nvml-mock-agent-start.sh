#!/bin/bash
# The nvml-mock DaemonSet's node-agent container, run on the host: the host root is
# "/" instead of a /host mount, health is on loopback, and the profile ConfigMaps are
# files under /etc/nvml-mock.
set -euo pipefail
set -a
. /etc/nvml-mock/nvml-mock.env
[ -f /etc/nvml-mock/active.env ] && . /etc/nvml-mock/active.env
set +a
export NODE_NAME="${NODE_NAME:-$(hostname)}"
mkdir -p /run/nvml-mock /var/lib/nvml-mock /run/nvidia /var/run/cdi \
  /etc/kubernetes/node-feature-discovery/features.d /usr/local/nvml-mock \
  /etc/nvidia-container-runtime /etc/containerd/conf.d
exec /usr/local/bin/node-agent start \
  --config=/etc/nvml-mock/config.yaml \
  --host-root=/ \
  --health-addr=127.0.0.1:9091 \
  --log-level=info \
  --log-format=json \
  --shutdown-timeout=5s \
  --resync-interval=1m \
  --staging-lock-path=/run/nvml-mock/nri-staging.lock \
  --container-runtime=containerd \
  --container-runtime-restart=systemd \
  --container-runtime-config=/etc/containerd/config.toml \
  --container-runtime-config-dir=/etc/containerd/conf.d \
  --container-runtime-systemd-unit=containerd \
  --container-runtime-nri-socket=/var/run/nri/nri.sock \
  --host-fs=/
