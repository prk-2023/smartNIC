#!/bin/bash
# Host environment verification for virtio/DPDK/vDPA benchmarking
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
echo "===== HUGEPAGES ====="
grep Huge /proc/meminfo
mount | grep huge
echo
echo "===== IOMMU ====="
dmesg | grep -E -i 'DMAR|IOMMU'
echo
echo "===== MELLANOX ====="
lspci | grep Mellanox
echo
echo "===== DRIVER ====="
lsmod | grep mlx
echo 
echo "==== Mellonox Firmware version "
cat /sys/class/infiniband/rocep1s0f0/fw_ver
echo
echo "===== RDMA DEVICES ====="
ibv_devices
echo
echo "===== NET DEVICES ====="
ip -br link
echo

echo "==== VFIO, vDPA ===="
modprobe vfio
modprobe vdpa 
sleep 1
echo 
lsmod | grep -E 'vfio|vdpa'
echo
echo "===== SR-IOV ====="
for d in /sys/class/net/*; do
    iface=$(basename $d)
    if [ -f "$d/device/sriov_totalvfs" ]; then
        echo "$iface"
        echo "Total VFs : $(cat $d/device/sriov_totalvfs)"
        echo "Active VFs: $(cat $d/device/sriov_numvfs)"
        echo
    fi
done
echo "===== BRIDGE ====="
bridge link
bridge vlan
echo
echo "===== IRQBALANCE ====="
systemctl is-active irqbalance
echo
echo "===== IRQ AFFINITY ====="
cat /proc/interrupts | grep -E 'mlx|virtio|vhost'
echo
echo "===== QEMU ====="
pgrep -a qemu
echo
echo "===== TAP ====="
ip tuntap list
echo
echo "===== ETHTOOL ====="
for i in $(ls /sys/class/net); do
    echo "----- $i -----"
    ethtool $i 2>/dev/null | grep Speed
    ethtool -k $i 2>/dev/null | grep -E 'gro|gso|tso|lro'
    #echo "num of channels"
    #ethtool -l $i 2>/dev/null
    #echo "driver stats"
    #ethtool -S $i 2>/dev/null
    echo "driver version and firmware"
    ethtool -i $i 2>/dev/null
done

echo 
echo "==== checking intel_iommu=on enables the Intel IOMMU (VT-d) ===="
grep -E 'intel_iommu=on|iommu=pt' /proc/cmdline
echo

echo "
==============================
Benchmark Host Readiness
==============================

Kernel              
CPU Governor        
Hugepages           
IOMMU               
ConnectX-5          
RDMA                
SR-IOV              
VFIO                
OVS                 
vDPA                

NOTE: The above are not validated in the script. 
for Host Status: READY verify the output and update config or setting as required. 
"
