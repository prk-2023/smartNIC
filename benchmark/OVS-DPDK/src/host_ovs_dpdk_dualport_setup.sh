#!/bin/bash
set -euo pipefail

# ============================================================================
# host_ovs_dpdk_dualport_setup.sh
#
# Uses BOTH CX-5 ports on this ONE host, each fully DPDK-driven, joined only
# by the physical DAC cable between them - kernel networking stack is
# completely out of the picture on both sides.
#
# TWO SEPARATE VMs will attach here (one per port) rather than one VM with
# two NICs - each VM does ONE job (client or server), so we don't introduce
# intra-guest CPU contention or double the vhost-user hop count per packet.
# This keeps the test shape identical to the single-port OVS-DPDK leg and
# the Native VirtIO leg: one virtualization hop per side.
#
# Reminder (same as the single-port leg): mlx5's DPDK PMD does NOT need
# vfio-pci or driver unbinding - both ports stay on mlx5_core + rdma-core
# the whole time. This is why we can do this on ONE host at all without
# hitting the ARI/PCI-bus-allocation wall we hit with SR-IOV.
#
# Two independent bridges (br-left, br-right) rather than one 4-port bridge:
# each is just a "virtual patch cable" between one physical DPDK port and
# one vhost-user port - simpler than relying on L2 learning across 4 ports
# on a single bridge, and avoids any ambiguity about which port a given
# packet should flood to.
# ============================================================================

PF0="enp1s0f0np0"; PF0_PCI="0000:01:00.0"   # port0 -> br-left -> VM1
PF1="enp1s0f1np1"; PF1_PCI="0000:01:00.1"   # port1 -> br-right -> VM2

VHOST_SOCKET_DIR="/tmp/ovs-vhost"
VHOST_PORT_LEFT="vhost-user0"    # VM1 connects here
VHOST_PORT_RIGHT="vhost-user1"   # VM2 connects here

# Two ports now being polled instead of one - give PMD threads two cores
# (0xC = binary 1100 = bits 2 and 3). Must stay disjoint from BOTH VMs'
# vCPU pin sets and from any other isolated-core usage on this host.
PMD_CPU_MASK="0xC"
DPDK_SOCKET_MEM="1024"

MGMT_BRIDGE="br-mgmt"
MGMT_HOST_IP="192.168.50.1"
MGMT_PREFIX="24"
MGMT_TAP1="tap-mgmt1"   # VM1's mgmt NIC attaches here
MGMT_TAP2="tap-mgmt2"   # VM2's mgmt NIC attaches here
TAP_USER="$(whoami)"

echo "===== Dual-port OVS-DPDK host setup ====="

# ---- 1. Install openvswitch-dpdk ----
echo "[1/8] Installing openvswitch-dpdk"
if ! rpm -q openvswitch-dpdk &>/dev/null; then
    sudo dnf swap -y openvswitch openvswitch-dpdk 2>/dev/null || sudo dnf install -y openvswitch-dpdk
fi

# ---- 2. Hugepages check ----
# Now need room for: VM1's guest RAM + VM2's guest RAM + OVS-DPDK's own
# reservation, all from the SAME hugepage pool - this adds up fast.
#
# PAGE-SIZE AWARE: earlier versions of this check hardcoded a "need >=3072
# free pages" threshold, which only makes sense for 2MB pages (3072 x 2MB =
# 6GB). Hosts commonly get reconfigured to 1GB pages for DPDK workloads
# (fewer TLB misses on the datapath), in which case there might only be
# ~12 total pages - a hardcoded 2MB-page threshold would misfire constantly.
# Compute the real requirement from whatever page size is actually mounted.
echo "[2/8] Checking hugepages"
HUGEPAGE_SIZE_KB=$(grep Hugepagesize /proc/meminfo | awk '{print $2}')   # e.g. 1048576 (1GB) or 2048 (2MB)
HUGEPAGE_SIZE_MB=$((HUGEPAGE_SIZE_KB / 1024))
VM_MEM_MB=2048          # matches MEM=2G used by launch_ovs_dpdk_vm_generic.sh, per VM
TOTAL_NEEDED_MB=$(( VM_MEM_MB * 2 + DPDK_SOCKET_MEM ))   # 2 VMs + OVS-DPDK's own reservation
NEEDED_PAGES=$(( (TOTAL_NEEDED_MB + HUGEPAGE_SIZE_MB - 1) / HUGEPAGE_SIZE_MB ))   # round up

FREE_HP=$(grep HugePages_Free /proc/meminfo | awk '{print $2}')
echo "  Hugepage size: ${HUGEPAGE_SIZE_MB} MB | Free: ${FREE_HP} | Needed total: ${NEEDED_PAGES} (2x ${VM_MEM_MB}MB VMs + ${DPDK_SOCKET_MEM}MB OVS-DPDK)"
if [[ "${FREE_HP}" -lt "${NEEDED_PAGES}" ]]; then
    echo "  WARNING: likely too few for two VMs + OVS-DPDK. Consider raising nr_hugepages, e.g.:"
    echo "    echo ${NEEDED_PAGES} | sudo tee /sys/devices/system/node/node0/hugepages/hugepages-${HUGEPAGE_SIZE_KB}kB/nr_hugepages"
fi

# ---- 3. Start OVS ----
echo "[3/8] Starting openvswitch service"
sudo systemctl enable --now openvswitch

# ---- 4. Enable DPDK ----
echo "[4/8] Enabling DPDK in OVS"
sudo ovs-vsctl --no-wait set Open_vSwitch . other_config:dpdk-init=true
sudo ovs-vsctl --no-wait set Open_vSwitch . other_config:dpdk-socket-mem="${DPDK_SOCKET_MEM}"
sudo ovs-vsctl --no-wait set Open_vSwitch . other_config:pmd-cpu-mask=${PMD_CPU_MASK}
sudo systemctl restart openvswitch
sleep 3
DPDK_STATUS=$(sudo ovs-vsctl get Open_vSwitch . dpdk_initialized 2>/dev/null || echo "unknown")
echo "  dpdk_initialized: ${DPDK_STATUS}"
[[ "${DPDK_STATUS}" == "true" ]] || { echo "  ERROR: check: sudo journalctl -u openvswitch -n 50"; exit 1; }

# ---- 5. br-left: port0 + VM1's vhost-user port ----
echo "[5/8] Creating br-left (port0 side, for VM1)"
sudo mkdir -p ${VHOST_SOCKET_DIR}
if ! sudo ovs-vsctl br-exists br-left; then
    sudo ovs-vsctl add-br br-left -- set bridge br-left datapath_type=netdev
fi
sudo ovs-vsctl list-ports br-left | grep -q '^dpdk0$' || \
    sudo ovs-vsctl add-port br-left dpdk0 -- set Interface dpdk0 type=dpdk options:dpdk-devargs=${PF0_PCI}
sudo ovs-vsctl list-ports br-left | grep -q "^${VHOST_PORT_LEFT}$" || \
    sudo ovs-vsctl add-port br-left ${VHOST_PORT_LEFT} -- set Interface ${VHOST_PORT_LEFT} \
        type=dpdkvhostuserclient options:vhost-server-path=${VHOST_SOCKET_DIR}/${VHOST_PORT_LEFT}

# ---- 6. br-right: port1 + VM2's vhost-user port ----
echo "[6/8] Creating br-right (port1 side, for VM2)"
if ! sudo ovs-vsctl br-exists br-right; then
    sudo ovs-vsctl add-br br-right -- set bridge br-right datapath_type=netdev
fi
sudo ovs-vsctl list-ports br-right | grep -q '^dpdk1$' || \
    sudo ovs-vsctl add-port br-right dpdk1 -- set Interface dpdk1 type=dpdk options:dpdk-devargs=${PF1_PCI}
sudo ovs-vsctl list-ports br-right | grep -q "^${VHOST_PORT_RIGHT}$" || \
    sudo ovs-vsctl add-port br-right ${VHOST_PORT_RIGHT} -- set Interface ${VHOST_PORT_RIGHT} \
        type=dpdkvhostuserclient options:vhost-server-path=${VHOST_SOCKET_DIR}/${VHOST_PORT_RIGHT}

# ---- 7. Local management bridge (pure software, no CX-5 involvement) ----
# Same reasoning as the SR-IOV leg: once both physical ports are fully
# handed to DPDK, the host has no other L3 path to reach either VM for
# SSH/control. This bridge is NEVER connected to the CX-5 in any way.
echo "[7/8] Creating management bridge ${MGMT_BRIDGE}"
if ! ip link show ${MGMT_BRIDGE} &>/dev/null; then
    sudo ip link add ${MGMT_BRIDGE} type bridge
    sudo ip link set ${MGMT_BRIDGE} type bridge stp_state 0
    sudo ip addr add ${MGMT_HOST_IP}/${MGMT_PREFIX} dev ${MGMT_BRIDGE}
    sudo ip link set ${MGMT_BRIDGE} up
fi
for TAP in "${MGMT_TAP1}" "${MGMT_TAP2}"; do
    if ! ip link show ${TAP} &>/dev/null; then
        sudo ip tuntap add dev ${TAP} mode tap user "${TAP_USER}"
        sudo ip link set ${TAP} master ${MGMT_BRIDGE}
        sudo ip link set ${TAP} up
    fi
done

# ---- 8. Sanity checks ----
echo "[8/8] Sanity checks"
sudo ovs-vsctl show
echo
echo "Port link states (should say 'true' once both VMs are launched and connect):"
sudo ovs-vsctl get Interface dpdk0 link_state 2>/dev/null
sudo ovs-vsctl get Interface dpdk1 link_state 2>/dev/null

echo
echo "Done."
echo "  br-left  : dpdk0 (${PF0_PCI}) + ${VHOST_PORT_LEFT}  -> VM1 connects here"
echo "  br-right : dpdk1 (${PF1_PCI}) + ${VHOST_PORT_RIGHT} -> VM2 connects here"
echo "  Mgmt     : ${MGMT_BRIDGE} (${MGMT_HOST_IP}/${MGMT_PREFIX}), taps ${MGMT_TAP1}/${MGMT_TAP2}"
echo
echo "  Sockets for QEMU:"
echo "    VM1: ${VHOST_SOCKET_DIR}/${VHOST_PORT_LEFT}"
echo "    VM2: ${VHOST_SOCKET_DIR}/${VHOST_PORT_RIGHT}"
