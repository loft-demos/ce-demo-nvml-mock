# Metal3: a bare metal host as a simulated HGX B200 server

Make an ordinary bare metal host (or a VM-backed BareMetalHost) look like an 8-GPU B200
server all the way through the stack: inventory, Metal3, the NodeType, the tenant cluster's
template and the node itself. Everything mock-specific lives in the NodeType, so the tenant
cluster YAML is what you'd write for real GPU servers:

```yaml
privateNodes:
  autoNodes:
    - provider: my-metal3-provider
      static:
        - name: gpu
          quantity: 1
          nodeLabels:
            workload.example.com/pool: gpu-compute
          nodeTypeSelector:
            - property: vcluster.com/accelerator
              value: "b200"
```

The node joins with `nvidia.com/gpu: 8`, labeled `nvidia.com/gpu.product=NVIDIA-B200` by GPU
feature discovery, `vcluster.com/accelerator=b200`, and `nvidia-smi` shows eight B200s with their
own PCI bus IDs. Nothing CUDA runs; present the GPUs as simulated.

## How it fits together

```
NetBox device             device type hgx-b200, role gpu-compute, rack
   │ (NetBox import)
   ▼
BareMetalHost labels      netbox.vcluster.com/device-type=hgx-b200, role=gpu-compute, ...
   │ (NodeType bareMetalHosts.selector)
   ▼
NodeType                  resources nvidia.com/gpu: "8"; properties vcluster.com/accelerator: b200
                          + vcluster.com/user-data-template-config: nvml-mock-b200 (the "driver")
   │ (tenant cluster pool selects vcluster.com/accelerator)
   ▼
Node                      nvml-mock installed by cloud-init before the join; GPU Operator
                          (driver and toolkit off) advertises 8 GPUs
```

## Set it up

1. **Inventory.** With the NetBox import, add a device type and move one device to it:
   - Device type: manufacturer `NVIDIA`, model `HGX B200 8-GPU (simulated)`, slug `hgx-b200`.
     Keep the **same U height** as the device's current type, or it collides with its neighbors
     in the rack.
   - Device: that device type, role `gpu-compute`. Leave the rack, serial and import tag alone.

   The import relabels the BareMetalHost within a minute or two. Without NetBox, label the
   BareMetalHost yourself and select on those labels in the next step.
2. **MachineConfigTemplate.** Apply `out/hgx-b200.yaml` (from `scripts/configure.sh`; see
   [cloud-init.md](cloud-init.md)). It's rendered as `NAME=hgx-b200 GPU_COUNT=8 cloud-init/render.sh`:
   8 B200s built in, named for the server type. For several GPU models, use
   `nvidia-gpu-server` instead (below).
3. **NodeType.** Add `platform/metal3/node-type-snippet.yaml` to the Metal3 NodeProvider's
   `spec.metal3.nodeTypes`, adjusted to your site and rack labels. It declares `nvidia.com/gpu: "8"`
   and carries the cloud-init properties.
4. **Stack and tenant template.** Apply `out/nvml-mock-gpu-operator.yaml`,
   `out/nvml-mock-stack-gate.yaml`, `out/nvml-mock-gpu-preinstalled.yaml` and
   `out/nvml-mock-metal3-cloud-init.yaml`, then create a tenant cluster from **Private Nodes -
   Metal3 Servers with Simulated GPUs**.

## What it showed (2026-10-20)

On a vmetal VM-backed host (8 CPU, 16 GiB) relabeled as `hgx-b200`:

| Time | |
| --- | --- |
| 0:00 | Tenant cluster created |
| 1:38 | Host claimed through the B200 NodeType |
| 3:33 | Node joined (the host was already inspected; a full Metal3 boot adds several minutes) |
| 5:05 | 8 GPUs advertised, Stack gate passed at 8 |

Faults work per GPU: `GPU=5 demo/demo.sh heat <node>` pinned GPU 5 alone at 95 °C;
`demo/demo.sh reset` clears all eight.

## Failure demo: NVSentinel and a spare server

Template `nvml-mock-metal3-nvsentinel-dynamic`, Stack `nvml-mock-gpu-nvsentinel-preinstalled`. Two
hosts carry the B200 NodeType (one per rack), plus a CPU host for NVSentinel's pipeline:

- **Dynamic GPU pool** selecting `vcluster.com/accelerator: b200`, tainted, limit
  `(gpuServers + spareServers) x gpusPerServer` GPUs, retiring an empty server after a minute.
- **Workload first.** The Stack's first task runs one pod per GPU (8 for one server). They go
  Pending, and Auto Nodes provisions a server through Metal3 for them.
- **Static CPU service node** for cert-manager, MongoDB, fault-quarantine and node-drainer, so a
  drain never evicts the pipeline doing it.
- **Zero-limit headroom pool**, so Karpenter can still retire the failed server when the spare has
  taken the last GPU host.

Bring-up on 2026-10-20 (`gpuServers: 1`, `spareServers: 1`): GPU server claimed at 3 minutes
(Karpenter waits for its first cluster sync), joined at 5:35, 8 GPUs and the GPU gate at 7:10,
NVSentinel's pipeline up at about 10 minutes.

Then a thermal fault on one GPU of the eight (`GPU=3 demo/demo.sh heat <server>`):

| t | |
| --- | --- |
| 0 s | GPU 3 pinned at 142 °C |
| +13 s | `GpuThermalMarginWatch=True`; NVSentinel cordons the server and starts the drain; **Auto Nodes claims the spare server** |
| +72 s | Drain done; 8 pods Pending |
| +124 s | Metal3 has provisioned the spare |
| +148 s | Spare joins the tenant cluster |
| +195 s | **Karpenter retires the failed server**; Metal3 starts deprovisioning it |
| +207 s | Failed host back to `available` in the Metal3 pool |
| +254 s | Spare advertises 8 GPUs |
| +313 s | **All 8 pods running on the spare** |

No human step. The failed server went back into the pool as an ordinary available host, because
it's dynamic capacity: there's nothing to nurse back. With real hardware, keeping a bad GPU out of
rotation is a job for the machine layer (health checks before a host is handed out again), not
for Auto Nodes.

Notes from the run:

- The spare took about 100 s from joining to advertising GPUs, against about 60 s for the first
  server: the GPU Operator's validator waits on its driver check, which simply passed later.
- 16 workload pods show for a moment after the fault: the 8 evicted ones terminating and their 8
  replacements Pending.
- NVSentinel's pipeline pods restart once or twice while MongoDB comes up. That's expected.

## Gotchas

- **Broad GPU selectors claim the fake server.** A real GPU NodeType that selects every
  `gpu-compute` host in a rack (no device type) would match it too. Put the B200 host in another
  rack, or add a `device-type` key to the real NodeType.
- **Retyping a host removes it from its old NodeType** (CPU NodeTypes usually select on device
  type). Make sure nothing needs that capacity, and that no tenant cluster has it claimed.
- **The import's NetBox token is often read-only**, which is right for an import. Inventory edits
  need a user with write access.
- **Every NodeType property becomes a node label**, including the cloud-init ones. That's why
  the template is `hgx-b200` with the count built in: the node shows
  `vcluster.com/user-data-template-config=hgx-b200`, and no `nvml-mock` label at all. (The first
  version used `nvml-mock-b200` plus a `nvml-mock.vcluster.com/gpu-count` property, and both
  showed up in `kubectl get node --show-labels`.)
- **The provider must not set its own user-data template.** `vcluster.com/user-data`,
  `-template` and `-template-secret` on the NodeProvider or NodeType win over
  `-template-config`. A network-data template is fine.
- **NodeType capacity ignores tenant assignment.** If the host is assigned to a tenant, a claim
  from another project waits forever.
- **Within a server, GPUs have distinct UUIDs** (`...000` to `...007`); the same set repeats on
  every server, so dashboards key by node.

## Other GPU models: one template for B200, A100 and GB300

`cloud-init/machine-config-templates/nvidia-gpu-server.yaml`
(`PROFILES="b200 a100 gb300" NAME=nvidia-gpu-server cloud-init/render.sh`) carries all three
profiles. Each node picks one at boot from its own `vcluster.com/accelerator`, the property tenant
pools already select on, with that profile's GPU count:

| `vcluster.com/accelerator` | Simulated as | GPUs |
| --- | --- | --- |
| `b200` | NVIDIA B200 | 8 |
| `a100` | NVIDIA A100-SXM4-40GB | 8 |
| `gb300` | NVIDIA GB300 NVL (a 4-GPU tray) | 4 |
| anything else | the first profile (B200), logged | 8 |

So a GB300 server is a NodeType with `vcluster.com/accelerator: gb300`,
`vcluster.com/user-data-template-config: nvidia-gpu-server` and `nvidia.com/gpu: "4"` in its
resources, and no re-render. `nvml-mock.vcluster.com/gpu-count` still overrides the count.
Profile selection was checked against the rendered template for each value (and the fallback)
but not yet on a node. Caveats: nvml-mock 0.5.0 has no B300 profile (only a hand-made
`gpu.customConfig` could add one); GB300 is a Grace (arm64) part, so anything checking the
node's architecture sees x86.

## Undo

Set the NetBox device back to its old device type and role. The import relabels the host, and the
B200 NodeType shows zero capacity. Delete tenant clusters using it first, so the host is
deprovisioned before it changes NodeType.
