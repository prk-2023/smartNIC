#!/bin/bash
set -euo pipefail

### ---- Config ----
PHYS_IFACE_BRIDGED="enp1s0f0np0"   # port0 - bridge member, guest-facing
PHYS_IFACE_HOST="enp1s0f1np1"      # port1 - host-facing, other end of the DAC loop
BRIDGE="br0"
TAP="vnet0"
TAP_USER="$(whoami)"

HOST_IP="192.168.100.1"
HOST_PREFIX="24"

HUGEPAGE_COUNT=1024                 # 1024 x 2MB = 2GB, matches guest MEM=2G

echo "===== Host network setup for virtio benchmark ====="

### ---- 1. Hugepages ----
echo "[1/6] Configuring hugepages (${HUGEPAGE_COUNT} x 2MB)"
CURRENT_HP=$(grep HugePages_Total /proc/meminfo | awk '{print $2}')
if [[ "${CURRENT_HP}" -lt "${HUGEPAGE_COUNT}" ]]; then
    sudo sysctl -w vm.nr_hugepages=${HUGEPAGE_COUNT}
fi
grep Huge /proc/meminfo
mountpoint -q /dev/hugepages || sudo mount -t hugetlbfs hugetlbfs /dev/hugepages
FREE_HP=$(grep HugePages_Free /proc/meminfo | awk '{print $2}')
if [[ "${FREE_HP}" -lt "${HUGEPAGE_COUNT}" ]]; then
    echo "  WARNING: only ${FREE_HP} free hugepages (wanted ${HUGEPAGE_COUNT})."
    echo "  Consider setting via kernel cmdline (default_hugepagesz=2M hugepagesz=2M hugepages=${HUGEPAGE_COUNT}) + reboot for reliable contiguous allocation."
fi

### ---- 2. NetworkManager hands-off for our interfaces ----
echo "[2/6] Setting NetworkManager to unmanaged for test interfaces"
for IFACE in "${PHYS_IFACE_BRIDGED}" "${PHYS_IFACE_HOST}" "${BRIDGE}" "${TAP}"; do
    if command -v nmcli >/dev/null 2>&1 && nmcli device show "${IFACE}" &>/dev/null; then
        sudo nmcli device set "${IFACE}" managed no 2>/dev/null || true
    fi
done

### ---- 3. Bridge + tap (guest-facing side) ----
echo "[3/6] Creating bridge ${BRIDGE} with ${PHYS_IFACE_BRIDGED} as member"
if ! ip link show ${BRIDGE} &>/dev/null; then
    sudo ip link add ${BRIDGE} type bridge
    sudo ip link set ${BRIDGE} type bridge stp_state 0     # skip STP listening/learning delay
    sudo ip link set ${PHYS_IFACE_BRIDGED} master ${BRIDGE}
    sudo ip addr flush dev ${PHYS_IFACE_BRIDGED}            # bridge members carry no IP themselves
    sudo ip link set ${PHYS_IFACE_BRIDGED} up
    sudo ip link set ${BRIDGE} up
else
    echo "  ${BRIDGE} already exists, skipping creation"
fi

if ! ip link show ${TAP} &>/dev/null; then
    sudo ip tuntap add dev ${TAP} mode tap multi_queue user "${TAP_USER}"
    sudo ip link set ${TAP} master ${BRIDGE}
    sudo ip link set ${TAP} up
else
    echo "  ${TAP} already exists, skipping creation"
fi

### ---- 4. Host-facing physical port (completes the DAC loop) ----
echo "[4/6] Assigning ${HOST_IP}/${HOST_PREFIX} to ${PHYS_IFACE_HOST}"
sudo ip addr flush dev ${PHYS_IFACE_HOST}
sudo ip addr add ${HOST_IP}/${HOST_PREFIX} dev ${PHYS_IFACE_HOST}
sudo ip link set ${PHYS_IFACE_HOST} up

### ---- 5. Bridge netfilter off (avoid firewall/iptables intercepting bridged frames) ----
echo "[5/6] Disabling bridge-nf-call-iptables if br_netfilter is loaded"
if lsmod | grep -q br_netfilter; then
    sudo sysctl -w net.bridge.bridge-nf-call-iptables=0 || true
fi

### ---- 6. Sanity checks ----
echo "[6/6] Sanity checks"
bridge link show ${TAP} | grep -q "master ${BRIDGE}" \
    && echo "  OK: ${TAP} enslaved to ${BRIDGE}" \
    || { echo "  ERROR: ${TAP} not enslaved to ${BRIDGE}"; exit 1; }
bridge link show ${PHYS_IFACE_BRIDGED} | grep -q "master ${BRIDGE}" \
    && echo "  OK: ${PHYS_IFACE_BRIDGED} enslaved to ${BRIDGE}" \
    || { echo "  ERROR: ${PHYS_IFACE_BRIDGED} not enslaved to ${BRIDGE}"; exit 1; }

for IFACE in "${PHYS_IFACE_BRIDGED}" "${PHYS_IFACE_HOST}"; do
    LINK=$(sudo ethtool "${IFACE}" 2>/dev/null | grep -i "Link detected" || echo "unknown")
    echo "  ${IFACE}: ${LINK}"
done

lsmod | grep -q vhost_net || sudo modprobe vhost_net
[[ -e /dev/vhost-net ]] && echo "  OK: /dev/vhost-net present" || echo "  WARNING: /dev/vhost-net missing"

echo
echo "Done."
echo "  Bridge   : ${BRIDGE} (${PHYS_IFACE_BRIDGED} + ${TAP})"
echo "  Host IP  : ${HOST_IP}/${HOST_PREFIX} on ${PHYS_IFACE_HOST}"
echo "  Guest IP : 192.168.100.10/24 (set via cloud-init, see build_guest_image.sh)"


# $ ip a
# 1: lo: <LOOPBACK,UP,LOWER_UP> mtu 65536 qdisc noqueue state UNKNOWN group default qlen 1000
#     link/loopback 00:00:00:00:00:00 brd 00:00:00:00:00:00
#     inet 127.0.0.1/8 scope host lo
#        valid_lft forever preferred_lft forever
#     inet6 ::1/128 scope host noprefixroute
#        valid_lft forever preferred_lft forever
# 2: enp3s0: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc fq_codel state UP group default qlen 1000
#     link/ether d8:bb:c1:59:ec:b2 brd ff:ff:ff:ff:ff:ff
#     altname enxd8bbc159ecb2
#     inet 10.10.10.18/24 brd 10.10.10.255 scope global noprefixroute enp3s0
#        valid_lft forever preferred_lft forever
#     inet 192.168.88.152/21 brd 192.168.95.255 scope global dynamic noprefixroute enp3s0
#        valid_lft 7379sec preferred_lft 7379sec
#     inet6 fe80::a109:9ccb:ea55:8e44/64 scope link noprefixroute
#        valid_lft forever preferred_lft forever
# 3: enp1s0f0np0: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc mq master br0 state UP group default qlen 1000
#     link/ether 6c:b3:11:88:55:b4 brd ff:ff:ff:ff:ff:ff
#     altname enx6cb3118855b4
# 4: enp1s0f1np1: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc mq state UP group default qlen 1000
#     link/ether 6c:b3:11:88:55:b5 brd ff:ff:ff:ff:ff:ff
#     altname enx6cb3118855b5
#     inet 192.168.100.1/24 scope global enp1s0f1np1
#        valid_lft forever preferred_lft forever
# 5: br0: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc noqueue state UP group default qlen 1000
#     link/ether 6c:b3:11:88:55:b4 brd ff:ff:ff:ff:ff:ff
# 6: vnet0: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc mq master br0 state UP group default qlen 1000
#     link/ether 6e:0f:03:55:fc:4e brd ff:ff:ff:ff:ff:ff
#     inet6 fe80::6c0f:3ff:fe55:fc4e/64 scope link proto kernel_ll
#        valid_lft forever preferred_lft forever
