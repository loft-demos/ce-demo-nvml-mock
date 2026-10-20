#!/usr/bin/env bash
# Helper for recording the simulated-GPU + NVSentinel demo (see docs/video-script.md).
# Every command runs against the tenant cluster in $CTX (default: the current context).
# Works with both installs: the nvml-mock DaemonSet (kubectl exec) and nvml-mock from
# cloud-init (kubectl debug node/..., chroot into the host).
#
#   ./demo.sh status           nodes, GPUs, cordons, NVSentinel watches
#   ./demo.sh workload [N]     GPU workload, N replicas (default: one per static GPU node,
#                              so a drained pod needs a spare GPU node)
#   ./demo.sh smi [NODE]       nvidia-smi on a node (default: first GPU node)
#   ./demo.sh pick             a GPU node that is running a workload pod
#   ./demo.sh heat NODE        pin GPU $GPU (default 0) on NODE to 142 C (thermal fault)
#   ./demo.sh watch NODE       follow the cordon, condition and pod moves (Ctrl-C to stop)
#   ./demo.sh cool NODE        clear the fault on GPU $GPU; NVSentinel uncordons on its own
#   ./demo.sh reset            cool every GPU (all) and delete the workload (pre-take cleanup)
#   ./demo.sh timer            large elapsed-time clock since the last 'heat' (for recording)
#
# 'heat' starts an on-screen clock: 'watch' and 'timer' show FAULT +mm:ss, so a sped-up
# recording still shows how long each step really took.
set -euo pipefail

CTX="${CTX:-}"
HOT_C="${HOT_C:-142}"
GPU="${GPU:-0}"   # which GPU on the node, for multi-GPU servers
T0_FILE="${TMPDIR:-/tmp}/mock-gpu-demo.fault-start"
elapsed() { [[ -f "$T0_FILE" ]] || { echo "--:--"; return; }; local d=$(( $(date +%s) - $(cat "$T0_FILE") )); printf '%02d:%02d' $((d/60)) $((d%60)); }
K=(kubectl); [[ -n "$CTX" ]] && K+=(--context "$CTX")

gpu_nodes() { "${K[@]}" get nodes -l workload.example.com/pool=gpu-compute -o name | sed 's|node/||'; }
mock_pod() { "${K[@]}" -n mokka get pod -o name --field-selector "spec.nodeName=$1" 2>/dev/null || true; }
# nvml-mock-ctl on NODE: in its DaemonSet pod, or on the host when cloud-init installed it.
mockctl() {
  local node="$1"; shift
  local pod; pod="$(mock_pod "$node")"
  if [[ -n "$pod" ]]; then
    "${K[@]}" -n mokka exec "$pod" -c node-agent -- nvml-mock-ctl "$@"
  else
    # Not -i: a pod this short finishes before the attach and its output is lost.
    local dbg
    dbg=$("${K[@]}" debug "node/$node" --profile=sysadmin --image=busybox:1.36 -- chroot /host /usr/local/sbin/nvml-mock-ctl "$@" 2>&1 | grep -o 'node-debugger-[a-z0-9.-]*' | head -1)
    [[ -n "$dbg" ]] || { echo "kubectl debug failed on $node" >&2; return 1; }
    "${K[@]}" wait -n default "pod/$dbg" --for=jsonpath='{.status.phase}'=Succeeded --timeout=180s >/dev/null || true
    "${K[@]}" logs -n default "$dbg"
    "${K[@]}" delete -n default "pod/$dbg" --wait=false >/dev/null 2>&1 || true
  fi
}
# True when the workload is the Stack's (dynamic-GPU template): Argo CD owns it then.
argo_owned() { "${K[@]}" get deployment gpu-workload -n default -o jsonpath='{.metadata.annotations.argocd\.argoproj\.io/tracking-id}{.metadata.labels.app\.kubernetes\.io/instance}' 2>/dev/null | grep -q .; }
need_node() { [[ -n "${1:-}" ]] || { echo "usage: $0 $2 NODE   (try: $0 pick)" >&2; exit 1; }; }

case "${1:-status}" in
  status)
    "${K[@]}" get nodes -o custom-columns='NODE:.metadata.name,POOL:.metadata.labels.workload\.example\.com/pool,SPARE:.metadata.labels.demo\.vcluster\.com/spare-gpu,GPU:.status.allocatable.nvidia\.com/gpu,MODEL:.metadata.labels.nvidia\.com/gpu\.product,CORDONED:.spec.unschedulable'
    echo
    for n in $(gpu_nodes); do
      printf '%-24s ' "$n"
      "${K[@]}" get node "$n" -o jsonpath='{range .status.conditions[?(@.type=="GpuThermalMarginWatch")]}ThermalMargin={.status} {end}{range .status.conditions[?(@.type=="GpuNvlinkWatch")]}Nvlink={.status}{end}{"\n"}'
    done
    echo
    "${K[@]}" get pods -n default -l app=gpu-workload -o wide 2>/dev/null || true
    ;;
  workload)
    if argo_owned; then echo "gpu-workload is managed by the cluster's Stack (Argo CD); leaving it as is."; "${K[@]}" get pods -n default -l app=gpu-workload -o wide; exit 0; fi
    replicas="${2:-$("${K[@]}" get nodes -l 'workload.example.com/pool=gpu-compute,!demo.vcluster.com/spare-gpu' -o name | wc -l | tr -d ' ')}"
    # Tolerates the nvidia.com/gpu taint on spare GPU nodes, so a drained pod can land on one.
    "${K[@]}" apply -n default -f - <<YAML
apiVersion: apps/v1
kind: Deployment
metadata:
  name: gpu-workload
spec:
  replicas: ${replicas}
  selector:
    matchLabels: {app: gpu-workload}
  template:
    metadata:
      labels: {app: gpu-workload}
    spec:
      terminationGracePeriodSeconds: 5
      tolerations:
        - {key: nvidia.com/gpu, operator: Exists, effect: NoSchedule}
      containers:
        - name: work
          image: busybox:1.36
          command: [sleep, infinity]
          resources:
            limits: {nvidia.com/gpu: 1}
YAML
    "${K[@]}" rollout status deployment gpu-workload -n default --timeout=180s
    "${K[@]}" get pods -n default -l app=gpu-workload -o wide
    ;;
  smi)
    node="${2:-$(gpu_nodes | head -1)}"
    dp=$("${K[@]}" get pods -n gpu-operator -l app=nvidia-device-plugin-daemonset -o name --field-selector "spec.nodeName=$node")
    "${K[@]}" exec -n gpu-operator "$dp" -c nvidia-device-plugin -- nvidia-smi
    ;;
  pick)
    "${K[@]}" get pods -n default -l app=gpu-workload --field-selector status.phase=Running -o jsonpath='{.items[0].spec.nodeName}{"\n"}'
    ;;
  heat)
    need_node "${2:-}" heat
    mockctl "$2" temp --gpu "$GPU" "$HOT_C"
    date +%s > "$T0_FILE"
    ;;
  watch)
    need_node "${2:-}" watch
    while true; do
      clear
      printf '\033[1;7m  FAULT +%s  \033[0m   %s\n' "$(elapsed)" "$(date +%H:%M:%S)"
      "${K[@]}" get node "$2" -o jsonpath='Node {.metadata.name}  cordoned={.spec.unschedulable}{"\n"}{range .status.conditions[?(@.type=="GpuThermalMarginWatch")]}GpuThermalMarginWatch={.status}  {.message}{end}{"\n"}' | cut -c1-160
      echo
      "${K[@]}" get pods -n default -l app=gpu-workload -o custom-columns='POD:.metadata.name,STATUS:.status.phase,NODE:.spec.nodeName'
      echo
      "${K[@]}" get nodes -l workload.example.com/pool=gpu-compute -o custom-columns='GPU NODE:.metadata.name,SPARE:.metadata.labels.demo\.vcluster\.com/spare-gpu,READY:.status.conditions[?(@.type=="Ready")].status,GPU:.status.allocatable.nvidia\.com/gpu,CORDONED:.spec.unschedulable'
      sleep 2
    done
    ;;
  cool)
    need_node "${2:-}" cool
    mockctl "$2" reset --gpu "$GPU"
    ;;
  timer)
    # Big, standalone clock for a corner terminal; Ctrl-C to stop.
    while true; do printf '\r\033[1;7m  FAULT +%s  \033[0m ' "$(elapsed)"; sleep 1; done
    ;;
  reset)
    for n in $(gpu_nodes); do
      mockctl "$n" reset --gpu all >/dev/null && echo "cooled $n"
    done
    if argo_owned; then echo "gpu-workload is managed by the cluster's Stack; kept"; else
      "${K[@]}" delete deployment gpu-workload -n default --ignore-not-found
    fi
    ;;
  *)
    sed -n '2,17p' "$0"; exit 1
    ;;
esac
