#!/usr/bin/env bash
# t2_host_reset.sh — full reverse of t2_host_setup.sh (OVS-DPDK version). Removes the OVS
# bridges/dpdk-ports/vhost-user sockets, disables the DPDK datapath, restores PF0/PF1 to
# plain kernel netdevs, frees hugepages.

set -uo pipefail
source "$(dirname "$0")/t2_config.sh"

echo "===== t2 host reset (OVS-DPDK) ====="

### ---- 1. Kill any running t2 VMs first ----
echo "[1/5] Stopping any running t2 VMs"
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

### ---- 2. Tear down OVS bridges (also removes the dpdk/vhost-user ports on them) ----
echo "[2/5] Tearing down OVS bridges ${BR_LEFT} / ${BR_RIGHT}"
if command -v ovs-vsctl >/dev/null 2>&1; then
    sudo ovs-vsctl --if-exists del-br "${BR_LEFT}"
    sudo ovs-vsctl --if-exists del-br "${BR_RIGHT}"
    echo "  done"
else
    echo "  ovs-vsctl not found - nothing to tear down via OVS"
fi
rm -rf "${VHOST_SOCK_DIR}"

### ---- 3. Disable the DPDK datapath (PF0/PF1 return to the kernel driver as normal netdevs) ----
echo "[3/5] Disabling DPDK in OVS (this restarts openvswitch-switch)"
if command -v ovs-vsctl >/dev/null 2>&1; then
    sudo ovs-vsctl set Open_vSwitch . other_config:dpdk-init=false 2>/dev/null || true
    sudo systemctl restart openvswitch-switch 2>/dev/null || true
    echo "  done"
fi

### ---- 4. Free hugepages ----
echo "[4/5] Freeing hugepages (setting nr_hugepages back to 0)"
sudo sysctl -w vm.nr_hugepages=0 >/dev/null
echo "  done"

### ---- 5. Confirm PFs are back to a clean state ----
echo "[5/5] Confirming ${PF0}/${PF1} are visible as plain kernel netdevs again"
sleep 2
ip -br link show "${PF0}" "${PF1}" 2>/dev/null || echo "  WARNING: one or both PFs not showing - check 'ip -br link'"
echo "  (mlx5_core stays bound the whole time in this design, so PF0/PF1 should reappear"
echo "   as normal netdevs immediately once OVS-DPDK releases them - no manual rebind needed)"

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
echo "    - openvswitch-switch service (still running, now back on kernel datapath)"
echo "    - any bootloader cmdline changes from t2_perf_apply.sh (reboot to fully revert)"
