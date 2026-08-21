#!/usr/bin/env bash
# t2_host_reset-sriov_legacy.sh — Tears down SR-IOV VFs and resets physical interfaces

set -uo pipefail
source "$(dirname "$0")/t2_config.sh"

echo "===== Host Reset: SR-IOV eSwitch Legacy Mode ====="

# 1. Stop QEMU VMs
echo "[1/3] Terminating QEMU VM processes..."
for PID_FILE in /tmp/qemu-t2_vm*.pid; do
    [[ -f "$PID_FILE" ]] || continue
    PID=$(cat "$PID_FILE")
    if kill -0 "$PID" 2>/dev/null; then
        echo "  Stopping qemu PID $PID ($PID_FILE)"
        kill "$PID" 2>/dev/null || true
        sleep 2
        kill -0 "$PID" 2>/dev/null && kill -9 "$PID" 2>/dev/null || true
    fi
    rm -f "$PID_FILE"
done

# 2. Destroy VFs on PFs
echo "[2/3] Destroying SR-IOV Virtual Functions..."
for PF in "${PF0}" "${PF1}"; do
    if [[ -e "/sys/class/net/${PF}/device/sriov_numvfs" ]]; then
        echo 0 | sudo tee "/sys/class/net/${PF}/device/sriov_numvfs" >/dev/null
        echo "  VFs destroyed on ${PF}"
    fi
    sudo ip link set "${PF}" up 2>/dev/null || true
done
rm -f /tmp/t2_vf_bdf_*.txt

# 3. Release Hugepages
echo "[3/3] Releasing hugepages..."
sudo sysctl -w vm.nr_hugepages=0 >/dev/null

echo "Host reset complete."
