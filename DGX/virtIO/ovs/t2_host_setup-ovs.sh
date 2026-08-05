#!/usr/bin/env bash
# t2_host_setup.sh — prepares the DGX host for the t2 (VM<->VM virtio) test using
# OpenVSwitch (kernel datapath, NOT DPDK yet) instead of a plain Linux bridge:
#   br-left  (OVS bridge: PF0 + vnet0) and br-right (OVS bridge: PF1 + vnet1)
#
# Why OVS instead of a Linux bridge: plain Linux bridging between PF0/PF1 was confirmed
# non-functional on this hardware (see NVIDIA forum reference - ConnectX-6/7 has no
# hardware-only PF<->PF forwarding path; everything goes through host datapath). This
# swaps the bridge backend to OVS's kernel datapath as an intermediate step before
# OVS-DPDK - same taps/vhost-net/QEMU config as before, only the bridge implementation
# changes. other_config:dpdk-init is deliberately left unset here (kernel datapath only,
# not yet DPDK) - that's the next phase.
#
# Management/internet/SSH for both VMs still uses QEMU's built-in SLIRP networking
# (configured in t2_launch_vm.sh) - unaffected by this change.
#
# Run t2_perf_apply.sh BEFORE this for best results (not required, but recommended).

set -euo pipefail
source "$(dirname "$0")/t2_config.sh"

echo "===== t2 host setup (OpenVSwitch, kernel datapath) ====="

### ---- 0. Ensure OVS is running ----
echo "[0/5] Ensuring openvswitch-switch is running"
sudo systemctl enable --now openvswitch-switch >/dev/null
sudo systemctl is-active --quiet openvswitch-switch \
    && echo "  OK: openvswitch-switch active" \
    || { echo "  ERROR: openvswitch-switch not active - check 'systemctl status openvswitch-switch'"; exit 1; }

# Explicitly confirm we're on kernel datapath, not DPDK, for this phase.
DPDK_INIT=$(sudo ovs-vsctl get Open_vSwitch . other_config:dpdk-init 2>/dev/null || echo '"false"')
echo "  dpdk-init: ${DPDK_INIT} (expect false/unset for this kernel-datapath phase)"

### ---- 1. br-left: OVS bridge with PF0 + vnet0 ----
echo "[1/5] Creating OVS bridge ${BR_LEFT} (${PF0} + ${TAP_LEFT})"
sudo ovs-vsctl --may-exist add-br "${BR_LEFT}"
sudo ovs-vsctl set bridge "${BR_LEFT}" stp_enable=false

sudo ip addr flush dev "${PF0}"
sudo ip link set "${PF0}" up
sudo ovs-vsctl --may-exist add-port "${BR_LEFT}" "${PF0}"

if ! ip link show "${TAP_LEFT}" &>/dev/null; then
    sudo ip tuntap add dev "${TAP_LEFT}" mode tap multi_queue user "${TAP_USER}"
fi
sudo ip link set "${TAP_LEFT}" up
sudo ovs-vsctl --may-exist add-port "${BR_LEFT}" "${TAP_LEFT}"

### ---- 2. br-right: OVS bridge with PF1 + vnet1 ----
echo "[2/5] Creating OVS bridge ${BR_RIGHT} (${PF1} + ${TAP_RIGHT})"
sudo ovs-vsctl --may-exist add-br "${BR_RIGHT}"
sudo ovs-vsctl set bridge "${BR_RIGHT}" stp_enable=false

sudo ip addr flush dev "${PF1}"
sudo ip link set "${PF1}" up
sudo ovs-vsctl --may-exist add-port "${BR_RIGHT}" "${PF1}"

if ! ip link show "${TAP_RIGHT}" &>/dev/null; then
    sudo ip tuntap add dev "${TAP_RIGHT}" mode tap multi_queue user "${TAP_USER}"
fi
sudo ip link set "${TAP_RIGHT}" up
sudo ovs-vsctl --may-exist add-port "${BR_RIGHT}" "${TAP_RIGHT}"

### ---- 3. Promiscuous mode (harmless to keep; not the earlier fix but doesn't hurt) ----
echo "[3/5] Ensuring promiscuous mode on ${PF0}/${PF1}"
sudo ip link set "${PF0}" promisc on
sudo ip link set "${PF1}" promisc on

### ---- 4. Bridge netfilter off (ruled out as the earlier root cause, but cheap and harmless to keep) ----
echo "[4/5] Disabling bridge-nf-call-iptables if br_netfilter is loaded"
if lsmod | grep -q br_netfilter; then
    for KNOB in bridge-nf-call-iptables bridge-nf-call-ip6tables bridge-nf-call-arptables; do
        [[ -f "/proc/sys/net/bridge/${KNOB}" ]] && sudo sysctl -w "net.bridge.${KNOB}=0" >/dev/null
    done
    echo "  done"
else
    echo "  br_netfilter not loaded, skipping"
fi

### ---- 5. Sanity checks ----
echo "[5/5] Sanity checks"
echo "  --- ovs-vsctl show ---"
sudo ovs-vsctl show
for CHECK in "${PF0}:${BR_LEFT}" "${TAP_LEFT}:${BR_LEFT}" "${PF1}:${BR_RIGHT}" "${TAP_RIGHT}:${BR_RIGHT}"; do
    DEV="${CHECK%%:*}"; BR="${CHECK##*:}"
    sudo ovs-vsctl list-ports "${BR}" | grep -qx "${DEV}" \
        && echo "  OK: ${DEV} is a port on ${BR}" \
        || { echo "  ERROR: ${DEV} not found on ${BR}"; exit 1; }
done
lsmod | grep -q vhost_net || sudo modprobe vhost_net
[[ -e /dev/vhost-net ]] && echo "  OK: /dev/vhost-net present" || echo "  WARNING: /dev/vhost-net missing"

echo
echo "Done."
echo "  ${BR_LEFT}  (OVS): ${PF0} + ${TAP_LEFT} (VM1 test path)"
echo "  ${BR_RIGHT} (OVS): ${PF1} + ${TAP_RIGHT} (VM2 test path)"
echo "  Mgmt/internet/SSH: handled per-VM by QEMU SLIRP in t2_launch_vm.sh - unaffected by this change"
echo
echo "Next: t2_build_guest_image.sh / t2_launch_vm.sh are unchanged - reuse existing images if"
echo "      you already built them, or rebuild if starting fresh. Then retest the VM1<->VM2 ping."
