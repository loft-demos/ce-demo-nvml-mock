# nvml-mock from cloud-init

The Stack templates install nvml-mock as a DaemonSet (`nvml-mock-driver`). This variant puts
it in the machine instead: a vCluster Platform **MachineConfigTemplate** installs nvml-mock on
the host from cloud-init, so the node joins already looking like a GPU node with a driver, and
the Stack only has to deploy the GPU Operator, as it would on real hardware.

Why bother:

- **The GPU is part of the node, not the tenant's workloads.** Nothing in the tenant cluster
  (no `mokka` namespace, no DaemonSet) gives away that the GPU is simulated, and a tenant can't
  uninstall it.
- **Closer to the real-GPU Stack.** With the driver "preinstalled", a GPU Operator install with
  driver and toolkit turned off per node (the `nvidia.com/gpu.deploy.*=false` labels the
  template sets) is the same shape as a real deployment that uses a host driver.
- **Works on any provider that renders cloud-init through the Platform**: KubeVirt, Metal3,
  NICo, BCM, Terraform and external platforms all call the same user-data code.

## How it works

```
NodeClaim properties (pool or NodeType)
  vcluster.com/user-data-template-config: nvml-mock-b200
        │
        ▼
MachineConfigTemplate nvml-mock-b200  ──  Go template + sprig, .Values.{NodeClaim, Project, Properties, SSHKeys}
        │
        ▼
cloud-config: write_files (profile, units, scripts) + runcmd (enable units, start install --no-block)
        + the Platform's join command, appended AFTER the template's runcmd
        │
        ▼
nvml-mock-install.service (waits for /etc/kubernetes/kubelet.conf, the join's last step)
  → ctr pull + mount ghcr.io/nvidia/nvml-mock:<version>, copy binaries and libraries to /usr/local
  → nvml-mock-agent.service (the DaemonSet's node-agent, host root "/")
  → nvml-mock-nri.service (the DaemonSet's NRI plugin)
```

Details that matter:

- **Precedence.** The Platform takes the first of `vcluster.com/user-data` (literal),
  `vcluster.com/user-data-template` (inline), `vcluster.com/user-data-template-secret`
  (`namespace/name`) and `vcluster.com/user-data-template-config` (MachineConfigTemplate). A
  NodeType or provider that already sets one of the first three wins over this template.
- **Properties merge** provider, then NodeType, then network environment, then NodeClaim, so a
  tenant cluster pool's `properties` (which land on the NodeClaim) override the NodeType.
- **The join runs after the template's runcmd**, and it replaces containerd and its
  `config.toml`. That is why the install is a systemd unit started with `--no-block` that waits
  for the join to finish: nvml-mock edits containerd's config, and `ctr` only exists once the
  join installed it.
- **The template is a Go template.** Only the env file uses it
  (`GPU_COUNT` from the optional `nvml-mock.vcluster.com/gpu-count` property). Everything else is
  plain; `render.sh` refuses files containing `{{`.
- **Same profile as the DaemonSet.** `render.sh` renders the nvml-mock chart with
  `cloud-init/values.yaml` (the same values as `nvml-mock-driver`) and embeds its ConfigMaps
  gzip+base64. The generated `config.yaml` matched a DaemonSet install's ConfigMap (bar a trailing newline).
- **Registry mirrors apply.** The install pulls with `ctr --hosts-dir /etc/containerd/certs.d`,
  so mirrors configured under `privateNodes.joinNode.containerd.registry` are used.

Differences from the DaemonSet install:

| | DaemonSet | cloud-init |
| --- | --- | --- |
| Agent host root | `/host` mount | `/` |
| Health endpoints | pod network `:9091`, `:8080` | `127.0.0.1:9091`, `127.0.0.1:18080` |
| InfiniBand mock | `full` (cross-node ping fabric via a Service) | `sysfs` (no Service to reach) |
| Kernel log XIDs | off by default | on (`MOCK_NVML_KMSG=/dev/kmsg`), so XIDs reach `dmesg` and NVSentinel's syslog monitor |
| NRI excluded namespaces | `mokka`, `kube-system` | `kube-system` |
| Fault injection | `kubectl exec ds/nvml-mock -c node-agent -- nvml-mock-ctl ...` | `sudo nvml-mock-ctl ...` on the node, or `kubectl debug node/...` (below) |

## Use it

1. Render a template per GPU profile you want (the repo ships `b200`):

   ```sh
   cloud-init/render.sh                 # nvml-mock-b200, 1 GPU per node by default
   PROFILE=h100 cloud-init/render.sh    # nvml-mock-h100
   ```

   One template can also carry several profiles and let each node pick by its
   `vcluster.com/accelerator` (B200, A100, GB300 in the repo's `nvidia-gpu-server`):

   ```sh
   PROFILES="b200 a100 gb300" NAME=nvidia-gpu-server cloud-init/render.sh
   ```

   See [metal3-b200.md](metal3-b200.md#other-gpu-models-one-template-for-b200-a100-and-gb300).

   The GPU count isn't baked in: the chart only passes it as an env variable, so one template
   serves any count through the `nvml-mock.vcluster.com/gpu-count` property (`GPU_COUNT` sets
   the default).

   Needs `helm`, `yq` v4, `curl`, `gzip`, `base64`.
2. `scripts/configure.sh env.local` and apply `out/nvml-mock-b200.yaml`,
   `out/nvml-mock-gpu-operator.yaml`, `out/nvml-mock-stack-gate.yaml`,
   `out/nvml-mock-gpu-preinstalled.yaml` and `out/nvml-mock-kubevirt-cloud-init.yaml`.
3. Create a tenant cluster from **Private Nodes - KubeVirt VMs with Simulated GPUs (nvml-mock
   from cloud-init)**.

## Metal3: whole servers as multi-GPU machines

See [metal3-b200.md](metal3-b200.md): a bare metal host presented as an 8 x B200 server, with the
cloud-init properties on the NodeType so the tenant cluster selects it like real GPU capacity.

To use it with your own templates, set the property on any pool:

```yaml
privateNodes:
  autoNodes:
    - provider: my-provider
      static:
        - name: gpu
          quantity: 1
          properties:
            vcluster.com/user-data-template-config: nvml-mock-b200
            # nvml-mock.vcluster.com/gpu-count: "8"   # optional override
          nodeLabels:
            nvidia.com/gpu.deploy.driver: "false"
            nvidia.com/gpu.deploy.container-toolkit: "false"
```

or on a NodeType's `properties` (see `platform/kubevirt-provider/node-type-snippet.yaml` and
`platform/metal3/node-type-snippet.yaml`). For
a dynamic pool, the NodeType must declare `nvidia.com/gpu` in its `resources` so Auto Nodes can
launch it for GPU pods.

## Verify on the node

```sh
kubectl debug node/<node> -it --profile=sysadmin --image=busybox:1.36 -- chroot /host bash
systemctl status nvml-mock-install nvml-mock-agent nvml-mock-nri --no-pager
journalctl -u nvml-mock-install -u nvml-mock-agent --no-pager | tail -30
nvidia-smi -L
sudo nvml-mock-ctl status
```

In the tenant cluster: `kubectl get nodes -o custom-columns=NAME:.metadata.name,GPU:.status.allocatable.nvidia\\.com/gpu`.

## Fault injection

`/usr/local/sbin/nvml-mock-ctl` wraps the real tool with the environment the DaemonSet gave
`kubectl exec`. `demo/demo.sh heat` and `cool` use it through `kubectl debug` when a node has
no nvml-mock pod, so no SSH is needed. By hand:

```sh
kubectl debug node/<node> --profile=sysadmin --image=busybox:1.36 -- chroot /host nvml-mock-ctl temp --gpu 0 142
kubectl logs <the node-debugger-... pod it printed>     # the output
kubectl delete pod <the node-debugger-... pod>
```

Don't rely on `kubectl debug -i` for one-shot commands: the pod finishes before the attach and
the output is lost. Read the pod's logs instead.

## Limits

- **Profiles are fixed at render time.** A multi-profile template carries the profiles it was
  rendered with; a new model means a re-render.
- **Image updates need a re-render.** The install is skipped once
  `/var/lib/nvml-mock-install/installed` names the current image; a new version in
  `nvml-mock.env` (after a re-render and a new node) installs again.
- **Not a production pattern**: the libraries go into `/usr/local/lib` and the ld cache, which is
  what a mock driver is for, and exactly what you don't want on a real GPU node.
