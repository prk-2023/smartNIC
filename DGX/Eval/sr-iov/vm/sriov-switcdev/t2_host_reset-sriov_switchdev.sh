#!/usr/bin/env bash
# t2_host_reset-sriov_switchdev.sh — Tears down VMs, TC rules, OVS bridges, and resets devlink mode to legacy

set -uo pipefail
source "$(dirname "$0")/t2_config_switchdev.sh"

echo "=========================================================="
echo " Host Reset: SR-IOV Switchdev Mode Cleanup"
echo "=========================================================="

# 1. Stop QEMU processes
echo "[1/4] Terminating QEMU VM instances..."
for PID_FILE in /tmp/qemu-t2_vm*.pid; do
    [[ -f "$PID_FILE" ]] || continue
    PID=$(cat "$PID_FILE")
    if kill -0 "$PID" 2>/dev/null; then
        echo "  Stopping QEMU process PID ${PID} (${PID_FILE})..."
        kill "$PID" 2>/dev/null || true
        sleep 2
        kill -0 "$PID" 2>/dev/null && kill -9 "$PID" 2>/dev/null || true
    fi
    rm -f "$PID_FILE"
done

# 2. Cleanup OVS Bridges & TC Rules
echo "[2/4] Removing OVS Bridges and TC Flower Rules..."
sudo ovs-vsctl --if-exists del-br br-left 2>/dev/null || true
sudo ovs-vsctl --if-exists del-br br-right 2>/dev/null || true

for PF in "${PF0}" "${PF1}"; do
    sudo tc qdisc del dev "${PF}" ingress 2>/dev/null || true
    if [[ -f "/tmp/t2_rep_${PF}.txt" ]]; then
        REP=$(cat "/tmp/t2_rep_${PF}.txt")
        sudo tc qdisc del dev "${REP}" ingress 2>/dev/null || true
    fi
done

# 3. Reset eSwitch devlink mode to legacy and destroy VFs
echo "[3/4] Resetting devlink eSwitch mode to legacy and destroying VFs..."
for PF in "${PF0}" "${PF1}"; do
    if ip link show "${PF}" &>/dev/null; then
        PF_BDF=$(basename "$(readlink -f "/sys/class/net/${PF}/device")" 2>/dev/null || true)
        if [[ -n "${PF_BDF}" ]]; then
            echo 0 | sudo tee "/sys/class/net/${PF}/device/sriov_numvfs" >/dev/null 2>&1 || true
            sudo devlink dev eswitch set "pci/${PF_BDF}" mode legacy 2>/dev/null || true
            echo "  Reset port ${PF} (${PF_BDF}) to legacy mode."
        fi
    fi
done
rm -f /tmp/t2_vf_bdf_*.txt /tmp/t2_rep_*.txt

# 4. Release Hugepages
echo "[4/4] Releasing hugepages..."
sudo sysctl -w vm.nr_hugepages=0 >/dev/null

echo "=========================================================="
echo " Host Reset Complete."
echo "=========================================================="
