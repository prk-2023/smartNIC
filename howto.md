# ConnectX-5 Virtualization Datapath Benchmark

Benchmarks four metrics 

— **small-packet forwarding efficiency (Mpps)**,
- **transmission bandwidth**, 
- **average latency**, and 
- **host CPU usage** 

across three network virtualization architectures on a ConnectX-5 25GbE
dual-port NIC:

1. **Native VirtIO** (kernel `vhost-net`)
2. **SR-IOV** (VF passthrough via `vfio-pci`)
3. **OVS + DPDK** (userspace datapath via `vhost-user`)

All tests use a **physical DAC loopback cable** between the NIC's two ports as the "network" 
no external switch involved. 

Results are written to `results/<run_name>/summary.json` 

---

## 1. Package requirements (Fedora)

```bash
# Core virtualization
sudo dnf install -y qemu-kvm qemu-img podman

# Guest image building
sudo dnf install -y libguestfs-tools supermin cloud-utils   # virt-customize, cloud-localds
# (genisoimage or xorriso as fallback if cloud-localds is unavailable - usually pulled in already)

# Benchmark tools (host side - guest side installed automatically via virt-customize)
sudo dnf install -y iperf3 sysstat qperf

# SR-IOV leg only
sudo dnf install -y driverctl        # bind VFs to vfio-pci
sudo dnf install -y mstflint         # mstconfig - Fedora's open-source alternative to NVIDIA's mlxconfig

# OVS-DPDK leg only
sudo dnf install -y openvswitch-dpdk # DPDK-linked ovs-vswitchd (swaps out plain 'openvswitch' if installed)

# General
sudo dnf install -y python3          # result parsing (collate_results.py, inline parsers)
```

### Group membership (needed once)
```bash
sudo usermod -aG kvm,libvirt $(whoami)
# then fully log out/in (or reboot) - group changes don't apply to the current session
```

### Kernel command-line parameters
Check current: `cat /proc/cmdline`. Add any missing via:
```bash
sudo grubby --update-kernel=ALL --args="<params>"
sudo reboot
```

| Parameter | Needed for | Notes |
|---|---|---|
| `intel_iommu=on` (or `amd_iommu=on`) | SR-IOV VF passthrough | Required for `vfio-pci` |
| `iommu=pt` | SR-IOV (perf tuning) | Optional but recommended |
| `default_hugepagesz=2M hugepagesz=2M hugepages=1024` | All legs | 1024 x 2MB = 2GB; raise for OVS-DPDK/dual-VM legs which need more |
| `isolcpus=N-M nohz_full=N-M rcu_nocbs=N-M` | All legs | Isolates cores for vCPU/vhost/PMD pinning |
| `pci=realloc,assign-busses` | SR-IOV (attempted fix) | Did **not** fully resolve our dual-port-per-host VF issue - see Known Issues |
| `pcie_acs_override=downstream,multifunction` | SR-IOV (workaround) | Only if IOMMU group isolation check fails; **weakens PCIe isolation**, use only on a dedicated bench host |

### Locked memory limit (needed for SR-IOV / any `vfio-pci` passthrough)
```bash
echo "$(whoami) hard memlock unlimited" | sudo tee -a /etc/security/limits.conf
echo "$(whoami) soft memlock unlimited" | sudo tee -a /etc/security/limits.conf
# new login session required
```

### `/boot/vmlinuz` readability (only if `virt-customize` fails with `guestfs_launch failed`)
```bash
sudo chmod 0644 /boot/vmlinuz-$(uname -r)
```

---

## 2. Repo layout and what each script does

### Shared / used by every leg

| Script | Purpose |
|---|---|
| `collate_results.py` | Averages one or more `results/<run>/summary.json` files (repeat runs of the same leg) and prints a ready-to-paste markdown table row with mean +/- stdev. |

---

### Leg 1: Native VirtIO (kernel `vhost-net`)

```
Guest VM (virtio-net) -> vnet0 (tap) -> br0 -> port0 --DAC-- port1 (host IP, test peer)
```

| Script | Purpose |
|---|---|
| `build_guest_image.sh` | Pulls a Fedora containerdisk image via podman, extracts the raw disk, bakes   |
|                        | `iperf3`/`sysstat`/`qperf` in via `virt-customize`, layers a writable qcow2   |
|                        | overlay, and generates a cloud-init seed ISO (static IP on the guest's NIC    |
|                        | matched by MAC, SSH key auth, `iperf3-server`/`qperf-server` systemd units, a |
|                        | `guest-monitor@.service` template for per-run CPU/interrupt capture).         |
| `host_network_setup.sh`| One-time host prep: hugepages, creates `br0` with `port0` as a member (no IP on |
|                        | the bridge slave itself), creates the `vnet0` tap, assigns the host's static IP |
|                        | to `port1` (the DAC loopback peer), disables STP delay and bridge-netfilter interception. |
| `launch_virtio.sh` | Boots the VM with `-netdev tap,vhost=on` (kernel vhost-net path), hugepage-backed |
|                    | RAM, vCPU pinning, and pre-flight checks (hugepages free, `/dev/vhost-net`, `/dev/kvm`, |
|                    | stale-process detection). |
| `run_test.sh` | Runs the four-metric test: `iperf3` TCP (throughput), `iperf3` UDP 64B unlimited-rate  |
|               | (PPS), `qperf tcp_lat udp_lat` (latency), `mpstat`/`pidstat` (host + guest CPU).       |
|               | Parses everything into`summary.json`.                                                  |

---

### Leg 2: SR-IOV (VF passthrough via `vfio-pci`)

**Important:** we originally tried putting **both** VFs (one per port) on a
**single** host - this failed. Consumer PCIe root complexes (tested on both
an Intel board and an AMD A520/Ryzen board) lack ARI (Alternate Routing-ID
Interpretation) support, so the second port's VF has nowhere to land on the
PCI bus (`pci_enable_sriov failed: -5`). The working design splits this
across **two physical hosts**, one VF each - plus a **bare-metal-only**
variant that needs no VM at all, as a reference ceiling.

**Superseded (kept for reference only - do not use for the actual benchmark):**
`host_sriov_setup.sh`, `launch_sriov_vm.sh` (single-host, two ports), `run_test_sriov.sh`

**Test 2a - bare-metal VF-to-VF (no VM, reference ceiling):**
```
PC1: VF0 of port0 (plain host netdev) --DAC-- PC2: VF0 of port0 (plain host netdev)
```
| Script | Purpose |
|---|---|
| `host_vf_baremetal_setup.sh` | Enables 1 VF on the given PF, sets a static MAC, and assigns a static IP **directly to the VF interface** as an ordinary kernel netdev - no VM, no `vfio-pci`. Run once per host. |
| `run_test_baremetal_vf.sh` | Cross-host: run from PC1, reaches PC2 over its **normal management network** (not the isolated VF subnet) to start `mpstat`/`iperf3`/`qperf` servers (nohup'd so they survive SSH session teardown), then benchmarks directly against PC2's VF IP. |

**Test 2b - VM-to-VM via VF passthrough:**
```
PC1: VM1 [VF0 port0, vfio-pci] --DAC-- PC2: VM2 [VF0 port0, vfio-pci]
```
| Script | Purpose |
|---|---|
| `host_vf_vfio_setup.sh` | Enables 1 VF, sets a static MAC, binds it to `vfio-pci` via `driverctl`, checks IOMMU group isolation, and creates a **local-only management bridge** (`br-mgmt`) - needed because once the VF is inside the VM, the host has no other way to reach it; this bridge never touches the CX-5. |
| `build_sriov_vm_image.sh` | Parameterized (VM name, mgmt IP/MAC, dataplane IP/MAC) image builder - same base as `build_guest_image.sh`, but with **two** NICs matched by MAC: one for mgmt, one for the passed-through VF (or, when reused for the OVS-DPDK leg, the vhost-user NIC). |
| `launch_sriov_vm.sh` | QEMU launcher: `-device vfio-pci,host=<VF BDF>` for the dataplane NIC, plain tap/vhost-net for mgmt. |
| `run_test_vm_vf.sh` | Cross-host: runs from PC1, reaches VM1 directly, reaches VM2 via **SSH ProxyJump through PC2** (both VM images must be built with the same SSH public key). Same four-metric test as the virtio leg, plus captures host CPU on *both* physical hosts - should be near-zero on both, confirming the kernel bypass actually worked. |

---

### Leg 3: OVS + DPDK (`vhost-user` userspace datapath)

`mlx5`'s DPDK PMD does **not** need `vfio-pci`/unbinding (unlike Intel PMDs) - it works through the 
existing `mlx5_core` kernel driver + `rdma-core`, so this leg sidesteps the whole IOMMU-group/ARI problem 
class from the SR-IOV leg entirely.

**3a - single-port (mirrors the Native VirtIO leg's shape exactly - this is the one that fills the
"OVS+DPDK" column in the team comparison table):**

```
VM (virtio-net) -> vhost-user -> OVS-DPDK bridge -> dpdk0(port0) --DAC-- port1 (host IP, kernel netdev peer)
```
| Script | Purpose |
|---|---|
| `host_ovs_dpdk_setup.sh` | Installs `openvswitch-dpdk`, enables DPDK in OVS (`dpdk-init`, `pmd-cpu-mask`, `dpdk-socket-mem`), creates a `datapath_type=netdev` bridge with port0 bound to the DPDK PMD and a `dpdkvhostuserclient` port for the VM to connect to. Port1 stays exactly as in the virtio leg (plain kernel peer). |
| `launch_ovs_dpdk_vm.sh` | Boots the **same** `guest.qcow2`/`seed.iso` as the virtio leg (guest is unmodified - same driver, same IP config), but connects via `-chardev socket` + `-netdev vhost-user` instead of a tap. Confirms OVS actually linked to the socket before declaring success. |
| `run_test_ovs_dpdk.sh` | Same test as `run_test.sh`, plus captures `ovs-appctl dpif-netdev/pmd-stats-show` and `pmd-perf-show` before/after - needed to correctly interpret host CPU%, since PMD threads busy-poll at ~100% **by design**. |

**3b - dual-port, dual-VM (optional deeper-isolation test - fully bypasses the kernel on *both* physical
ports, at the cost of no longer having a single "OVS+DPDK" number directly comparable to the single-port
leg's shape):**
```
VM1 -> vhost-user0 -> br-left  -> dpdk0(port0) --DAC-- dpdk1(port1) -> br-right -> vhost-user1 -> VM2
```
| Script | Purpose |
|---|---|
| `host_ovs_dpdk_dualport_setup.sh` | Binds **both** ports to DPDK, creates two independent bridges (`br-left`, `br-right` - each a simple two-port "virtual patch cable" rather than one 4-port bridge relying on L2 learning), plus a local `br-mgmt` bridge (same reasoning as the SR-IOV leg) for SSH into both VMs. |
| `launch_ovs_dpdk_vm_generic.sh` | Generic, reused for both VM1 and VM2 via arguments - each VM gets a vhost-user dataplane NIC plus a tap/vhost-net mgmt NIC. |
| `run_test_ovs_dpdk_dualvm.sh` | Same-host version of the cross-host VF test - no ProxyJump needed since both VMs are local. VM1 is client, VM2 is server. |

> **Note:** this leg deliberately avoids putting both NICs on *one* VM
> (self-loopback) - that would double the vhost-user/OVS hop count per
> packet and introduce CPU contention between the client and server roles
> sharing one guest's vCPUs, breaking comparability with the other legs.

---

## 3. Known issues encountered while building this (read before re-running from scratch)

- **`podman run --entrypoint sh` fails on containerdisk images** - they're `FROM scratch`, no shell inside. Use `podman create` (never executes anything) + `podman export | tar -tv` to inspect/extract instead.
- **`qemu-img info --output=json` can have multiple `"format"` keys** on newer QEMU, breaking naive `grep`/JSON parsing - use the plain-text `file format:` line instead.
- **`-daemonize` + `-serial mon:stdio` conflict** - daemonizing detaches stdio, which `mon:stdio` requires. Use `-serial file:<path>` instead.
- **cloud-init caches `user-data` per `instance-id`** - reusing the same overlay disk with a changed `user-data` but unchanged `instance-id` silently skips reprocessing. Use a timestamp-based `instance-id`.
- **NetworkManager profile `interface-name=` must match the guest's actual name** (`ens3`, not `eth0`, on this containerdisk/systemd-predictable-naming combo) - or match by `mac-address=` instead, which is stable regardless of naming scheme.
- **`virt-customize` under `sudo` (libvirt backend) fails with `Permission denied`** on files under a user's home directory (mode 700 blocks the separate libvirt-qemu process) - use `LIBGUESTFS_BACKEND=direct` and drop `sudo`.
- **`virt-customize`/`guestfs_launch failed`** - often caused by `/boot/vmlinuz-$(uname -r)` being unreadable by non-root on Fedora; `chmod 0644` it.
- **Bridge-slave interfaces shouldn't carry an IP** - once `port0` is enslaved to `br0`, its own IP doesn't work reliably; put host IPs on non-bridged interfaces only.
- **SR-IOV on both ports of one host can fail with `pci_enable_sriov failed: -5`** - consumer PCIe root complexes commonly lack ARI support, so the second port's VF has no bus number to land on. `pci=realloc,assign-busses` doesn't fix this (it's an ARI limitation, not a BAR/bus-count issue). Workaround: split across two hosts, or accept the same-port dual-VF (internal e-switch) alternative.
- **`vfio-pci` passthrough: `Cannot allocate memory` (-12)** - the launching user's `RLIMIT_MEMLOCK` is too low to pin the guest's RAM for DMA. Set `hard/soft memlock unlimited` in `/etc/security/limits.conf` (needs a new login session).
- **`vfio-pci` passthrough: `group N is not viable`** - the VF's IOMMU group contains another device (often the PF) not bound to `vfio-pci`, usually due to missing ACS support on the root complex. `pcie_acs_override=downstream,multifunction` is the common (isolation-weakening) workaround.
- **Backgrounded remote SSH commands get `SIGHUP`'d** when the SSH session's shell exits, unless `nohup`'d - bit us when starting `iperf3`/`qperf` servers remotely for the bare-metal SR-IOV leg.
- **mlx5's DPDK PMD does not need `vfio-pci`** (unlike Intel PMDs) - it uses `dpdk-devargs=<PCI address>` while the port stays on `mlx5_core` + `rdma-core`. This is why the OVS-DPDK leg avoids all the IOMMU-group/ARI problems the SR-IOV leg hit.
- **ConnectX-5 is not supported by DPDK's mlx5 vDPA driver** - hardware vDPA offload requires ConnectX-6/6 Dx/6 Lx/7, BlueField, or BlueField-2/3 (source: https://doc.dpdk.org/guides-24.07/vdpadevs/mlx5.html).

---

## 4. Typical run sequence (any leg)

```bash
# repeat 3+ times per leg before trusting the numbers (run-to-run variance)
./run_test_<leg>.sh <leg>_run1
./run_test_<leg>.sh <leg>_run2
./run_test_<leg>.sh <leg>_run3

./collate_results.py <leg>_run1 <leg>_run2 <leg>_run3
# paste the printed markdown row into the comparison table
```
