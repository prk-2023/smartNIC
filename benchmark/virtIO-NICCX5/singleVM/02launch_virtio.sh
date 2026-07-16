#!/bin/bash
set -euo pipefail

RUN=virtio_tcp_run1
VCPUS=4
MEM=2G
DISK="$(realpath ./guest.qcow2)"
SEED="$(realpath ./seed.iso)"
MONITOR_SOCK=/tmp/qemu-monitor-${RUN}.sock
SERIAL_LOG=/tmp/qemu-${RUN}-serial.log
PHYS_IFACE=enp1s0f0np0
BRIDGE=br0
TAP=vnet0

VCPU_PIN=(2 3 4 5)      # isolated cores for guest vCPUs
VHOST_PIN=(6 7)         # isolated cores for vhost-net kernel threads, disjoint from VCPU_PIN

### ---- Pre-flight sanity checks ----
[[ -f "${DISK}" ]] || { echo "ERROR: ${DISK} not found"; exit 1; }
[[ -f "${SEED}" ]] || { echo "ERROR: ${SEED} not found"; exit 1; }

FREE_HP=$(grep HugePages_Free /proc/meminfo | awk '{print $2}')
if [[ "${FREE_HP}" -lt 1024 ]]; then
    echo "ERROR: only ${FREE_HP} free hugepages, need >=1024 for ${MEM}"
    exit 1
fi

lsmod | grep -q vhost_net || sudo modprobe vhost_net
[[ -e /dev/vhost-net ]] || { echo "ERROR: /dev/vhost-net missing after modprobe"; exit 1; }
[[ -e /dev/kvm ]] || { echo "ERROR: /dev/kvm missing"; exit 1; }

pgrep -f "qemu-${RUN}" >/dev/null && { echo "ERROR: a qemu process named qemu-${RUN} is already running"; exit 1; }
rm -f "/tmp/qemu-${RUN}.pid" "${MONITOR_SOCK}"

### ---- Host network prep (idempotent) ----
if ! ip link show ${BRIDGE} &>/dev/null; then
    sudo ip link add ${BRIDGE} type bridge
    sudo ip link set ${PHYS_IFACE} master ${BRIDGE}
    sudo ip addr flush dev ${PHYS_IFACE}
    sudo ip link set ${PHYS_IFACE} up
    sudo ip link set ${BRIDGE} up
fi

if ! ip link show ${TAP} &>/dev/null; then
    sudo ip tuntap add dev ${TAP} mode tap multi_queue user $(whoami)
    sudo ip link set ${TAP} master ${BRIDGE}
    sudo ip link set ${TAP} up
fi

bridge link show ${TAP} | grep -q "master ${BRIDGE}" || { echo "tap not enslaved"; exit 1; }
bridge link show ${PHYS_IFACE} | grep -q "master ${BRIDGE}" || { echo "phys iface not enslaved"; exit 1; }

### ---- QEMU launch ----
# qemu-system-x86_64 \
#   -name guest,process=qemu-${RUN} \
#   -enable-kvm -cpu host,host-cache-info=on -smp ${VCPUS},sockets=1,cores=${VCPUS},threads=1 \
#   -m ${MEM} \
#   -object memory-backend-file,id=mem,size=${MEM},mem-path=/dev/hugepages,share=on \
#   -numa node,memdev=mem \
#   -drive file=${DISK},if=virtio,format=qcow2,cache=none,aio=native \
#   -drive file=${SEED},if=virtio,format=raw,readonly=on \
#   -netdev tap,id=net0,ifname=${TAP},script=no,downscript=no,vhost=on,queues=${VCPUS} \
#   -device virtio-net-pci,netdev=net0,mq=on,vectors=$((2*VCPUS+2)),rx_queue_size=1024,tx_queue_size=1024,mac=52:54:00:12:34:56 \
#   -monitor unix:${MONITOR_SOCK},server,nowait \
#   #-serial file:${SERIAL_LOG} \
#   -serial mon:pty \
#   -display none \
#   -daemonize \
#   -pidfile /tmp/qemu-${RUN}.pid

qemu-system-x86_64 \
  -name guest,process=qemu-${RUN} \
  -enable-kvm -cpu host,host-cache-info=on -smp ${VCPUS},sockets=1,cores=${VCPUS},threads=1 \
  -m ${MEM} \
  -object memory-backend-file,id=mem,size=${MEM},mem-path=/dev/hugepages,share=on \
  -numa node,memdev=mem \
  -drive file=${DISK},if=virtio,format=qcow2,cache=none,aio=native \
  -drive file=${SEED},if=virtio,format=raw,readonly=on \
  -netdev tap,id=net0,ifname=${TAP},script=no,downscript=no,vhost=on,queues=${VCPUS} \
  -device virtio-net-pci,netdev=net0,mq=on,vectors=$((2*VCPUS+2)),disable-legacy=on,mac=52:54:00:12:34:56 \
  -monitor unix:${MONITOR_SOCK},server,nowait \
   -serial file:${SERIAL_LOG} \
  -display none \
  -daemonize \
  -pidfile /tmp/qemu-${RUN}.pid
### ---- Confirm it actually started ----
sleep 2
if [[ ! -f "/tmp/qemu-${RUN}.pid" ]]; then
    echo "ERROR: QEMU failed to start - check ${SERIAL_LOG} and dmesg"
    exit 1
fi
QEMU_PID=$(cat /tmp/qemu-${RUN}.pid)
if ! kill -0 "${QEMU_PID}" 2>/dev/null; then
    echo "ERROR: QEMU pid ${QEMU_PID} not running - check ${SERIAL_LOG}"
    exit 1
fi

### ---- Pin vCPU threads ----
i=0
for tid in $(ls /proc/${QEMU_PID}/task | tail -n +2); do
    comm=$(cat /proc/${QEMU_PID}/task/${tid}/comm)
    if [[ "$comm" == CPU* ]]; then
        taskset -pc ${VCPU_PIN[$i]} ${tid}
        i=$((i+1))
    fi
done

echo "QEMU launched, PID ${QEMU_PID}, monitor at ${MONITOR_SOCK}"
echo "Serial console log: ${SERIAL_LOG}"
echo "NOTE: run pin_vhost.sh AFTER guest boots and traffic starts (vhost threads spawn lazily)"
