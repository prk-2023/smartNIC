#!/usr/bin/env bash
# t2_host_reset.sh — full reverse of t2_host_setup.sh (OVS version). Removes the OVS
# bridges/ports/taps, restores PF0/PF1 to plain unbridged kernel netdevs, frees hugepages.

set -uo pipefail
source "$(dirname "$0")/t2_config.sh"

echo "===== t2 host reset (OpenVSwitch) ====="

### ---- 1. Kill any running t2 VMs first ----
echo "[1/4] Stopping any running t2 VMs"
for PID_FILE in /tmp/qemu-t2_vm*.pid; do
    [[ -f "$PID_FILE" ]] || continue
    PID=$(cat "$PID_FILE")
    if kill -0 "$PID" 2>/dev/null; then
        echo "  Stopping qemu PID $PID ($PID_FILE)"
        kill "$PID"
        sleep 2
        kill -0 "$PID" 2>/dev/null && kill -9 "$PID"
    fi
    rm -f "$PID_FILE"
done

### ---- 2. Tear down OVS bridges (PF0/PF1 return to plain, unbridged netdevs) ----
echo "[2/4] Tearing down OVS bridges ${BR_LEFT} / ${BR_RIGHT}"
if command -v ovs-vsctl >/dev/null 2>&1; then
    sudo ovs-vsctl --if-exists del-br "${BR_LEFT}"
    sudo ovs-vsctl --if-exists del-br "${BR_RIGHT}"
    echo "  done"
else
    echo "  ovs-vsctl not found - nothing to tear down via OVS"
fi

for TAP in "${TAP_LEFT}" "${TAP_RIGHT}"; do
    sudo ip link set "$TAP" down 2>/dev/null || true
    sudo ip tuntap del dev "$TAP" mode tap 2>/dev/null || true
done

for PF in "${PF0}" "${PF1}"; do
    sudo ip link set "$PF" up 2>/dev/null || true
done

### ---- 3. Free hugepages ----
echo "[3/4] Freeing hugepages (setting nr_hugepages back to 0)"
sudo sysctl -w vm.nr_hugepages=0 >/dev/null
echo "  done"

### ---- 4. Confirm PFs are back to a clean state ----
echo "[4/4] Confirming ${PF0}/${PF1} are plain, unbridged, no IP"
sleep 1
ip -br link show "${PF0}" "${PF1}" 2>/dev/null || echo "  WARNING: one or both PFs not showing - check 'ip -br link'"
sudo ovs-vsctl show 2>/dev/null | grep -q "Bridge ${BR_LEFT}\|Bridge ${BR_RIGHT}" \
    && echo "  WARNING: an OVS bridge is still present - check 'sudo ovs-vsctl show'" \
    || echo "  OK: no leftover OVS bridges"

echo
echo "Done."
echo "  NOT reset (generally harmless to leave, revert manually if needed):"
echo "    - CPU governor (still 'performance')"
echo "    - CPU idle states (deep C-states still disabled)"
echo "    - KSM (still off)"
echo "    - THP (still madvise)"
echo "    - irqbalance (still stopped/disabled)"
echo "    - NIC offload settings on ${PF0}/${PF1} (still tx/rx/TSO/GRO on)"
echo "    - promiscuous mode on ${PF0}/${PF1} (harmless to leave on)"
echo "    - openvswitch-switch service (still running - harmless to leave active)"
echo "    - any bootloader cmdline changes from t2_perf_apply.sh (reboot to fully revert)"
