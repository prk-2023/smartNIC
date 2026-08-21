#!/usr/bin/env bash
# t2_host_setup-sriov_legacy.sh — Prepares host interfaces with MTU 9000, allocates VFs, and binds VFs to vfio-pci

set -euo pipefail
source "$(dirname "$0")/t2_config.sh"

echo "=========================================================="
echo " Host Setup: SR-IOV eSwitch Legacy Mode Passthrough (MTU ${MTU})"
echo "=========================================================="

# 1. Load vfio-pci driver and iommu modules
echo "[1/6] Loading vfio-pci and IOMMU kernel modules..."
sudo modprobe vfio
sudo modprobe vfio-pci
sudo modprobe vfio_iommu_type1 2>/dev/null || true

# 2. Disable OVS service if present
echo "[2/6] Ensuring Open vSwitch is stopped..."
sudo systemctl stop openvswitch-switch 2>/dev/null || true

# 3. Helper function to set up SR-IOV Legacy Mode on PF
setup_sriov_pf() {
    local PF="$1"
    local MAC="$2"
    
    echo "----------------------------------------------------"
    echo "Configuring physical port: ${PF} with MTU ${MTU}"
    
    if ! ip link show "${PF}" &>/dev/null; then
        echo "ERROR: Interface ${PF} not found on system!"
        exit 1
    fi

    # Set host interface MTU and bring link UP
    sudo ip link set "${PF}" mtu "${MTU}" up

    # Extract PCI BDF (e.g. 0000:01:00.0)
    local PF_BDF
    PF_BDF=$(basename "$(readlink -f "/sys/class/net/${PF}/device")")
    echo "  PF PCI Address: ${PF_BDF}"

    # Reset VFs on PF
    echo "  Resetting existing VFs..."
    echo 0 | sudo tee "/sys/class/net/${PF}/device/sriov_numvfs" >/dev/null

    # Set eSwitch to Legacy mode via devlink
    echo "  Setting devlink eSwitch mode to legacy..."
    sudo devlink dev eswitch set "pci/${PF_BDF}" mode legacy 2>/dev/null || true

    # Instantiate 1 Virtual Function
    echo "  Creating 1 Virtual Function..."
    echo 1 | sudo tee "/sys/class/net/${PF}/device/sriov_numvfs" >/dev/null
    sleep 1

    # Configure VF MAC, Trust mode, and Spoof checking on PF
    echo "  Setting VF 0 properties: MAC=${MAC}, trust=on, spoofchk=off..."
    sudo ip link set "${PF}" vf 0 mac "${MAC}" trust on spoofchk off

    # Locate allocated VF PCI BDF
    local VF_BDF
    VF_BDF=$(basename "$(readlink -f "/sys/class/net/${PF}/device/virtfn0")")
    echo "  Allocated VF 0 BDF: ${VF_BDF}"

    # Unbind VF from host mlx5_core driver
    if [[ -d "/sys/bus/pci/drivers/mlx5_core/${VF_BDF}" ]]; then
        echo "  Unbinding ${VF_BDF} from host mlx5_core..."
        echo "${VF_BDF}" | sudo tee /sys/bus/pci/drivers/mlx5_core/unbind >/dev/null
    fi

    # Bind VF to vfio-pci driver for QEMU passthrough
    echo "  Binding ${VF_BDF} to vfio-pci driver..."
    echo "vfio-pci" | sudo tee "/sys/bus/pci/devices/${VF_BDF}/driver_override" >/dev/null
    echo "${VF_BDF}" | sudo tee /sys/bus/pci/drivers_probe >/dev/null

    # Store VF BDF in temporary file for QEMU launch script
    echo "${VF_BDF}" > "/tmp/t2_vf_bdf_${PF}.txt"
}

echo "[3/6] Configuring SR-IOV on ${PF0} (VM1 Path)..."
setup_sriov_pf "${PF0}" "${VM1_TEST_MAC}"

echo "[4/6] Configuring SR-IOV on ${PF1} (VM2 Path)..."
setup_sriov_pf "${PF1}" "${VM2_TEST_MAC}"

# 5. Allocate Host Hugepages
echo "[5/6] Allocating Hugepages (${TOTAL_HUGEPAGES} pages x 2MB)..."
sudo sysctl -w vm.nr_hugepages=${TOTAL_HUGEPAGES} >/dev/null
mountpoint -q /dev/hugepages || sudo mount -t hugetlbfs hugetlbfs /dev/hugepages

# 6. Verification
echo "[6/6] Sanity check bound devices..."
VF0_BDF=$(cat "/tmp/t2_vf_bdf_${PF0}.txt")
VF1_BDF=$(cat "/tmp/t2_vf_bdf_${PF1}.txt")

echo "  VM1 VF BDF (${PF0}) : ${VF0_BDF}"
echo "  VM2 VF BDF (${PF1}) : ${VF1_BDF}"

ls -l /sys/bus/pci/drivers/vfio-pci/ | grep -E "(${VF0_BDF}|${VF1_BDF})"

echo "=========================================================="
echo " Host Setup Complete for SR-IOV Legacy Mode (Jumbo Frames MTU ${MTU})."
echo "=========================================================="
