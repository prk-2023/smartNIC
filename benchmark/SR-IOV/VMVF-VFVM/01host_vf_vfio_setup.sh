#!/bin/bash
set -euo pipefail

# ============================================================================
# host_vf_vfio_setup.sh
#
# Sets up ONE SR-IOV VF on this host, bound to vfio-pci for passthrough into
# a VM (Test 2: VM-to-VM via VF, cross-host). Also creates a local, VF-
# independent management bridge so the host can SSH into its own VM -
# because once the VF is inside the VM, the host has no other way to
# reach the VM's test-path IP directly (same reasoning as the original
# single-host SR-IOV design, just now one VM per physical host instead
# of two VMs on one host).
#
# Run this ONCE per host (PC1 and PC2), each using its own port0.
#
# Usage: ./host_vf_vfio_setup.sh <pf_iface> <vf_mac>
#   e.g. on PC1: ./host_vf_vfio_setup.sh enp1s0f0np0 52:54:00:aa:bb:01
#        on PC2: ./host_vf_vfio_setup.sh enp1s0f0np0 52:54:00:aa:bb:02
# ============================================================================

PF_IFACE="${1:?Usage: $0 <pf_iface> <vf_mac>}"
VF_MAC="${2:?missing vf_mac, e.g. 52:54:00:aa:bb:01}"
VF_INDEX=0

MGMT_BRIDGE="br-mgmt"
MGMT_HOST_IP="192.168.50.1"       # same value on both hosts is fine - each
                                    # bridge is LOCAL to its own host, never
                                    # bridged together, so no conflict
MGMT_PREFIX="24"
MGMT_TAP="tap-mgmt0"
TAP_USER="$(whoami)"

echo "===== VFIO passthrough setup on ${PF_IFACE} ====="

# ---- 1. IOMMU check (should already be on from earlier troubleshooting) ----
grep -qE 'intel_iommu=on|amd_iommu=on' /proc/cmdline \
    || { echo "ERROR: IOMMU not enabled on kernel cmdline"; exit 1; }
echo "  OK: IOMMU enabled"

# ---- 2. Enable exactly 1 VF on this port ----
TOTAL=$(cat /sys/class/net/${PF_IFACE}/device/sriov_totalvfs 2>/dev/null || echo 0)
[[ "${TOTAL}" -gt 0 ]] || { echo "ERROR: sriov_totalvfs=0 on ${PF_IFACE}"; exit 1; }
CURRENT=$(cat /sys/class/net/${PF_IFACE}/device/sriov_numvfs)
if [[ "${CURRENT}" -lt 1 ]]; then
    echo 1 | sudo tee /sys/class/net/${PF_IFACE}/device/sriov_numvfs
fi
echo "  sriov_numvfs=$(cat /sys/class/net/${PF_IFACE}/device/sriov_numvfs)"

# ---- 3. Set a static, known MAC on the VF (so guest cloud-init can match it) ----
sudo ip link set ${PF_IFACE} vf ${VF_INDEX} mac ${VF_MAC} trust on spoofchk off

# ---- 4. Resolve VF PCI address and bind it to vfio-pci ----
# The VF currently belongs to mlx5_core (visible as a normal netdev) - we
# need to hand it over to vfio-pci so QEMU can claim it exclusively.
sudo modprobe vfio-pci
command -v driverctl >/dev/null 2>&1 || sudo dnf install -y driverctl

VF_BDF=$(basename "$(readlink -f /sys/class/net/${PF_IFACE}/device/virtfn${VF_INDEX})")
echo "  VF PCI address: ${VF_BDF}"
sudo driverctl set-override "${VF_BDF}" vfio-pci
echo "${VF_BDF}" > /tmp/vf_bdf.txt

# ---- 5. Confirm it actually bound (should show vfio-pci as current driver) ----
CURRENT_DRIVER=$(basename "$(readlink -f /sys/bus/pci/devices/${VF_BDF}/driver)")
[[ "${CURRENT_DRIVER}" == "vfio-pci" ]] \
    && echo "  OK: ${VF_BDF} bound to vfio-pci" \
    || { echo "  ERROR: ${VF_BDF} bound to '${CURRENT_DRIVER}', not vfio-pci"; exit 1; }

# ---- 6. IOMMU group isolation check ----
# With only ONE VF on this host (unlike the earlier two-VF-one-host attempt),
# this should cleanly show a group with just this device in it.
GROUP=$(basename "$(readlink -f /sys/bus/pci/devices/${VF_BDF}/iommu_group)")
MEMBERS=$(ls /sys/kernel/iommu_groups/${GROUP}/devices/)
echo "  iommu_group ${GROUP} members: ${MEMBERS}"
[[ $(echo "${MEMBERS}" | wc -w) -eq 1 ]] \
    && echo "  OK: isolated group" \
    || echo "  WARNING: shares group with other devices - passthrough may be blocked"

# ---- 7. Local management bridge (pure software, VF-independent) ----
# This exists purely so the host can SSH into its own VM's mgmt NIC.
# It is NEVER bridged to the CX-5 or to the other host - fully local.
if ! ip link show ${MGMT_BRIDGE} &>/dev/null; then
    sudo ip link add ${MGMT_BRIDGE} type bridge
    sudo ip link set ${MGMT_BRIDGE} type bridge stp_state 0
    sudo ip addr add ${MGMT_HOST_IP}/${MGMT_PREFIX} dev ${MGMT_BRIDGE}
    sudo ip link set ${MGMT_BRIDGE} up
fi
if ! ip link show ${MGMT_TAP} &>/dev/null; then
    sudo ip tuntap add dev ${MGMT_TAP} mode tap user "${TAP_USER}"
    sudo ip link set ${MGMT_TAP} master ${MGMT_BRIDGE}
    sudo ip link set ${MGMT_TAP} up
fi

echo
echo "Done."
echo "  VF BDF (pass to launch_sriov_vm.sh): ${VF_BDF}"
echo "  Mgmt bridge: ${MGMT_BRIDGE} (${MGMT_HOST_IP}/${MGMT_PREFIX}), tap: ${MGMT_TAP}"
echo
echo "  Next: build and launch the VM on this host with the existing scripts:"
echo "    ./build_sriov_vm_image.sh vmX <mgmt_ip> <mgmt_mac> <vf_ip> ${VF_MAC}"
echo "    ./launch_sriov_vm.sh vmX ${VF_BDF} ${MGMT_TAP} <mgmt_mac> <vcpu_pin_csv>"
