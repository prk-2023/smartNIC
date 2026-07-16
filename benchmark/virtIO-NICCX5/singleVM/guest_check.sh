#!/bin/bash
#
# Guest environment verification for virtio / vhost-user / vDPA benchmarking
#

#NIC=${1:-$(ip -br link | awk '$1!="lo" && $2=="UP" {print $1; exit}')}
if [ -z "$1" ]; then
    echo "Usage: $0 <interface>"
    echo
    echo "Available interfaces:"
    ip -br link
    exit 1
fi

NIC=$1

echo "===== SYSTEM ====="
hostnamectl
echo

echo "===== KERNEL ====="
uname -a
echo

echo "===== CPU ====="
lscpu | grep -E 'Model name|Socket|NUMA|CPU\(s\)|Thread|Core'
echo

echo "===== CPU GOVERNOR ====="
cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null
echo


echo "===== MEMORY ====="
free -h
echo


echo "===== HUGE PAGES ====="
grep Huge /proc/meminfo
echo


echo "===== NUMA ====="
numactl --hardware 2>/dev/null
echo


echo "===== CLOCKSOURCE ====="
cat /sys/devices/system/clocksource/clocksource0/current_clocksource
echo


echo "===== NETWORK DEVICE ====="
echo "Selected NIC: $NIC"
ip -br addr
echo


echo "===== PCI DEVICES ====="
lspci | grep -i virtio
echo

echo "===== PCI DEVICE ====="
ethtool -i $NIC
echo

echo "===== PCI LOCATION ====="
readlink /sys/class/net/$NIC/device
echo

echo "===== PCI DETAILS ====="
lspci -vv | grep -A20 -i virtio
echo


echo "===== VIRTIO MODULES ====="
lsmod | grep virtio
echo


echo "===== DRIVER INFO ====="
ethtool -i $NIC 2>/dev/null
echo


echo "===== LINK STATUS ====="
ethtool $NIC 2>/dev/null | grep -E 'Speed|Duplex|Link detected'
echo


echo "===== MULTIQUEUE ====="
ethtool -l $NIC 2>/dev/null
echo

echo "===== CURRENT QUEUES ====="
echo "RX queues:"
ls /sys/class/net/$NIC/queues/ | grep rx | wc -l

echo "TX queues:"
ls /sys/class/net/$NIC/queues/ | grep tx | wc -l
echo


echo "===== RSS ====="
ethtool -x $NIC 2>/dev/null
echo


echo "===== OFFLOADS ====="
ethtool -k $NIC 2>/dev/null | \
grep -E 'gro|gso|tso|lro|checksum'
echo


echo "===== IRQ ====="
cat /proc/interrupts | grep -i virtio
echo


echo "===== IRQ AFFINITY ====="

for irq in $(grep -i virtio /proc/interrupts | cut -d: -f1); do
    irq=$(echo $irq | tr -d ' ')
    echo "IRQ $irq -> $(cat /proc/irq/$irq/smp_affinity_list 2>/dev/null)"
done
echo


echo "===== NETWORK STATISTICS ====="
ip -s link show $NIC
echo

# Log gets long if enabled.
#echo "===== ETHTOOL STATISTICS ====="
#ethtool -S $NIC 2>/dev/null
#echo


echo "===== ROUTES ====="
ip route
echo


echo "===== MTU ====="
ip link show $NIC | grep mtu
echo
