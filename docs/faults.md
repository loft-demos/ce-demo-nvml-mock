# Faults you can inject

`nvml-mock-ctl` (nvml-mock 0.5.0) changes what the simulated driver reports. Run it in the
nvml-mock pod (`kubectl -n mokka exec <pod> -c node-agent -- nvml-mock-ctl ...`), or on the host
for cloud-init nodes (`sudo nvml-mock-ctl ...`, or `kubectl debug node/...`, see
[cloud-init.md](cloud-init.md)). `demo/demo.sh heat` and `cool` pick the right one.

| Command | Simulates | Verified here |
| --- | --- | --- |
| `temp --gpu 0 142` | Overheating past the slowdown threshold | Yes: NVSentinel `GpuThermalMarginWatch=True`, cordon in 12 to 14 s, drain; DCGM reports 95 °C (its cap) |
| `fail --gpu 0 --mode ecc_uncorrectable --xid 48` | Double-bit ECC error, Xid 48 | Yes, on a cloud-init node: `NVRM: Xid (PCI:0000:1a:00): 48` in the kernel log |
| `fail --gpu 0 --mode fallen_off_bus --xid 79` | GPU fallen off the bus | No |
| `fail --gpu 0 --mode lost` | GPU lost (NVML calls fail) | No |
| `fail ... --after-calls N` | Fails after N successful calls, to hit a running job | No |
| `power`, `fan`, `util`, `clocks`, `throttle`, `pstate` | Pin a reading or a throttle reason | No |
| `nvlink-error`, `sram-ecc`, `fabric-health` | NVLink errors, SRAM ECC, NVLink fabric health | No |
| `set` | Set any override field directly | No |
| `fail --gpu 0 --mode healthy`, `reset --gpu 0` | Clear a failure, clear every override | Yes |
| `status`, `watch-allocations` | Show current overrides, follow device allocations | No |

Notes:

- **One override file per node.** Overrides live in `/var/lib/nvml-mock/driver/config/overrides.yaml`;
  `reset` clears them all for that GPU.
- **Kernel log.** The DaemonSet install writes Xids to the kernel log only with
  `nodeAgent.kernelLog.enabled`; the cloud-init install always does. NVSentinel's syslog health
  monitor reads them from there.
- **Only the thermal path is verified end to end with NVSentinel.** The others change what NVML
  and DCGM report; whether a given NVSentinel rule acts on them is worth a test before a demo.

## The faults that matter in real fleets

What operators of large GPU fleets usually see, and how close the mock gets:

| Fault | Typical sign | In the mock |
| --- | --- | --- |
| Uncorrectable memory ECC, row-remap failure | Xid 48, 63, 64, 94, 95 | `fail --mode ecc_uncorrectable --xid <n>` |
| GPU fallen off the bus | Xid 79, the device disappears | `fail --mode fallen_off_bus --xid 79` |
| NVLink errors | Xid 74, NVLink CRC and replay counters | `nvlink-error` |
| Thermal and power throttling | Clocks drop, throttle reasons set | `temp`, `power`, `throttle` |
| GSP firmware errors, driver hangs | Xid 119, 120 | `fail --xid 119` surfaces the Xid; the hang itself isn't simulated |
| PCIe errors (AER) | Kernel PCIe errors, link retraining | Not simulated |
| Application faults | Xid 13, 31, 43 (usually the workload, not the GPU) | `fail --xid <n>` surfaces the Xid |

Most real incidents need a node drain and a reset or reboot; memory faults that row remapping
can't fix need the GPU replaced. That is the loop the spare-capacity and dynamic templates show.
