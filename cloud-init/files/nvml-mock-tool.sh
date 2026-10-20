#!/bin/bash
# Runs an nvml-mock tool with the environment the DaemonSet gave `kubectl exec`, so
# it resolves the same profile, overrides and mock trees a workload sees.
# Installed as /usr/local/sbin/nvml-mock-ctl (ahead of /usr/local/bin in PATH).
set -euo pipefail
set -a
. /etc/nvml-mock/nvml-mock.env
[ -f /etc/nvml-mock/active.env ] && . /etc/nvml-mock/active.env
set +a
export LD_PRELOAD=/usr/local/lib/libibmockumad.so.1:/usr/local/lib/libibmockverbs.so.1:/usr/local/lib/libibmocksys.so.1:/usr/local/lib/libmockfs.so.1
exec "/usr/local/bin/$(basename "$0")" "$@"
