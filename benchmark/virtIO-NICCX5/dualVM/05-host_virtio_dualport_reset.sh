#!/bin/bash
# ============================================================================
# 00-host_virtio_dualport_reset.sh
# Resets the host network to default after pure-virtio (Linux bridge +
# vhost-net) benchmark runs:
#   1. Terminate any running QEMU VM instances
#   2. Remove the data/mgmt bridges and tap interfaces created for the test
# Physical NICs (enp1s0f0np0 / enp1s0f1np1) are released back to their
# default, un-bridged state - nothing else on the host is touched.
# ============================================================================

PF0="enp1s0f0np0"
PF1="enp1s0f1np1"

DATA_TAP_LEFT="vnet0"
DATA_TAP_RIGHT="vnet1"
MGMT_TAP1="tap-mgmt1"
MGMT_TAP2="tap-mgmt2"

echo "===== Resetting host network to default ====="

# ---- 1. Terminate QEMU VM instances ----
echo "[1/3] Terminating QEMU instances"
# NOTE: VMs are launched with '-name guest,process=qemu-<vm_name>', which
# renames the process itself - so `killall qemu-system-x86_64` (name match)
# finds nothing. pkill -f matches the full command line instead, which still
# contains the qemu-system-x86_64 binary path regardless of that renaming.
if pgrep -f qemu-system-x86_64 >/dev/null; then
    sudo pkill -9 -f qemu-system-x86_64
    # Wait for processes to actually exit so tap fds are released before we
    # try to delete them below - otherwise ip tuntap del fails with EBUSY.
    for i in $(seq 1 10); do
        pgrep -f qemu-system-x86_64 >/dev/null || break
        sleep 0.5
    done
    if pgrep -f qemu-system-x86_64 >/dev/null; then
        echo "  WARNING: qemu process(es) still alive after SIGKILL - tap removal below may fail"
    else
        echo "  QEMU instances terminated"
    fi
else
    echo "  No QEMU instances running"
fi
rm -f /tmp/qemu-*.pid /tmp/qemu-monitor-*.sock /tmp/qemu-*-serial.log

# ---- 2. Remove bridges (br-left, br-right, br-mgmt) ----
echo "[2/3] Removing bridges"
for BR in br-left br-right br-mgmt; do
    if ip link show "${BR}" &>/dev/null; then
        sudo ip link set "${BR}" down
        sudo ip link delete "${BR}" type bridge
        echo "  removed ${BR}"
    else
        echo "  ${BR} not present, skipping"
    fi
done

# Release physical NICs back from any bridge membership (default state)
for PF in "${PF0}" "${PF1}"; do
    sudo ip link set "${PF}" nomaster 2>/dev/null || true
done

# ---- 3. Remove tap interfaces (data + mgmt) ----
echo "[3/3] Removing tap interfaces"
for TAP in "${DATA_TAP_LEFT}" "${DATA_TAP_RIGHT}" "${MGMT_TAP1}" "${MGMT_TAP2}"; do
    if ip link show "${TAP}" &>/dev/null; then
        sudo ip link set "${TAP}" down 2>/dev/null || true
        if sudo ip tuntap del dev "${TAP}" mode tap 2>/tmp/tapdel_err.$$; then
            echo "  removed ${TAP}"
        else
            echo "  WARNING: failed to remove ${TAP} - $(cat /tmp/tapdel_err.$$ | tr -d '\n')"
        fi
        rm -f /tmp/tapdel_err.$$
    else
        echo "  ${TAP} not present, skipping"
    fi
done

echo
echo "----- Verification -----"
ip -br link show dev "${PF0}"
ip -br link show dev "${PF1}"
echo
echo "Remaining bridges/taps (should be empty of br-left/br-right/br-mgmt/vnet*/tap-mgmt*):"
ip -br link show type bridge 2>/dev/null
ip -br link show type tun 2>/dev/null | grep -E "vnet|tap-mgmt" || echo "  (none)"
echo
echo "Host network reset complete."
echo "reset the terminal to normal"
tput reset
