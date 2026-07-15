#!/bin/bash
set -euo pipefail

# ============================================================================
# teardown_ovs_dpdk.sh
#
# Cleans up the test environment by stopping the QEMU virtual machines,
# removing the DPDK bridges to halt PMD busy-polling, destroying the 
# management tap interfaces, and stopping the openvswitch service.
# ============================================================================

VM_NAMES=("vm1" "vm2")
MGMT_BRIDGE="br-mgmt"
MGMT_TAPS=("tap-mgmt1" "tap-mgmt2")

echo "===== Tearing down OVS-DPDK Benchmark Environment ====="

# ---- 1. Stop Virtual Machines ----
echo "[1/5] Stopping QEMU virtual machines..."
for VM in "${VM_NAMES[@]}"; do
    PID_FILE="/tmp/qemu-${VM}.pid"
    if [[ -f "${PID_FILE}" ]]; then
        QEMU_PID=$(cat "${PID_FILE}")
        if kill -0 "${QEMU_PID}" 2>/dev/null; then
            echo "  Killing ${VM} (PID: ${QEMU_PID})..."
            sudo kill -15 "${QEMU_PID}"
            
            # Wait up to 10 seconds for graceful shutdown
            for i in {1..10}; do
                if ! kill -0 "${QEMU_PID}" 2>/dev/null; then break; fi
                sleep 1
            done
            
            # Force kill if still running
            kill -0 "${QEMU_PID}" 2>/dev/null && sudo kill -9 "${QEMU_PID}"
        fi
        rm -f "${PID_FILE}"
    else
        echo "  ${VM} does not appear to be running (no PID file)."
    fi
    # Clean up monitor sockets
    rm -f "/tmp/qemu-monitor-${VM}.sock"
done

# ---- 2. Destroy OVS DPDK Bridges ----
# CRITICAL STEP: Deleting the bridges releases the physical NIC rings and 
# internal vhost ports from the PMD thread loop, stopping the 100% CPU utilization.
echo "[2/5] Destroying OVS bridges to release pinned PMD cores..."
if systemctl is-active openvswitch &>/dev/null; then
    for BR in br-left br-right; do
        if sudo ovs-vsctl br-exists "${BR}" 2>/dev/null; then
            echo "  Removing ${BR}..."
            sudo ovs-vsctl del-br "${BR}"
        fi
    done
else
    echo "  Open vSwitch is not running; skipping bridge deletion."
fi

# ---- 3. Stop Open vSwitch Services ----
echo "[3/5] Stopping openvswitch system service..."
sudo systemctl stop openvswitch
sudo systemctl disable openvswitch --now 2>/dev/null || true

# ---- 4. Clean up Linux Management Bridge & Taps ----
echo "[4/5] Cleaning up pure-software management interfaces..."
for TAP in "${MGMT_TAPS[@]}"; do
    if ip link show "${TAP}" &>/dev/null; then
        echo "  Deleting tap interface ${TAP}..."
        sudo ip link set "${TAP}" down
        sudo ip tuntap del dev "${TAP}" mode tap
    fi
done

if ip link show "${MGMT_BRIDGE}" &>/dev/null; then
    echo "  Deleting management bridge ${MGMT_BRIDGE}..."
    sudo ip link set "${MGMT_BRIDGE}" down
    sudo ip link del "${MGMT_BRIDGE}" type bridge
fi

# ---- 5. Clear Shared Socket Directory ----
echo "[5/5] Cleaning up remaining runtime directories..."
sudo rm -rf /tmp/ovs-vhost

echo
echo "===== SUCCESS ====="
echo "All benchmark VMs stopped, OVS services deactivated, and PMD cores released."
echo "Host CPU utilization should now return to normal baseline idle percentages."
