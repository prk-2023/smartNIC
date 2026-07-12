#!/bin/bash
set -euo pipefail

# ============================================================================
# host_vf_baremetal_setup.sh
#
# Sets up ONE SR-IOV VF on this host and assigns it a static IP directly,
# as an ordinary kernel netdev. No VM, no vfio-pci, no QEMU involved.
#
# This is the "ceiling" reference test: VF hardware + mlx5_core driver +
# Linux networking stack, with zero virtualization overhead. Run the
# equivalent of this script on BOTH physical hosts (PC1 and PC2), each
# using its own PF/port, then run iperf3/qperf directly between the two
# resulting VF IPs across the DAC cable.
#
# Usage: ./host_vf_baremetal_setup.sh <pf_iface> <vf_ip>
#   e.g. on PC1: ./host_vf_baremetal_setup.sh enp1s0f0np0 192.168.101.10
#        on PC2: ./host_vf_baremetal_setup.sh enp1s0f0np0 192.168.101.20
# (Each host uses its OWN port0 here - remember: dual-port-on-one-host is
#  what's blocked by the ARI/PCIe bus limitation we hit earlier. Two
#  separate hosts, one VF each, sidesteps that entirely.)
# ============================================================================

PF_IFACE="${1:?Usage: $0 <pf_iface> <vf_ip>}"
VF_IP="${2:?missing vf_ip, e.g. 192.168.101.10}"
VF_PREFIX="24"
VF_INDEX=0
VF_MAC="52:54:00:cc:dd:$(printf '%02x' $((RANDOM % 256)))"  # unique-enough per host run

echo "===== Bare-metal VF setup on ${PF_IFACE} ====="

# ---- 1. Confirm SR-IOV capability exists on this PF ----
# (sriov_totalvfs > 0 means firmware has SR-IOV enabled for this port;
#  we already fought through this on both test hosts, so this should pass.)
TOTAL=$(cat /sys/class/net/${PF_IFACE}/device/sriov_totalvfs 2>/dev/null || echo 0)
if [[ "${TOTAL}" -eq 0 ]]; then
    echo "ERROR: ${PF_IFACE} reports sriov_totalvfs=0. SR-IOV not available on this port."
    exit 1
fi
echo "  sriov_totalvfs=${TOTAL} on ${PF_IFACE}"

# ---- 2. Enable exactly 1 VF ----
# Only ONE VF, on ONE port - this is the config we already proved works
# on both hosts. Do not try to also enable the second port here.
CURRENT=$(cat /sys/class/net/${PF_IFACE}/device/sriov_numvfs)
if [[ "${CURRENT}" -lt 1 ]]; then
    echo 1 | sudo tee /sys/class/net/${PF_IFACE}/device/sriov_numvfs
fi
echo "  sriov_numvfs=$(cat /sys/class/net/${PF_IFACE}/device/sriov_numvfs)"

# ---- 3. Set a known VF MAC (predictable, easier to identify in `ip a`/dmesg) ----
sudo ip link set ${PF_IFACE} vf ${VF_INDEX} mac ${VF_MAC} trust on spoofchk off
ip link show ${PF_IFACE} | grep -A1 "vf ${VF_INDEX}"

# ---- 4. Find the VF's netdev name (kernel auto-names it, e.g. enp1s0f0v0) ----
# The VF appears as its own /sys/class/net/* entry once enabled - find it by
# matching back to the PF's virtfn0 symlink target.
VF_PCI=$(basename "$(readlink -f /sys/class/net/${PF_IFACE}/device/virtfn${VF_INDEX})")
VF_IFACE=$(basename /sys/bus/pci/devices/${VF_PCI}/net/*)
echo "  VF PCI: ${VF_PCI}  ->  VF netdev: ${VF_IFACE}"

# ---- 5. Assign the static IP directly to the VF interface ----
# No bridge, no tap, no vhost - this VF IS the host's IP endpoint for this test.
sudo ip addr flush dev ${VF_IFACE}
sudo ip addr add ${VF_IP}/${VF_PREFIX} dev ${VF_IFACE}
sudo ip link set ${VF_IFACE} up

# ---- 6. Confirm link and driver ----
ethtool -i ${VF_IFACE} | grep driver
ethtool ${VF_IFACE} | grep -i "link detected\|speed" || true

echo
echo "Done."
echo "  VF interface : ${VF_IFACE}"
echo "  VF IP        : ${VF_IP}/${VF_PREFIX}"
echo "  Test from the OTHER host with:  ping -c3 ${VF_IP}"
