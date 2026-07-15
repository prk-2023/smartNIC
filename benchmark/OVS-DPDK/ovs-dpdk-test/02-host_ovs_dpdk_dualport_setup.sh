#!/bin/bash
set -euo pipefail

# ============================================================================
# host_ovs_dpdk_dualport_setup.sh
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

# ---- 2. Hugepages check (Page-Size Aware) ----
echo "[2/8] Checking hugepages"
HUGEPAGE_SIZE_KB=$(grep Hugepagesize /proc/meminfo | awk '{print $2}')
HUGEPAGE_SIZE_MB=$((HUGEPAGE_SIZE_KB / 1024))
VM_MEM_MB=2048          
TOTAL_NEEDED_MB=$(( VM_MEM_MB * 2 + DPDK_SOCKET_MEM ))   
NEEDED_PAGES=$(( (TOTAL_NEEDED_MB + HUGEPAGE_SIZE_MB - 1) / HUGEPAGE_SIZE_MB ))

FREE_HP=$(grep HugePages_Free /proc/meminfo | awk '{print $2}')
echo "  Hugepage size: ${HUGEPAGE_SIZE_MB} MB | Free: ${FREE_HP} | Needed total: ${NEEDED_PAGES}"
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
[[ "${DPDK_STATUS}" == "true" ]] || { echo "  ERROR: check openvswitch logs"; exit 1; }

# ---- 5. br-left: port0 + VM1's vhost-user port ----
echo "[5/8] Creating br-left (port0 side, for VM1)"
# OPTIMIZATION: Ensure open directory permissions so daemonized QEMU can write sockets
sudo mkdir -p ${VHOST_SOCKET_DIR}
sudo chmod 777 ${VHOST_SOCKET_DIR}

if ! sudo ovs-vsctl br-exists br-left; then
    sudo ovs-vsctl add-br br-left -- set bridge br-left datapath_type=netdev
fi
sudo ovs-vsctl list-ports br-left | grep -q '^dpdk0$' || \
    sudo ovs-vsctl add-port br-left dpdk0 -- set Interface dpdk0 type=dpdk options:dpdk-devargs=${PF0_PCI}

sudo ovs-vsctl list-ports br-left | grep -q "^${VHOST_PORT_LEFT}$" || \
    sudo ovs-vsctl add-port br-left ${VHOST_PORT_LEFT} -- set Interface ${VHOST_PORT_LEFT} \
        type=dpdkvhostuserclient options:vhost-server-path=${VHOST_SOCKET_DIR}/${VHOST_PORT_LEFT}
# sudo ovs-vsctl list-ports br-left | grep -q "^${VHOST_PORT_LEFT}$" || \
#     sudo ovs-vsctl add-port br-left ${VHOST_PORT_LEFT} -- set Interface ${VHOST_PORT_LEFT} \
#     type=dpdkvhostuser options:vhost-server-path=/tmp/ovs-vhost/vhost-user0

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
# sudo ovs-vsctl list-ports br-right | grep -q "^${VHOST_PORT_RIGHT}$" || \
#     sudo ovs-vsctl add-port br-right ${VHOST_PORT_RIGHT} -- set Interface ${VHOST_PORT_RIGHT} \
#     type=dpdkvhostuser options:vhost-server-path=/tmp/ovs-vhost/vhost-user1

sleep 2
# NOTE (fixed): OVS ports are dpdkvhostuserclient, so OVS connects OUT to the
# socket rather than creating it. The socket files don't exist until QEMU
# (the vhost-user server, see 04-launch_ovs_dpdk_vm_generic.sh) actually
# starts, so chmod'ing them here always failed and, under set -euo pipefail,
# silently aborted the rest of this script (steps 7-8 never ran).
# QEMU creates the socket itself with open permissions via its own umask 0000,
# so no chmod is needed here at all.
echo "Setup complete! Vhost-user sockets will appear in ${VHOST_SOCKET_DIR}/ once each VM is launched (QEMU acts as the vhost-user server)."

# ---- 7. Local management bridge (pure software) ----
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
echo "Done."
