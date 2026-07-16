#!/bin/bash
set -euo pipefail

# ============================================================================
# 01-host_virtio_dualport_setup.sh
# PURE VIRTIO dual-port host setup: native Linux bridges + vhost-net only.
# No Open vSwitch, no DPDK, no hugepage PMD cores - isolates vhost-net/
# virtio-net as the only variable against the OVS-DPDK and OVS-kernel runs.
# Safe to re-run: tears down any previous state first, then rebuilds clean.
# ============================================================================

PF0="enp1s0f0np0"   # port0 -> br-left  -> VM1
PF1="enp1s0f1np1"   # port1 -> br-right -> VM2

DATA_TAP_LEFT="vnet0"    # VM1's data NIC attaches here (vhost-net)
DATA_TAP_RIGHT="vnet1"   # VM2's data NIC attaches here (vhost-net)
TAP_USER="$(whoami)"

MGMT_BRIDGE="br-mgmt"
MGMT_HOST_IP="192.168.50.1"
MGMT_PREFIX="24"
MGMT_TAP1="tap-mgmt1"
MGMT_TAP2="tap-mgmt2"

echo "===== Pure-virtio dual-port host setup (Linux bridge + vhost-net) ====="

# ---- 1. Clean slate: kill VMs, remove any previous bridges/taps, stop OVS ----
echo "[1/6] Wiping previous configuration"
sudo killall -9 qemu-system-x86_64 2>/dev/null || true
for BR in br-left br-right br-mgmt; do
    sudo ip link set "${BR}" down 2>/dev/null || true
    sudo ip link delete "${BR}" type bridge 2>/dev/null || true
done
for TAP in "${DATA_TAP_LEFT}" "${DATA_TAP_RIGHT}" "${MGMT_TAP1}" "${MGMT_TAP2}"; do
    sudo ip link set "${TAP}" down 2>/dev/null || true
    sudo ip tuntap del dev "${TAP}" mode tap 2>/dev/null || true
done
for PF in "${PF0}" "${PF1}"; do
    sudo ip link set "${PF}" nomaster 2>/dev/null || true
done
sudo systemctl stop openvswitch 2>/dev/null || true
systemctl is-active --quiet openvswitch && echo "  WARNING: openvswitch still active" || echo "  openvswitch: inactive (correct for this baseline)"

# ---- 2. vhost_net kernel module ----
echo "[2/6] Ensuring vhost_net kernel module is loaded"
sudo modprobe vhost_net
lsmod | grep -q '^vhost_net' && echo "  vhost_net: loaded" || echo "  WARNING: vhost_net not loaded - data path will fall back to slower pure userspace virtio"

# ---- 3. br-left: PF0 + VM1 data tap (plain Linux bridge, L2 only) ----
echo "[3/6] Creating br-left (port0 side, for VM1)"
sudo ip link add name br-left type bridge
sudo ip link set br-left type bridge stp_state 0
sudo ip link set ${PF0} master br-left
sudo ip link set ${PF0} up
sudo ip link set br-left up

sudo ip tuntap add dev ${DATA_TAP_LEFT} mode tap user "${TAP_USER}"
sudo ip link set ${DATA_TAP_LEFT} master br-left
sudo ip link set ${DATA_TAP_LEFT} up

# ---- 4. br-right: PF1 + VM2 data tap (plain Linux bridge, L2 only) ----
echo "[4/6] Creating br-right (port1 side, for VM2)"
sudo ip link add name br-right type bridge
sudo ip link set br-right type bridge stp_state 0
sudo ip link set ${PF1} master br-right
sudo ip link set ${PF1} up
sudo ip link set br-right up

sudo ip tuntap add dev ${DATA_TAP_RIGHT} mode tap user "${TAP_USER}"
sudo ip link set ${DATA_TAP_RIGHT} master br-right
sudo ip link set ${DATA_TAP_RIGHT} up

# ---- 5. Local management bridge (pure software, host-reachable) ----
echo "[5/6] Creating management bridge ${MGMT_BRIDGE}"
sudo ip link add ${MGMT_BRIDGE} type bridge
sudo ip link set ${MGMT_BRIDGE} type bridge stp_state 0
sudo ip addr add ${MGMT_HOST_IP}/${MGMT_PREFIX} dev ${MGMT_BRIDGE}
sudo ip link set ${MGMT_BRIDGE} up
for TAP in "${MGMT_TAP1}" "${MGMT_TAP2}"; do
    sudo ip tuntap add dev ${TAP} mode tap user "${TAP_USER}"
    sudo ip link set ${TAP} master ${MGMT_BRIDGE}
    sudo ip link set ${TAP} up
done

# ---- 6. Sanity checks ----
echo "[6/6] Sanity checks"
bridge link show
echo
systemctl is-active --quiet openvswitch && echo "OVS active: YES (unexpected!)" || echo "OVS active: no (correct)"
echo "Done. br-left/br-right are plain Linux bridges; ${DATA_TAP_LEFT}/${DATA_TAP_RIGHT} ready for vhost-net-backed VMs."
