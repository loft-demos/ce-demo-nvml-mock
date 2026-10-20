# ce-demo-nvml-mock

GPU tenant clusters on **simulated** GPUs, for vCluster Platform demos with no GPU hardware.

NVIDIA's [nvml-mock](https://github.com/NVIDIA/k8s-test-infra) makes an ordinary node report
GPUs to Kubernetes, `nvidia-smi` and DCGM. Everything around it is real: vCluster Platform
private nodes and Auto Nodes, KubeVirt, the NVIDIA GPU Operator, DCGM, NVSentinel and Fleet
Observability. Nothing runs CUDA. **Always present the GPUs as simulated.**

What you can show with it:

- A mock "4-GPU server" carved into 1-GPU KubeVirt VMs shared by several tenant clusters, each
  with its own GPU Operator Stack and a per-tenant GPU dashboard.
- **A GPU fault handled with no human step:** NVSentinel quarantines the node (12 to 14 s),
  Auto Nodes launches a replacement from spare capacity, the workload moves, and the failed node
  is retired or healed and the spare given back (about 5 to 7 minutes in total).
- Simulated GPUs as part of the **machine** (cloud-init), so the tenant cluster sees a node with a
  "driver" already installed, on KubeVirt VMs or whole Metal3 servers (8 GPUs each).

## Contents

| Path | What |
| --- | --- |
| `platform/kubevirt-provider/` | Snippets for the KubeVirt provider: the mock GPU host pool and the `kvm-mock-gpu` NodeType |
| `platform/metal3/` | Metal3 NodeType snippet for a simulated HGX B200 server (cloud-init properties, 8 GPUs) |
| `platform/argocd-templates/` | Argo CD application templates (nvml-mock, GPU Operator mock values, NVSentinel, cert-manager, GPU workload, Stack gate) |
| `platform/stacks/` | StackTemplates: `nvml-mock-gpu`, `nvml-mock-gpu-nvsentinel`, `nvml-mock-gpu-nvsentinel-dynamic`, `nvml-mock-gpu-preinstalled` |
| `platform/cluster-templates/` | VirtualClusterTemplates, one per Stack (below) |
| `cloud-init/` | Generator and rendered MachineConfigTemplates that install nvml-mock from cloud-init: `nvml-mock-b200` (1 GPU), `hgx-b200` (8), `nvidia-gpu-server` (B200, A100 or GB300, picked by `vcluster.com/accelerator`) |
| `charts/gpu-workload/` | N pods requesting one GPU each |
| `dashboards/` | Tenant Cluster GPUs Grafana dashboard (Fleet Observability) |
| `demo/demo.sh` | On-camera one-liners: `status`, `workload`, `smi`, `pick`, `heat`, `watch`, `cool`, `timer`, `reset` |
| `docs/` | [Runbook](docs/runbook.md), [cloud-init](docs/cloud-init.md), [Metal3 B200 server](docs/metal3-b200.md), [faults](docs/faults.md), [video script](docs/video-script.md) |

## Templates

| Template | GPU nodes | Shows |
| --- | --- | --- |
| `nvml-mock-kubevirt` | Static, `gpuVMCount` | Simulated GPUs, GPU Operator, dashboards |
| `nvml-mock-kubevirt-nvsentinel` | Static, plus optional dynamic spares | NVSentinel quarantine and drain; replacement from spare capacity, then given back |
| `nvml-mock-kubevirt-dynamic` | All dynamic, launched by the workload | Replacement on demand, failed nodes retired by consolidation |
| `nvml-mock-kubevirt-cloud-init` | Static, nvml-mock installed by cloud-init | The GPU as part of the machine; the Stack only installs the GPU Operator |
| `nvml-mock-metal3-nvsentinel-dynamic` | Dynamic Metal3 B200 servers launched by the workload, plus a spare | NVSentinel quarantines a failed server, a spare is provisioned through Metal3, the failed one is deprovisioned |
| `nvml-mock-metal3-cloud-init` | Static Metal3 hosts selected by `vcluster.com/accelerator` | Whole bare metal servers presented as 8 x B200; all mock config is on the NodeType ([metal3-b200.md](docs/metal3-b200.md)) |

## Quick start

```sh
cp env.example env.local        # your provider, NodeTypes, Argo CD connector, CIDRs
scripts/configure.sh env.local  # fills the placeholders into out/
kubectl apply -f out/           # against the vCluster Platform management API
```

Then add the provider snippets, allow the templates in a project, and create a tenant cluster.
[docs/runbook.md](docs/runbook.md) has the full steps, a path that needs no KubeVirt at all (any
private-node tenant cluster), what to expect, and the gotchas.

## Requirements

vCluster Platform 4.12+ with private nodes and the Argo CD integration (4.13 for Tenants),
containerd 2.x on the nodes (as vCluster's join installs it), and pulls from `ghcr.io`,
`nvcr.io` and `helm.ngc.nvidia.com`. No GPU, IOMMU or vfio. This does **not** exercise GPU
passthrough; see the runbook.

## Status

Built and verified in October 2026 on vCluster Platform 4.13.0-alpha.19 (KubeVirt VMs on
Metal3-provisioned hosts), nvml-mock 0.5.0, GPU Operator v26.3.3 and NVSentinel v1.21.0. The
cloud-init path was verified on 2026-10-20: one VM, GPU advertised as an NVIDIA B200 and the
Stack gate passed about 4.5 minutes after create; faults injected through the host.
The Metal3 variant was verified the same day: a VM-backed host relabeled in NetBox as an
`hgx-b200` device joined through a B200 NodeType with 8 GPUs, and the Stack gate passed about
5 minutes after create.
NVSentinel on those servers was verified next: a thermal fault on one GPU quarantined its server
in 13 s, a spare server was provisioned through Metal3, the failed one was deprovisioned back into
the pool, and the workload ran on the spare after 5 minutes 13 seconds, with no human step.
