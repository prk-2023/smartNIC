#!/usr/bin/env bash
# t2_host_setup.sh — prepares the DGX host for the t2 (VM<->VM virtio) test:
#   br-left  (PF0 + vnet0) and br-right (PF1 + vnet1) — the test-path bridges
#
# Management/internet/SSH for both VMs uses QEMU's built-in SLIRP networking (configured
# in t2_launch_vm.sh) instead of a host bridge — nothing to set up here for it.
#
# Run t2_perf_apply.sh BEFORE this for best results (not required, but recommended).

set -euo pipefail
source "$(dirname "$0")/t2_config.sh"

echo "===== t2 host setup ====="

### ---- 1. Test-path bridges: br-left (PF0+vnet0), br-right (PF1+vnet1) ----
echo "[1/5] Creating ${BR_LEFT} (${PF0} + ${TAP_LEFT})"
if ! ip link show "${BR_LEFT}" &>/dev/null; then
    sudo ip link add "${BR_LEFT}" type bridge
    sudo ip link set "${BR_LEFT}" type bridge stp_state 0
else
    echo "  ${BR_LEFT} already exists, skipping creation"
fi
sudo ip link set "${PF0}" master "${BR_LEFT}"
sudo ip addr flush dev "${PF0}"
sudo ip link set "${PF0}" up
sudo ip link set "${BR_LEFT}" up

if ! ip link show "${TAP_LEFT}" &>/dev/null; then
    sudo ip tuntap add dev "${TAP_LEFT}" mode tap multi_queue user "${TAP_USER}"
fi
sudo ip link set "${TAP_LEFT}" master "${BR_LEFT}"
sudo ip link set "${TAP_LEFT}" up

echo "[2/5] Creating ${BR_RIGHT} (${PF1} + ${TAP_RIGHT})"
if ! ip link show "${BR_RIGHT}" &>/dev/null; then
    sudo ip link add "${BR_RIGHT}" type bridge
    sudo ip link set "${BR_RIGHT}" type bridge stp_state 0
else
    echo "  ${BR_RIGHT} already exists, skipping creation"
fi
sudo ip link set "${PF1}" master "${BR_RIGHT}"
sudo ip addr flush dev "${PF1}"
sudo ip link set "${PF1}" up
sudo ip link set "${BR_RIGHT}" up

if ! ip link show "${TAP_RIGHT}" &>/dev/null; then
    sudo ip tuntap add dev "${TAP_RIGHT}" mode tap multi_queue user "${TAP_USER}"
fi
sudo ip link set "${TAP_RIGHT}" master "${BR_RIGHT}"
sudo ip link set "${TAP_RIGHT}" up

### ---- 3. Bridge netfilter off — CRITICAL for VM<->VM bridged traffic ----
# If br_netfilter is loaded (podman commonly loads it) and bridge-nf-call-iptables=1
# (a common default), bridged L2 frames between br-left and br-right get passed through
# the iptables FORWARD chain as if they were routed traffic - and can be silently
# dropped by whatever FORWARD policy/rules already exist (e.g. from podman/docker),
# even though the bridges themselves are structurally correct. This is very likely the
# actual cause if VM1<->VM2 ping fails despite both having correct manually-verified IPs.
echo "[3/5] Disabling bridge-nf-call-iptables (and ip6tables/arptables) so bridged frames"
echo "      aren't filtered by iptables FORWARD rules"
if lsmod | grep -q br_netfilter; then
    echo "  br_netfilter is loaded - this fix is likely necessary, not just precautionary"
else
    echo "  br_netfilter not currently loaded - applying anyway in case something loads it later"
    sudo modprobe br_netfilter 2>/dev/null || true
fi
for KNOB in bridge-nf-call-iptables bridge-nf-call-ip6tables bridge-nf-call-arptables; do
    if [[ -f "/proc/sys/net/bridge/${KNOB}" ]]; then
        BEFORE=$(cat "/proc/sys/net/bridge/${KNOB}")
        sudo sysctl -w "net.bridge.${KNOB}=0" >/dev/null
        echo "  ${KNOB}: ${BEFORE} -> 0"
    fi
done
echo "net.bridge.bridge-nf-call-iptables=0
net.bridge.bridge-nf-call-ip6tables=0
net.bridge.bridge-nf-call-arptables=0" | sudo tee /etc/sysctl.d/99-t2-bridge-nf.conf >/dev/null
echo "  persisted to /etc/sysctl.d/99-t2-bridge-nf.conf"

### ---- 4. Force promiscuous mode on both PFs ----
# Enslaving to a bridge is supposed to auto-enable this, but it doesn't reliably happen
# with every NIC/driver. Without it: broadcast frames (ARP) are always received
# regardless, but unicast frames addressed to a VM's virtio MAC (not the PF's own MAC)
# get filtered out by the NIC's hardware RX filter before ever reaching bridge software -
# ARP resolves fine, but actual unicast traffic (ICMP, TCP, UDP) silently goes nowhere.
echo "[4/5] Forcing promiscuous mode on ${PF0}/${PF1}"
sudo ip link set "${PF0}" promisc on
sudo ip link set "${PF1}" promisc on
for IFACE in "${PF0}" "${PF1}"; do
    ip -d link show "$IFACE" | grep -qi PROMISC \
        && echo "  OK: ${IFACE} promiscuous" \
        || echo "  WARNING: ${IFACE} promisc flag not confirmed - check 'ip -d link show ${IFACE}'"
done

### ---- 5. Sanity checks ----
echo "[5/5] Sanity checks"
for CHECK in "${TAP_LEFT}:${BR_LEFT}" "${PF0}:${BR_LEFT}" "${TAP_RIGHT}:${BR_RIGHT}" "${PF1}:${BR_RIGHT}"; do
    DEV="${CHECK%%:*}"; BR="${CHECK##*:}"
    bridge link show "$DEV" 2>/dev/null | grep -q "master ${BR}" \
        && echo "  OK: ${DEV} enslaved to ${BR}" \
        || { echo "  ERROR: ${DEV} not enslaved to ${BR}"; exit 1; }
done
lsmod | grep -q vhost_net || sudo modprobe vhost_net
[[ -e /dev/vhost-net ]] && echo "  OK: /dev/vhost-net present" || echo "  WARNING: /dev/vhost-net missing"
echo "  bridge-nf-call-iptables now: $(cat /proc/sys/net/bridge/bridge-nf-call-iptables 2>/dev/null || echo unknown)"

echo
echo "Done."
echo "  ${BR_LEFT}  : ${PF0} + ${TAP_LEFT} (VM1 test path)"
echo "  ${BR_RIGHT} : ${PF1} + ${TAP_RIGHT} (VM2 test path)"
echo "  Mgmt/internet/SSH: handled per-VM by QEMU SLIRP in t2_launch_vm.sh - nothing to check here"
echo
echo "Next: run t2_build_guest_image.sh 1   then   t2_build_guest_image.sh 2"
