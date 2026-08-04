#!/usr/bin/env bash
# t2_host_reset.sh — full reverse of t2_host_setup.sh. Removes br-left/br-right/br-mgmt,
# taps, and NAT rules; restores PF0/PF1 to plain unbridged kernel netdevs; frees hugepages.
# Also covers the "reset host system network" ask — this is the one script for both.
# enP7s7 was never touched by setup, so there's nothing to restore for it here.

set -uo pipefail
source "$(dirname "$0")/t2_config.sh"

echo "===== t2 host reset ====="

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

### ---- 2. Tear down test-path bridges (PF0/PF1 return to plain, unbridged netdevs) ----
echo "[2/5] Tearing down ${BR_LEFT} / ${BR_RIGHT}"
for TAP in "${TAP_LEFT}" "${TAP_RIGHT}"; do
    sudo ip link set "$TAP" down 2>/dev/null || true
    sudo ip tuntap del dev "$TAP" mode tap 2>/dev/null || true
done
for BR_PF in "${BR_LEFT}:${PF0}" "${BR_RIGHT}:${PF1}"; do
    BR="${BR_PF%%:*}"; PF="${BR_PF##*:}"
    sudo ip link set "$PF" nomaster 2>/dev/null || true
    sudo ip link set "$BR" down 2>/dev/null || true
    sudo ip link delete "$BR" type bridge 2>/dev/null || true
    sudo ip link set "$PF" up 2>/dev/null || true
done

### ---- 3. Management networking: nothing to tear down ----
echo "[3/5] Management/internet/SSH used QEMU SLIRP (per-VM-process) - nothing on the"
echo "      host to clean up there; it disappears automatically when each qemu process exits."

### ---- 4. Free hugepages ----
echo "[4/5] Freeing hugepages (setting nr_hugepages back to 0)"
sudo sysctl -w vm.nr_hugepages=0 >/dev/null
echo "  done"

### ---- 5. Confirm PFs are back to a clean state ----
echo "[5/5] Confirming ${PF0}/${PF1} are plain, unbridged, no IP"
sleep 1
ip -br link show "${PF0}" "${PF1}" 2>/dev/null || echo "  WARNING: one or both PFs not showing - check 'ip -br link'"

echo
echo "Done."
echo "  NOT reset (generally harmless to leave, revert manually if needed):"
echo "    - CPU governor (still 'performance')"
echo "    - CPU idle states (deep C-states still disabled)"
echo "    - KSM (still off)"
echo "    - THP (still madvise)"
echo "    - irqbalance (still stopped/disabled)"
echo "    - NIC offload settings on ${PF0}/${PF1} (still tx/rx/TSO/GRO on)"
echo "    - any bootloader cmdline changes from t2_perf_apply.sh (reboot to fully revert)"
