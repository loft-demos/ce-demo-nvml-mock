# Runbook: simulated GPU tenant clusters

How to stand up, verify and demo the templates in this repo, and what the first runs
showed. Times and results are from a vCluster Platform 4.13.0-alpha.19 lab (KubeVirt VMs on
Metal3-provisioned hosts), October 2026.

## The pieces

| File | Object | What |
| --- | --- | --- |
| `platform/kubevirt-provider/mock-gpu-host-pool-snippet.yaml` | provider cluster static pool | One host labeled `demo.vcluster.com/mock-gpu-host=true` for the simulated-GPU VMs |
| `platform/metal3/node-type-snippet.yaml` | Metal3 NodeType `rack-b-b200-xlarge` | A simulated 8 x B200 server: NetBox device type `hgx-b200`, cloud-init properties, `nvidia.com/gpu: "8"` |
| `platform/kubevirt-provider/node-type-snippet.yaml` | NodeType `kvm-mock-gpu` | 2 CPU (1 requested), 3 GiB, 30 GiB disk, max 4, pinned to the mock host, **declares** `nvidia.com/gpu: "1"` |
| `platform/argocd-templates/nvml-mock-driver.yaml` | `nvml-mock-driver` | NVIDIA nvml-mock as a DaemonSet on the GPU pool |
| `platform/argocd-templates/nvml-mock-gpu-operator.yaml` | `nvml-mock-gpu-operator` | GPU Operator v26.3.3 with driver and toolkit off (NVIDIA's k8s-test-infra recipe); `standaloneDCGM` for NVSentinel |
| `platform/argocd-templates/nvml-mock-nvsentinel.yaml` | `nvml-mock-nvsentinel` | NVSentinel v1.21.0, full pipeline (MongoDB, fault-quarantine, node-drainer) |
| `platform/argocd-templates/nvml-mock-gpu-workload.yaml` | `nvml-mock-gpu-workload` | `charts/gpu-workload`: N pods requesting one GPU each |
| `platform/argocd-templates/nvml-mock-stack-gate.yaml`, `nvml-mock-cert-manager.yaml` | | The Stack's readiness gate, and cert-manager for NVSentinel |
| `platform/stacks/*.yaml` | 4 StackTemplates | Plain, NVSentinel, NVSentinel with dynamic GPUs, and preinstalled (cloud-init) |
| `platform/cluster-templates/*.yaml` | 5 VirtualClusterTemplates | One per Stack, plus a Metal3 one for the preinstalled Stack |
| `cloud-init/machine-config-templates/nvml-mock-b200.yaml` | MachineConfigTemplate | Installs nvml-mock on the host from cloud-init ([cloud-init.md](cloud-init.md)) |
| `dashboards/gen_tenant_gpus.py` | Grafana dashboard | Tenant Cluster GPUs, keyed by node |
| `demo/demo.sh` | | On-camera one-liners |

## What you need

| | Plain | With NVSentinel |
| --- | --- | --- |
| vCluster Platform | 4.12+ with private nodes and the Argo CD integration (Stacks). 4.13 for Tenants | same |
| Node runtime | containerd 2.x under systemd, as vCluster's join installs it | same |
| GPU nodes | 1 CPU, 3 GiB, 30 GiB disk each (one simulated GPU per node) | same, plus ~770 MiB of NVSentinel requests per node |
| CPU service node | none | 2 CPU, 4 GiB, and a StorageClass for a 2 GiB MongoDB volume (`local-path` works) |
| Registries | `ghcr.io/nvidia/nvml-mock`, `nvcr.io`, `helm.ngc.nvidia.com/nvidia` | plus `ghcr.io/nvidia/nvsentinel`, `docker.io/percona/*`, `quay.io/jetstack` |
| Optional | Fleet Observability, for the dashboard | same |

No real GPU, IOMMU, vfio or device operator anywhere.

## Fastest path: an existing tenant cluster

No KubeVirt needed. Any private-node tenant cluster with the Argo CD integration works:

1. `scripts/configure.sh env.local`, then apply `out/nvml-mock-driver.yaml`,
   `out/nvml-mock-gpu-operator.yaml`, `out/nvml-mock-stack-gate.yaml` and `out/nvml-mock-gpu.yaml`.
2. Label the nodes that should get a simulated GPU `workload.example.com/pool=gpu-compute`.
3. Add the `nvml-mock-gpu` Stack to the cluster (cluster template `deploy.stacks`, or the UI)
   with `minGPUs` set to the number of labeled nodes.

Each labeled node reports `nvidia.com/gpu: 1` a few minutes after nvml-mock starts.

## Full path: KubeVirt VMs on a mock "4-GPU server"

1. **Provider cluster.** Add the mock host pool to the KubeVirt provider cluster (or label an
   existing provider node `demo.vcluster.com/mock-gpu-host=true`), and the `kvm-mock-gpu`
   NodeType to the KubeVirt NodeProvider. Give every other NodeType the `DoesNotExist`
   affinity from the snippet so they leave the mock host's slots alone. After changing the
   provider cluster's template, **sync its template** (UI **Sync Template**), or the new pool
   never renders.
2. **Templates.** `cp env.example env.local`, fill it in, `scripts/configure.sh env.local`,
   `kubectl apply -f out/` against the management API.
3. **Project.** Add the cluster templates to a project's `allowedTemplates` (or use a project
   that allows all templates).
4. **Create a tenant cluster** from one of the templates. The mock host fits four GPU VMs in
   total across all tenant clusters.

The plain template has no CPU service VM: the GPU nodes carry the `gpu-compute` pool label
but no `nvidia.com/gpu` taint, so CoreDNS and the GPU Operator controllers run on them.

## Verify

In the tenant cluster:

```sh
kubectl get nodes -o custom-columns=NAME:.metadata.name,GPU:.status.allocatable.nvidia\\.com/gpu,PRODUCT:.metadata.labels.nvidia\\.com/gpu\\.product
kubectl -n gpu-operator get pods
kubectl -n gpu-operator exec ds/nvidia-device-plugin-daemonset -- nvidia-smi -L
```

Expect `nvidia.com/gpu: 1` on every GPU node (`NVIDIA-B200` with the default profile), the
Stack Healthy once all of them are advertised, and DCGM series (`DCGM_FI_DEV_GPU_UTIL`
between 15 and 75%) on the dashboard.

Lab timings: four VMs joined about 3 minutes after their disk imports; the Stack was Healthy
about 4 minutes after nvml-mock started.

## What the first runs showed

- **containerd restart is fine.** The node agent writes `/etc/containerd/conf.d/50-mokka.toml`,
  restarts containerd through systemd and sets up the `nvidia` handler; NRI connects
  (containerd 2.2.3) and nodes stay Ready.
- **DCGM fields.** dcgm-exporter skips fields the mock doesn't implement without crashing. Of
  the 24 it serves, these move: GPU utilization, memory copy utilization, temperature, power,
  graphics engine, tensor and DRAM activity, PCIe rx/tx. Static or zero: framebuffer used,
  memory temperature, SM and memory clocks, total energy, encoder/decoder, NVLink bandwidth.
  The dashboard uses only the first group plus framebuffer capacity and error counters.
- **Same UUID on every node.** Profiles hard-code GPU UUIDs, so every 1-GPU node reports
  `GPU-b2000000-0000-0000-0000-000000000000`. Key GPUs by `Hostname`, never `UUID`.
- **Counters gain `_total`** in Prometheus (`DCGM_EXP_XID_ERRORS_COUNT_total`).
- **Control plane cluster views show nothing for these tenants on the provider cluster.** The
  tenant's control plane runs on its control plane cluster; only its VMs run on the provider
  cluster. Use the fleet view.

## Variant: NVSentinel fault injection

Template `nvml-mock-kubevirt-nvsentinel`, Stack `nvml-mock-gpu-nvsentinel`: the GPU VMs plus
one CPU service VM, with standalone DCGM (`nvidia-dcgm` on 5555) and NVSentinel's full
pipeline, following NVIDIA's k8s-test-infra NVSentinel guide.

Placement: health monitor, metadata collector and platform connectors on the GPU nodes;
MongoDB, its operator, fault-quarantine, node-drainer and the labeler on the CPU service VM,
so a GPU drain never evicts the pipeline doing it.

Lab result: Stack Healthy about 14 minutes after create. A thermal fault cordoned its node in
**12 seconds** and the drained pod was running elsewhere in under a minute; cooling the GPU
uncordoned the node in **21 seconds**, no manual step.

### The demo beat

Put something on the GPUs, leaving one free so the evicted pod has somewhere to go:

```sh
demo/demo.sh workload 3
demo/demo.sh pick              # a node running a workload pod
demo/demo.sh heat <node>       # nvml-mock-ctl temp --gpu 0 142
demo/demo.sh watch <node>      # cordon, GpuThermalMarginWatch, pods moving
demo/demo.sh cool <node>       # nvml-mock-ctl reset --gpu 0
```

What happens: `GpuThermalMarginWatch=True`
(`GPU_TEMP_HW_SLOWDOWN_VIOLATION ... thermal margin -5°C below HW slowdown`), the node cordons,
its pod is evicted and runs on the free GPU node. After `cool`, NVSentinel uncordons it.

On the dashboard the GPU's temperature jumps from about 60 to **95 °C** (DCGM's reported
temperature tops out there; NVSentinel acts on the thermal-margin field, which the 142 °C pin
drives negative) and drops back after the reset, with up to a minute of scrape delay.

See [faults.md](faults.md) for the other faults nvml-mock can inject.

### Gotchas

- **Stack tasks can show Failed while they are still starting.** cert-manager (waiting for its
  node) and NVSentinel (Percona CRDs without status yet) go Failed/Degraded and then recover on
  their own. Retry a task (UI, or the `platform.vcluster.com/stack-retry` annotation) only if it
  stays Failed after its pods are Running.
- **NVSentinel's first minutes are noisy and fine.** platform-connectors, fault-quarantine and
  node-drainer crash-loop on `ENOTFOUND mongodb-rs0...` until MongoDB is Ready.
- **Every watch must be healthy before you inject.** `kubectl get node <gpu node> -o
  jsonpath='{range .status.conditions[*]}{.type}={.status}{"\n"}{end}'` should show
  `GpuThermalMarginWatch=False` and `GpuNvlinkWatch=False`. A True NVLink watch at idle means
  the BER suppression didn't apply, and that node will never uncordon after a fault.

## Variant: replace a failed GPU from spare capacity

The NVSentinel template with `spareGPUs: 1`. In the lab, two tenant clusters shared the mock
"4-GPU server": tenant A with 2 GPU VMs and 1 spare, tenant B with 1, one slot in reserve.
With `demo/demo.sh workload 2` on tenant A (one pod per static GPU, so a drained pod has nowhere
to go but a spare):

| t | |
| --- | --- |
| 0 s | `nvml-mock-ctl temp --gpu 0 142` on a static GPU node |
| +13 s | NVSentinel cordons and drains it; the pod goes Pending; **Auto Nodes claims the reserve slot** (`gpu-spare` pool) |
| +111 s | Spare VM joins |
| +306 s | Spare advertises its GPU; **the workload runs on it** |
| +306 s | `nvml-mock-ctl reset --gpu 0` |
| +328 s | NVSentinel uncordons the healed node |
| +393 s | **Consolidation moves the workload back** |
| +437 s | **Spare deleted; slot returned to the reserve** |

How it works:

- `kvm-mock-gpu` **declares** `nvidia.com/gpu: "1"` in its `resources`, so vCluster copies the
  GPU into the Karpenter instance type and a Pending GPU pod can launch it.
- **`gpu-spare`** is a dynamic pool, separate from the static GPU pool so a cordoned static node
  doesn't use up its `limits`. Tainted `nvidia.com/gpu:NoSchedule` so only GPU pods trigger it.
  `WhenEmptyOrUnderutilized` with `consolidateAfter: 1m` gives the slot back after recovery.
- **`scheduler-headroom`** is a dynamic pool on an always-available type with
  `limits: {cpu: "0"}`. It never launches anything. When the spare takes the mock host's last
  slot, the mock GPU NodeType goes Pending, no dynamic pool has a launchable instance type, and
  Karpenter refuses to build its scheduler ("filtered out all instance types for all node
  pools"), so consolidation can't even simulate deleting the spare. A fleet with free
  capacity in some pool doesn't need this.
- **Dynamic pools select the full NodeType name** (`<provider>.kvm-mock-gpu`). The short alias
  launches fine but breaks consolidation: vCluster's init-node controller copies the selected
  `vcluster.com/node-type` value into `node.kubernetes.io/instance-type`, Karpenter names
  instance types with the full name, and the node is "Unconsolidatable: Instance Type
  "kvm-mock-gpu" not found". A vCluster bug, worked around here.

If a spare never goes away, read Karpenter in the tenant's control plane pod rather than the
events (Karpenter de-duplicates them):
`kubectl -n <tenant namespace> logs <tenant>-0 | grep -iE "disruption|consolidat"`.

## Variant: every GPU node dynamic, failed nodes retired

Template `nvml-mock-kubevirt-dynamic`, Stack `nvml-mock-gpu-nvsentinel-dynamic`: no static GPU
pool. One dynamic `gpu` pool (limit `gpuVMCount + spareGPUs`, tainted, full NodeType name)
supplies every GPU node, next to the static CPU service VM and `scheduler-headroom`.

- **The workload brings up the GPUs.** The Stack's first task deploys `gpu-workload` with
  `gpuVMCount` pods requesting one GPU each. They go Pending, Auto Nodes launches a GPU VM per
  pod, and the rest of the Stack (which installs with no GPU node present) lands on them.
  Bring-up took about 12 minutes.
- **A failed node is retired, not nursed back.** Karpenter's disruption checks don't look at
  cordons, so the drained node (empty but for DaemonSets, and dynamic) is consolidated away
  about a minute after its drain while the evicted pod's replacement comes up.
- **The workload belongs to Argo CD** here. `demo.sh workload` and `reset` leave it alone;
  deleting its pods scales GPU nodes to zero and takes about 5 minutes to come back.

| t | |
| --- | --- |
| 0 s | `nvml-mock-ctl temp --gpu 0 142` on a GPU node |
| +14 s | NVSentinel cordons and drains it; the pod goes Pending |
| +25 s | Auto Nodes claims a slot for a replacement |
| +122 s | Replacement joins |
| +166 s | Karpenter starts retiring the failed node |
| +220 s | Failed node gone, slot released |
| +318 s | Workload running on the replacement |

With real GPU passthrough, retiring the VM frees the physical GPU for reuse, so keeping a
failed GPU out of the pool is a device-health concern below Auto Nodes. With nvml-mock the
"failed" GPU was never real, so reuse is harmless.

## Variant: nvml-mock from cloud-init

Templates `nvml-mock-kubevirt-cloud-init` (KubeVirt VMs) and `nvml-mock-metal3-cloud-init`
(whole Metal3 servers, 8 GPUs each), Stack `nvml-mock-gpu-preinstalled`: nvml-mock is part of
the machine instead of the Stack. See [cloud-init.md](cloud-init.md) and
[metal3-b200.md](metal3-b200.md).

## What this does not cover: GPU passthrough

The simulated GPU lives **inside the guest**. Each mock VM is an ordinary KubeVirt VM with no
`hostDevices` or `gpus`. None of the passthrough path is exercised:

- the **vCluster device operator** (binding GPUs to vfio-pci, `permittedHostDevices`, IOMMU
  kernel arguments, hugepages and NUMA, NVLink partitioning);
- **IOMMU groups**, `/dev/vfio`, and QEMU's VFIO DMA mapping;
- the **GPU reset** vfio performs when a VM is torn down;
- a GPU NodeType's capacity tracking the host's real GPUs (`kvm-mock-gpu` *declares* its GPU).

nvml-mock's [PCIe topology mocking](https://nvidia.github.io/k8s-test-infra/helm-chart/#pcie-topology-mocking)
can't fake it: it is a fake sysfs tree served through an LD_PRELOAD shim or bind mounts, for
DRA drivers, device plugins and GPU feature discovery. Passthrough needs a kernel PCI device,
an IOMMU group and `/dev/vfio`, which a directory can't provide. To exercise passthrough, use a
real GPU, or (untested) QEMU test devices behind a vIOMMU on the KubeVirt host.

## Gotchas

- **Template changes don't reach a running instance** until it syncs its template (UI **Sync
  Template**).
- **A static pool's host must be visible to the claiming cluster.** NodeType capacity ignores
  tenant assignment, so a selector that spans a host assigned to a tenant can stall the claim
  forever. Narrow the selector or unassign the host.
- **Argo CD OCI charts:** `repoURL` must include the chart name
  (`oci://ghcr.io/nvidia/k8s-test-infra/chart/nvml-mock`); without it ghcr answers 403.
- **nvml-mock's `gpu.count` must be an integer**; the chart schema rejects `"1"`.
- **NVSentinel needs a non-GPU node for its pipeline**, or the drainer can evict itself; extend
  `node-drainer.systemNamespaces` to whatever must survive a drain.
- **Tenant CIDRs must not overlap the provider cluster's.** With KubeVirt bridge binding, node
  IPs are provider pod IPs.
