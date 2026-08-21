#!/usr/bin/env bash
# t2_host_setup-sriov_legacy.sh — Prepares host for SR-IOV Legacy Mode VM passthrough

set -euo pipefail
source "$(dirname "$0")/t2_config.sh"

echo "===== Host Setup: SR-IOV eSwitch Legacy Mode ====="

# 1. Load vfio-pci driver
echo "[1/6] Loading vfio-pci kernel module..."
sudo modprobe vfio-pci

# 2. Stop OVS if running (Not needed in SR-IOV Legacy Mode)
echo "[2/6] Disabling Open vSwitch if active..."
sudo systemctl stop openvswitch-switch 2>/dev/null || true

# 3. Helper function to create VF and configure Legacy eSwitch
setup_sriov_pf() {
    local PF="$1"
    local MAC="$2"
    
    echo "  Configuring ${PF}..."
    sudo ip link set "${PF}" up

    # Get PF PCI Address (e.g. 0000:01:00.0)
    local PF_BDF
    PF_BDF=$(basename "$(readlink -f "/sys/class/net/${PF}/device")")

    # Reset VFs first
    echo 0 | sudo tee "/sys/class/net/${PF}/device/sriov_numvfs" >/dev/null

    # Ensure eSwitch is in Legacy mode
    echo "  Setting eSwitch mode to legacy on ${PF_BDF}..."
    sudo devlink dev eswitch set "pci/${PF_BDF}" mode legacy 2>/dev/null || true

    # Allocate 1 VF
    echo 1 | sudo tee "/sys/class/net/${PF}/device/sriov_numvfs" >/dev/null
    sleep 1

    # Set Hardware MAC, Trust Mode, and Disable Spoof Checking on host
    echo "  Setting VF 0 MAC ${MAC}, trust=on, spoofchk=off..."
    sudo ip link set "${PF}" vf 0 mac "${MAC}" trust on spoofchk off

    # Find VF PCI BDF
    local VF_BDF
    VF_BDF=$(basename "$(readlink -f "/sys/class/net/${PF}/device/virtfn0")")
    echo "  Allocated VF 0 BDF: ${VF_BDF}"

    # Unbind VF from host mlx5_core and bind to vfio-pci
    if [[ -d "/sys/bus/pci/drivers/mlx5_core/${VF_BDF}" ]]; then
        echo "  Unbinding ${VF_BDF} from host mlx5_core..."
        echo "${VF_BDF}" | sudo tee /sys/bus/pci/drivers/mlx5_core/unbind >/dev/null
    fi

    echo "  Binding ${VF_BDF} to vfio-pci..."
    echo "vfio-pci" | sudo tee "/sys/bus/pci/devices/${VF_BDF}/driver_override" >/dev/null
    echo "${VF_BDF}" | sudo tee /sys/bus/pci/drivers_probe >/dev/null

    # Save VF BDF for VM Launch script
    echo "${VF_BDF}" > "/tmp/t2_vf_bdf_${PF}.txt"
}

echo "[3/6] Setting up SR-IOV on ${PF0} (VM1 Path)..."
setup_sriov_pf "${PF0}" "${VM1_TEST_MAC}"

echo "[4/6] Setting up SR-IOV on ${PF1} (VM2 Path)..."
setup_sriov_pf "${PF1}" "${VM2_TEST_MAC}"

# 5. Allocate Hugepages
echo "[5/6] Allocating Hugepages..."
sudo sysctl -w vm.nr_hugepages=${TOTAL_HUGEPAGES} >/dev/null
mountpoint -q /dev/hugepages || sudo mount -t hugetlbfs hugetlbfs /dev/hugepages

echo "[6/6] Sanity Checks..."
echo "VF BDF for ${PF0}: $(cat /tmp/t2_vf_bdf_${PF0}.txt)"
echo "VF BDF for ${PF1}: $(cat /tmp/t2_vf_bdf_${PF1}.txt)"
ls -l /sys/bus/pci/drivers/vfio-pci/ | grep -E "$(cat /tmp/t2_vf_bdf_${PF0}.txt)|$(cat /tmp/t2_vf_bdf_${PF1}.txt)"

echo
echo "Host setup complete for SR-IOV Legacy Mode."
