# VirtIO Performance Benchmarking — DGX Spark Platform Addendum

**Readme:** Test matrix for the DGX Spark (ARM/Grace, GB10 Superchip) ⟷ Intel i5 PC (ConnectX-6) setup, connected via QSFP56 DAC.

---

## 0. Hardware + Topology Summary

| Item | PC | DGX Spark |
|---|---|---|
| CPU | Intel i5 (x86_64) | NVIDIA Grace: 20-core Arm (10× Cortex-X925 + 10× Cortex-A725), aarch64 |
| NIC | ConnectX-6 (add-in card) | ConnectX-7 (onboard, part of GB10 Superchip) |
| IOMMU | Intel VT-d | Arm SMMU |
| OS | DGX: Ubuntu:24.x , PC: Fedora:43  | NVIDIA DGX OS (patched kernel — Ethernet/GPU require this specific kernel) |
|NICS| DGX: CX-7, PC: CX-6| CX-7 has new eSwitch and better vDPA offloading |
| Link | QSFP56 DAC between the two NICs | Depends on Link Negotiation |

**Note on NIC mismatch:** 
- Two ends are different NICs (CX-6 vs CX-7). Link-level tests will negotiate to the lower common denominator.
- But ASAP²/e-switch/vDPA offload behavior may differ between ends.

---

## 1. Checklist (DGX Spark only: run before scheduling SR-IOV / vDPA test days)

(DGX Spark is ARM based custom system: test the below items before scheduling SR-IOV / vDPA test)

| # | Check | Command | Gates |
|---|---|---|---|
| 1 | Confirm running NVIDIA-shipped kernel (not a swapped-in generic aarch64 kernel) | `uname -a` | All rows |
| 2 | Confirm PCIe ARI capability on Grace root complex | `lspci -vvv -s <cx7-bdf>` (look for "ARI" in extended capabilities) | BM-3, VIRTIO-3, SRIOV-2, SRIOV-3. If Fail: requires kernel module build/chk firmware|
| 3 | Confirm `mlx5_vdpa` module presence/buildability | `modinfo mlx5_vdpa`; `find /lib/modules/$(uname -r) -iname "*vdpa*"` | VDPA-1, VDPA-2, VDPA-3. If Fail: requires kernel module build/chk firmware |
| 4 | Confirm SMMU passthrough cmdline works | `cat /proc/cmdline`; add SMMU passthrough param; `dmesg \| grep -i smmu` | SRIOV-*, VDPA-* |


---

## 2. Bare-metal (no VM) : reference measurement

| ID | Topology | Data flow | PC | DGX Spark | Notes |
|---|---|---|---|---|---|
| BM-1 | Single host, dual-port, plain kernel netdevs | `port0(kernel) ⟷ DAC ⟷ port1(kernel)` | N/A (single NIC) |  Run here | |
| BM-2 | Dual host, single port each, plain kernel netdevs | `PC1:port0(kernel) ⟷ DAC ⟷ DGX:port0(kernel)` |  |  | CX-6 ⟷ CX-7 cross-generation link |
| BM-3 | Single host, dual-port, VF-to-VF | `port0:VF0 ⟷ DAC ⟷ port1:VF0` |  no ARI |  Pending pre-flight check #2 | Run only if ARI confirmed present |
| BM-4 | Dual host, single VF each | `PC1:port0:VF0 ⟷ DAC ⟷ DGX:port0:VF0` |  |  | |

---

## 3. Native VirtIO (`vhost-net`)

| ID | Topology | Data flow | PC | DGX Spark | Notes |
|---|---|---|---|---|---|
| VIRTIO-1 | Single host, one VM, kernel peer | `VM→vhost-net→br0→port0 ⟷ DAC ⟷ port1(kernel)` |  |  | Direct comparison target |
| VIRTIO-2 | Dual host, one VM each | `PC1:VM1→vhost-net→port0 ⟷ DAC ⟷ DGX:port0→vhost-net→VM2` |  |  | Requires KVM confirmed functional on DGX OS |
| VIRTIO-3 | Single host, dual-port, one VM each | `VM1→vhost-net→port0 ⟷ DAC ⟷ port1→vhost-net→VM2` |  no ARI |  Pending pre-flight check #2 | |

---

## 4. SR-IOV (`vfio-pci` VF passthrough)

| ID | Topology | Data flow | PC | DGX Spark | Notes |
|---|---|---|---|---|---|
| SRIOV-1 | Dual host, one VF/VM each | `PC1:VM1[VF,vfio-pci] ⟷ DAC ⟷ PC2:VM2[VF,vfio-pci]` |  (needs 2nd PC) | — | Re-check if a second PC is actually available; else substitute with SRIOV3IO-4 dual-host case |
| SRIOV-2 | Single host, dual-port, one VF/VM each | `VM1[VF0 port0] ⟷ DAC ⟷ VM2[VF0 port1]` | no ARI |  Pending check #2 | |
| SRIOV-3 | Single host, same port, two VFs, e-switch loopback | `VF0 ⟷ NIC internal e-switch ⟷ VF1` (no DAC) | — | Pending check #2 | Isolates NIC-internal switching cost vs. external PHY/cable cost |
| SRIOV3IO-4 | Dual host, single VF each, virtio inside VM over VF | `PC1:VM1→vhost-net→port0:VF0 ⟷ DAC ⟷ VF0:port1→vhost-net→VM2:DGX` |  |  | SR-IOV enablement path differs: PC uses BIOS VT-d + `mlxconfig`; DGX Spark uses SMMU cmdline params (check #4) + `mlxconfig` (arch-independent, should apply the same way) |

**ARM-specific SR-IOV enablement differences to document in the write-up:**
- No legacy BIOS SR-IOV toggle on DGX Spark — enablement is via kernel cmdline SMMU parameters, not a VT-d-style BIOS switch.
- `mlxconfig` firmware-level SR-IOV enable/VF count should behave identically on both ends (firmware tool is architecture-independent).

---

## 5. OVS + DPDK (`vhost-user`)

| ID | Topology | Data flow | PC | DGX Spark | Notes |
|---|---|---|---|---|---|
| OVSDPDK-1 | Single host, single port, kernel peer | `VM→vhost-user→OVS-DPDK→dpdk0(port0) ⟷ DAC ⟷ port1(kernel)` | (distro packages likely available) |  (build from source) | mlx5 PMD is arch-agnostic (built on rdma-core); packaging, not capability, is the ARM friction point |
| OVSDPDK-2 | Single host, dual-port, one VM each | `VM1→vhost-user0→br-left→dpdk0 ⟷ DAC ⟷ dpdk1→br-right→vhost-user1→VM2` |  |  | |
| OVSDPDK-3 | Dual host, one VM each | `PC1:VM1→vhost-user→OVS-DPDK→port0 ⟷ DAC ⟷ PC2:port0→OVS-DPDK→vhost-user→VM2` |  (needs 2nd PC) |  | |

**ARM-specific build note:** build OVS + DPDK from source against DGX OS kernel headers, using DPDK's `arm64-native` meson cross-file tuned for Cortex-X925/A725 rather than a generic armv8 target. Do not assume a prebuilt `openvswitch-switch-dpdk`-equivalent package exists in the DGX OS repos — verify first.

---

## 6. vDPA (new category — CX-6/CX-7 only)

| ID | Topology | Data flow | PC | DGX Spark | Notes |
|---|---|---|---|---|---|
| VDPA-1 | Single host, single port, kernel peer | `VM→vhost-vdpa→mlx5_vdpa(HW offload)→port0 ⟷ DAC ⟷ port1(kernel)` |  |  Pending check #3 | |
| VDPA-2 | Single host, dual-port, one VM each | `VM1→vhost-vdpa→port0 ⟷ DAC ⟷ port1→vhost-vdpa→VM2` |  |  Pending checks #2 + #3 | |
| VDPA-3 | Dual host, one VM each | `PC1:VM1→vhost-vdpa→port0 ⟷ DAC ⟷ DGX:port0→vhost-vdpa→VM2` |  |  Pending check #3 | Direct comparison against SRIOV-1/SRIOV3IO-4 — vDPA retains virtio semantics (live-migration-friendly) vs. raw VF exposure |

*(vDPA has no bare-metal-equivalent case — it's inherently virtio-facing; there's no "just use it directly on the host" mode analogous to a VF.)*

**Biggest open risk in the whole matrix:** whether `mlx5_vdpa` is present or buildable in NVIDIA's DGX Spark kernel tree. Resolve via pre-flight check #3 before scheduling any VDPA-* test day. If absent, this becomes a kernel-module-build task, not a configuration task, and should be scoped/timeboxed separately from the rest of the benchmarking work.

---

## 7. Summary of Platform-Level Deltas (PC vs. DGX Spark)

| Concern | PC (x86_64, CX-6) | DGX Spark (aarch64, CX-7) |
|---|---|---|
| IOMMU enablement | `intel_iommu=on iommu=pt` (GRUB) | SMMU passthrough cmdline params (exact syntax TBD — check #4) |
| SR-IOV BIOS toggle | Standard VT-d/SR-IOV BIOS options | No legacy BIOS SR-IOV toggle; UEFI menu is limited |
| ARI support | Confirmed absent | Unconfirmed — check #2 |
| vDPA kernel module | Well-established (`mlx5_vdpa` in mainline) | Unconfirmed in DGX OS kernel — check #3 |
| OVS-DPDK | Likely packaged | Build from source (aarch64-tuned) |
| Kernel | Any modern distro kernel | Must use NVIDIA DGX Spark kernel (required for CX-7 Ethernet + GPU) |
| NIC generation | ConnectX-6 | ConnectX-7 (onboard, GB10) |

---
