#!/usr/bin/env bash
# t2_host_setup-sriov_switchdev.sh — Prepares host for SR-IOV Switchdev mode (OVS HW-offload or TC Flower)

set -euo pipefail
source "$(dirname "$0")/t2_config_switchdev.sh"

STEERING_MODE="ovs"

# Parse arguments
while [[ $# -gt 0 ]]; do
  case "$1" in
    --mode)
      STEERING_MODE="$2"
      shift 2
      ;;
    *)
      echo "Unknown argument: $1"
      echo "Usage: $0 [--mode ovs|tc]"
      exit 1
      ;;
  esac
done

if [[ "$STEERING_MODE" != "ovs" && "$STEERING_MODE" != "tc" ]]; then
    echo "ERROR: Invalid mode '${STEERING_MODE}'. Choose 'ovs' or 'tc'."
    exit 1
fi

echo "=========================================================="
echo " Host Setup: SR-IOV Switchdev Mode [Mode: ${STEERING_MODE^^}] (MTU ${MTU})"
echo "=========================================================="

# 1. Load vfio-pci and IOMMU modules
echo "[1/7] Loading vfio-pci driver and IOMMU kernel modules..."
sudo modprobe vfio
sudo modprobe vfio-pci
sudo modprobe vfio_iommu_type1 2>/dev/null || true

# 2. Configure OVS Service according to selected mode
if [[ "${STEERING_MODE}" == "ovs" ]]; then
    echo "[2/7] Initializing Open vSwitch with Hardware Offload enabled..."
    sudo systemctl start openvswitch-switch 2>/dev/null || sudo systemctl start ovs-vswitchd 2>/dev/null || true
    sudo ovs-vsctl set Open_vSwitch . other_config:hw-offload=true
    sudo systemctl restart openvswitch-switch 2>/dev/null || sudo systemctl restart ovs-vswitchd 2>/dev/null || true
else
    echo "[2/7] Stopping Open vSwitch for pure TC Flower offload mode..."
    sudo systemctl stop openvswitch-switch 2>/dev/null || sudo systemctl stop ovs-vswitchd 2>/dev/null || true
fi

# 3. Helper function to find VF Representor interface name
get_vf_representor() {
    local PF="$1"
    local PF_BDF="$2"
    local REP=""

    # Try searching by phys_port_name or netlink naming conventions
    for dev in /sys/class/net/*; do
        dev_name=$(basename "$dev")
        if [[ -e "$dev/device" ]]; then
            dev_bdf=$(basename "$(readlink -f "$dev/device")" 2>/dev/null || true)
            if [[ "$dev_bdf" == "$PF_BDF" && "$dev_name" != "$PF" ]]; then
                # Check for representor port name markers
                if [[ -e "$dev/phys_port_name" ]]; then
                    port_name=$(cat "$dev/phys_port_name" 2>/dev/null || true)
                    if [[ "$port_name" =~ pf[0-9]+vf0|v0|0 ]]; then
                        REP="$dev_name"
                        break
                    fi
                fi
            fi
        fi
    done

    # Fallback pattern match
    if [[ -z "$REP" ]]; then
        REP=$(ip -o link show | grep -E "${PF}v0|${PF}_0|pf0vf0" | awk -F': ' '{print $2}' | head -n1 || true)
    fi

    echo "$REP"
}

# 4. Helper function to setup SR-IOV Switchdev on PF
setup_switchdev_pf() {
    local PF="$1"
    local MAC="$2"

    echo "----------------------------------------------------"
    echo "Configuring Physical Port: ${PF} with MTU ${MTU}"

    if ! ip link show "${PF}" &>/dev/null; then
        echo "ERROR: Interface ${PF} not found on system!"
        exit 1
    fi

    # Set PF MTU and bring link UP
    sudo ip link set "${PF}" mtu "${MTU}" up

    # Get PF PCI Address
    local PF_BDF
    PF_BDF=$(basename "$(readlink -f "/sys/class/net/${PF}/device")")
    echo "  PF PCI Address: ${PF_BDF}"

    # Reset existing VFs and unbind them
    echo "  Resetting existing VFs..."
    echo 0 | sudo tee "/sys/class/net/${PF}/device/sriov_numvfs" >/dev/null

    # Transition eSwitch mode to switchdev
    echo "  Setting devlink eSwitch mode to switchdev..."
    sudo devlink dev eswitch set "pci/${PF_BDF}" mode switchdev

    # Instantiate 1 VF
    echo "  Creating 1 Virtual Function..."
    echo 1 | sudo tee "/sys/class/net/${PF}/device/sriov_numvfs" >/dev/null
    sleep 2

    # Set MAC and Trust mode on VF 0
    sudo ip link set "${PF}" vf 0 mac "${MAC}" trust on spoofchk off 2>/dev/null || true

    # Identify Allocated VF BDF
    local VF_BDF
    VF_BDF=$(basename "$(readlink -f "/sys/class/net/${PF}/device/virtfn0")")
    echo "  Allocated VF 0 BDF: ${VF_BDF}"

    # Discover VF Representor netdev
    local REP
    REP=$(get_vf_representor "${PF}" "${PF_BDF}")
    if [[ -z "${REP}" ]]; then
        echo "ERROR: Failed to detect VF representor interface for ${PF}!"
        exit 1
    fi
    echo "  Detected VF Representor: ${REP}"

    # Set MTU 9000 on representor
    sudo ip link set "${REP}" mtu "${MTU}" up

    # Unbind VF from host mlx5_core driver and bind to vfio-pci
    if [[ -d "/sys/bus/pci/drivers/mlx5_core/${VF_BDF}" ]]; then
        echo "  Unbinding ${VF_BDF} from host mlx5_core..."
        echo "${VF_BDF}" | sudo tee /sys/bus/pci/drivers/mlx5_core/unbind >/dev/null
    fi

    echo "  Binding ${VF_BDF} to vfio-pci..."
    echo "vfio-pci" | sudo tee "/sys/bus/pci/devices/${VF_BDF}/driver_override" >/dev/null
    echo "${VF_BDF}" | sudo tee /sys/bus/pci/drivers_probe >/dev/null

    # Store paths
    echo "${VF_BDF}" > "/tmp/t2_vf_bdf_${PF}.txt"
    echo "${REP}" > "/tmp/t2_rep_${PF}.txt"
}

echo "[3/7] Setting up SR-IOV Switchdev on ${PF0}..."
setup_switchdev_pf "${PF0}" "${VM1_TEST_MAC}"

echo "[4/7] Setting up SR-IOV Switchdev on ${PF1}..."
setup_switchdev_pf "${PF1}" "${VM2_TEST_MAC}"

REP0=$(cat "/tmp/t2_rep_${PF0}.txt")
REP1=$(cat "/tmp/t2_rep_${PF1}.txt")

# 5. Apply Datapath Steering Rules (OVS HW-Offload vs TC Flower)
if [[ "${STEERING_MODE}" == "ovs" ]]; then
    echo "[5/7] Configuring Open vSwitch Bridges with HW-Offload..."
    
    # Bridge Left (PF0 <-> REP0)
    sudo ovs-vsctl --if-exists del-br br-left
    sudo ovs-vsctl add-br br-left
    sudo ovs-vsctl add-port br-left "${PF0}"
    sudo ovs-vsctl add-port br-left "${REP0}"
    sudo ip link set br-left mtu "${MTU}" up

    # Bridge Right (PF1 <-> REP1)
    sudo ovs-vsctl --if-exists del-br br-right
    sudo ovs-vsctl add-br br-right
    sudo ovs-vsctl add-port br-right "${PF1}"
    sudo ovs-vsctl add-port br-right "${REP1}"
    sudo ip link set br-right mtu "${MTU}" up

else
    echo "[5/7] Configuring Hardware Offloaded TC Flower Redirection Rules..."
    
    # Configure TC on Left Path (PF0 <-> REP0)
    sudo tc qdisc del dev "${PF0}" ingress 2>/dev/null || true
    sudo tc qdisc del dev "${REP0}" ingress 2>/dev/null || true
    sudo tc qdisc add dev "${PF0}" ingress
    sudo tc qdisc add dev "${REP0}" ingress

    sudo tc filter add dev "${PF0}" ingress protocol all prio 1 flower action mirred egress redirect dev "${REP0}"
    sudo tc filter add dev "${REP0}" ingress protocol all prio 1 flower action mirred egress redirect dev "${PF0}"

    # Configure TC on Right Path (PF1 <-> REP1)
    sudo tc qdisc del dev "${PF1}" ingress 2>/dev/null || true
    sudo tc qdisc del dev "${REP1}" ingress 2>/dev/null || true
    sudo tc qdisc add dev "${PF1}" ingress
    sudo tc qdisc add dev "${REP1}" ingress

    sudo tc filter add dev "${PF1}" ingress protocol all prio 1 flower action mirred egress redirect dev "${REP1}"
    sudo tc filter add dev "${REP1}" ingress protocol all prio 1 flower action mirred egress redirect dev "${PF1}"
fi

# 6. Reserve Hugepages
echo "[6/7] Allocating Hugepages (${TOTAL_HUGEPAGES} pages x 2MB)..."
sudo sysctl -w vm.nr_hugepages=${TOTAL_HUGEPAGES} >/dev/null
mountpoint -q /dev/hugepages || sudo mount -t hugetlbfs hugetlbfs /dev/hugepages

# 7. Verification
echo "[7/7] Verification & Device Summary..."
VF0_BDF=$(cat "/tmp/t2_vf_bdf_${PF0}.txt")
VF1_BDF=$(cat "/tmp/t2_vf_bdf_${PF1}.txt")

echo "  VM1 VF (${PF0}): BDF=${VF0_BDF}, Representor=${REP0}"
echo "  VM2 VF (${PF1}): BDF=${VF1_BDF}, Representor=${REP1}"
echo "  Steering Mode Applied : ${STEERING_MODE^^}"

echo "=========================================================="
echo " Host Setup Complete (Switchdev Mode: ${STEERING_MODE^^}, MTU ${MTU})."
echo "=========================================================="

