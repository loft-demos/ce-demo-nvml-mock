#!/bin/bash
# The nvml-mock DaemonSet's NRI plugin container, run on the host. Waits for the
# agent to report the mock driver staged, as the pod's startup probe did.
set -euo pipefail
set -a
. /etc/nvml-mock/nvml-mock.env
[ -f /etc/nvml-mock/active.env ] && . /etc/nvml-mock/active.env
set +a
export NODE_NAME="${NODE_NAME:-$(hostname)}"
for _ in $(seq 1 300); do
  curl -fsS -o /dev/null http://127.0.0.1:9091/stagedz && break
  sleep 2
done
exec /usr/local/bin/nri-plugin \
  --socket-path=/var/run/nri/nri.sock \
  --plugin-name=nvml-mock \
  --plugin-index=10 \
  --overlay-host-path=/var/lib/nvml-mock \
  --overlay-mount-path=/opt/nvml-mock \
  --device-host-path=/var/lib/nvml-mock/driver/dev \
  --opt-out-annotation=nvml-mock.nvidia.com/inject \
  --device-annotation=nvml-mock.nvidia.com/devices \
  --device-injection-mode=raw \
  --cdi-spec-host-path=/var/run/cdi/nvml-mock-nri.yaml \
  --imex-channel-annotation=nvml-mock.nvidia.com/imex-channels \
  --imex-channel-host-path=/var/lib/nvml-mock/driver/dev/nvidia-caps-imex-channels \
  --infiniband-annotation=nvml-mock.nvidia.com/infiniband \
  --excluded-namespaces=kube-system \
  --node-name="$NODE_NAME" \
  --health-addr=127.0.0.1:18080 \
  --agent-staged-url=http://127.0.0.1:9091/stagedz \
  --staging-lock-path=/run/nvml-mock/nri-staging.lock \
  --log-level=info \
  --log-format=json
