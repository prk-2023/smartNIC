#!/usr/bin/env bash
# t2_host_setup.sh — prepares the DGX host for the t2 (VM<->VM virtio) test using
# OVS-DPDK: br-left/br-right become DPDK-datapath OVS bridges, PF0/PF1 are added as
# dpdk-type ports (via PCI BDF, NOT vfio-pci unbind - mlx5 stays bound to mlx5_core),
# and VM connectivity moves from tap+vhost-net to vhost-user (dpdkvhostuserclient).
#
# Prerequisites this script checks but does NOT fix for you (see t2_perf_status.sh /
# t2_README_ovsdpdk.md): DPDK_LCORE_MASK and PMD_CPU_MASK in t2_config.sh must be filled
# in first - this script refuses to proceed with the placeholders empty.

set -euo pipefail
source "$(dirname "$0")/t2_config.sh"

echo "===== t2 host setup (OVS-DPDK) ====="
echo "Make sure you are using the correct ovs-vswitchd-dpdk"
echo "if unsure use: sudo update-alternatives --config ovs-vswitchd"
echo "and select the right one"

### ---- 0. Refuse to proceed with unfilled CPU placeholders ----
if [[ -z "${DPDK_LCORE_MASK}" || -z "${PMD_CPU_MASK}" ]]; then
    echo "ERROR: DPDK_LCORE_MASK and/or PMD_CPU_MASK are empty in t2_config.sh."
    echo "       Run 'lscpu -e' first, pick cores disjoint from VCPU_PIN in t2_launch_vm.sh,"
    echo "       and fill both in before running this script. Refusing to guess at core"
    echo "       placement on a heterogeneous ARM topology (same reasoning as VCPU_PIN)."
    exit 1
fi

### ---- 1. Ensure OVS is running, enable the DPDK datapath ----
echo "[1/7] Enabling DPDK in OVS (this restarts openvswitch-switch)"
sudo systemctl enable --now openvswitch-switch >/dev/null

sudo ovs-vsctl set Open_vSwitch . other_config:dpdk-init=true
sudo ovs-vsctl set Open_vSwitch . other_config:dpdk-socket-mem="${DPDK_SOCKET_MEM_MB}"
sudo ovs-vsctl set Open_vSwitch . other_config:dpdk-lcore-mask="${DPDK_LCORE_MASK}"
sudo ovs-vsctl set Open_vSwitch . other_config:pmd-cpu-mask="${PMD_CPU_MASK}"

sudo systemctl restart openvswitch-switch
sleep 3

DPDK_OK=$(sudo ovs-vsctl get Open_vSwitch . dpdk_initialized 2>/dev/null || echo "false")
if [[ "${DPDK_OK}" != "true" ]]; then
    echo "  ERROR: dpdk_initialized=${DPDK_OK} - DPDK datapath did not come up."
    echo "  Check: sudo journalctl -u openvswitch-switch -n 100 --no-pager"
    echo "  Common cause: DPDK_SOCKET_MEM_MB not available as free hugepages yet -"
    echo "  run t2_perf_apply.sh first, or increase HUGEPAGE count and retry."
    exit 1
fi
echo "  OK: dpdk_initialized=true"

### ---- 2. Verify mlx5 glue (libibverbs/libmlx5) actually loaded, not just DPDK generically ----
echo "[2/7] Checking for mlx5 PMD glue-library errors in the OVS log"
if sudo journalctl -u openvswitch-switch -n 200 --no-pager 2>/dev/null | grep -qi "cannot load glue library\|missing run-time dependency on rdma-core"; then
    echo "  ERROR: mlx5 PMD failed to load its rdma-core glue library."
    echo "  Install the runtime libs: sudo apt install libibverbs1 libmlx5-1"
    echo "  (This DGX should already have these from normal ConnectX-7 operation - if this"
    echo "   fires, something is unusually broken, not just missing by default.)"
    exit 1
fi
echo "  OK: no glue-library errors found in recent log"

### ---- 3. Recreate br-left/br-right with datapath_type=netdev (required for dpdk ports) ----
echo "[3/7] Recreating ${BR_LEFT}/${BR_RIGHT} with datapath_type=netdev"
sudo ovs-vsctl --if-exists del-br "${BR_LEFT}"
sudo ovs-vsctl --if-exists del-br "${BR_RIGHT}"
sudo ovs-vsctl add-br "${BR_LEFT}" -- set bridge "${BR_LEFT}" datapath_type=netdev
sudo ovs-vsctl add-br "${BR_RIGHT}" -- set bridge "${BR_RIGHT}" datapath_type=netdev
sudo ovs-vsctl set bridge "${BR_LEFT}" stp_enable=false
sudo ovs-vsctl set bridge "${BR_RIGHT}" stp_enable=false

### ---- 4. Add PF0/PF1 as dpdk ports (PCI BDF, NOT the kernel netdev name) ----
echo "[4/7] Adding ${PF0_PCI} to ${BR_LEFT}, ${PF1_PCI} to ${BR_RIGHT}"
sudo ovs-vsctl add-port "${BR_LEFT}" dpdk-p0 \
    -- set Interface dpdk-p0 type=dpdk options:dpdk-devargs="${PF0_PCI}"
sudo ovs-vsctl add-port "${BR_RIGHT}" dpdk-p1 \
    -- set Interface dpdk-p1 type=dpdk options:dpdk-devargs="${PF1_PCI}"
sleep 2
for PORT in dpdk-p0 dpdk-p1; do
    STATE=$(sudo ovs-vsctl get Interface "${PORT}" link_state 2>/dev/null || echo "unknown")
    ADMIN=$(sudo ovs-vsctl get Interface "${PORT}" admin_state 2>/dev/null || echo "unknown")
    echo "  ${PORT}: link_state=${STATE} admin_state=${ADMIN}"
    [[ "${STATE}" != "up" ]] && echo "  WARNING: ${PORT} link not up - check 'sudo ovs-vsctl list Interface ${PORT}' for an 'error' field"
done

### ---- 5. Add vhost-user client ports for both VMs ----
echo "[5/7] Adding vhost-user ports (OVS as client, QEMU as server)"
mkdir -p "${VHOST_SOCK_DIR}"
sudo ovs-vsctl add-port "${BR_LEFT}" vhost-vm1 \
    -- set Interface vhost-vm1 type=dpdkvhostuserclient options:vhost-server-path="${VHOST_SOCK_VM1}"
sudo ovs-vsctl add-port "${BR_RIGHT}" vhost-vm2 \
    -- set Interface vhost-vm2 type=dpdkvhostuserclient options:vhost-server-path="${VHOST_SOCK_VM2}"
echo "  (these show 'connection failed' or similar until a VM is actually launched and"
echo "   listening on the socket - that's expected right now, not an error)"

### ---- 6. Hugepages: confirm enough for OVS-DPDK's own reservation + both VMs ----
echo "[6/7] Hugepage check"
FREE_HP=$(grep HugePages_Free /proc/meminfo | awk '{print $2}')
echo "  ${FREE_HP} free of ${TOTAL_HUGEPAGES} needed (OVS-DPDK: ${DPDK_HUGEPAGES}, VMs: $((TOTAL_HUGEPAGES - DPDK_HUGEPAGES)))"
[[ "${FREE_HP}" -lt "$((TOTAL_HUGEPAGES - DPDK_HUGEPAGES))" ]] && \
    echo "  WARNING: may not have enough left for both VMs after OVS-DPDK's own allocation - run t2_perf_apply.sh"

### ---- 7. Sanity summary ----
echo "[7/7] Summary"
sudo ovs-vsctl show

echo
echo "Done."
echo "  ${BR_LEFT}  (OVS-DPDK): dpdk-p0 (${PF0_PCI}) + vhost-vm1 -> ${VHOST_SOCK_VM1}"
echo "  ${BR_RIGHT} (OVS-DPDK): dpdk-p1 (${PF1_PCI}) + vhost-vm2 -> ${VHOST_SOCK_VM2}"
echo "  Mgmt/internet/SSH: still QEMU SLIRP, unaffected by this change"
echo
echo "Next: launch both VMs with t2_launch_vm.sh (now using vhost-user, not tap) - the"
echo "      vhost-vm1/vhost-vm2 ports above will show connected once each VM's QEMU"
echo "      process is listening on its socket."
