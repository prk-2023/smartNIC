#!/bin/bash
set -euo pipefail

### ---- Args ----
# Usage: ./launch_sriov_vm.sh <vm_name> <vf_bdf> <mgmt_tap> <mgmt_mac> <vcpu_pin_csv>
VM_NAME="${1:?Usage: $0 <vm_name> <vf_bdf> <mgmt_tap> <mgmt_mac> <vcpu_pin_csv>}"
VF_BDF="${2:?missing vf_bdf, e.g. 0000:01:00.2}"
MGMT_TAP="${3:?missing mgmt_tap, e.g. tap-mgmt1}"
MGMT_MAC="${4:?missing mgmt_mac}"
VCPU_PIN_CSV="${5:?missing vcpu_pin_csv, e.g. 2,3,4,5}"
IFS=',' read -ra VCPU_PIN <<< "${VCPU_PIN_CSV}"

VCPUS=${#VCPU_PIN[@]}
MEM=2G
DISK="$(realpath ./${VM_NAME}.qcow2)"
SEED="$(realpath ./${VM_NAME}-seed.iso)"
MONITOR_SOCK=/tmp/qemu-monitor-${VM_NAME}.sock
SERIAL_LOG=/tmp/qemu-${VM_NAME}-serial.log

### ---- Pre-flight ----
[[ -f "${DISK}" ]] || { echo "ERROR: ${DISK} not found"; exit 1; }
[[ -f "${SEED}" ]] || { echo "ERROR: ${SEED} not found"; exit 1; }
[[ -e "/sys/bus/pci/devices/${VF_BDF}" ]] || { echo "ERROR: PCI device ${VF_BDF} not found"; exit 1; }

CURRENT_DRIVER=$(basename "$(readlink -f /sys/bus/pci/devices/${VF_BDF}/driver)" 2>/dev/null || echo none)
if [[ "${CURRENT_DRIVER}" != "vfio-pci" ]]; then
    echo "ERROR: ${VF_BDF} is bound to '${CURRENT_DRIVER}', not vfio-pci."
    echo "  Run host_sriov_setup.sh first, or manually: sudo driverctl set-override ${VF_BDF} vfio-pci"
    exit 1
fi

ip link show ${MGMT_TAP} &>/dev/null || { echo "ERROR: ${MGMT_TAP} does not exist - run host_sriov_setup.sh first"; exit 1; }

FREE_HP=$(grep HugePages_Free /proc/meminfo | awk '{print $2}')
[[ "${FREE_HP}" -ge 1024 ]] || { echo "ERROR: only ${FREE_HP} free hugepages, need >=1024"; exit 1; }

pgrep -f "qemu-${VM_NAME}" >/dev/null && { echo "ERROR: qemu-${VM_NAME} already running"; exit 1; }
rm -f "/tmp/qemu-${VM_NAME}.pid" "${MONITOR_SOCK}"

### ---- Launch ----
qemu-system-x86_64 \
  -name guest,process=qemu-${VM_NAME} \
  -enable-kvm -cpu host,host-cache-info=on -smp ${VCPUS},sockets=1,cores=${VCPUS},threads=1 \
  -m ${MEM} \
  -object memory-backend-file,id=mem,size=${MEM},mem-path=/dev/hugepages,share=on \
  -numa node,memdev=mem \
  -drive file=${DISK},if=virtio,format=qcow2,cache=none,aio=native \
  -drive file=${SEED},if=virtio,format=raw,readonly=on \
  -device vfio-pci,host=${VF_BDF} \
  -netdev tap,id=mgmt0,ifname=${MGMT_TAP},script=no,downscript=no,vhost=on \
  -device virtio-net-pci,netdev=mgmt0,mac=${MGMT_MAC} \
  -monitor unix:${MONITOR_SOCK},server,nowait \
  -serial file:${SERIAL_LOG} \
  -display none \
  -daemonize \
  -pidfile /tmp/qemu-${VM_NAME}.pid

### ---- Confirm started ----
sleep 2
[[ -f "/tmp/qemu-${VM_NAME}.pid" ]] || { echo "ERROR: failed to start - check ${SERIAL_LOG}"; exit 1; }
QEMU_PID=$(cat /tmp/qemu-${VM_NAME}.pid)
kill -0 "${QEMU_PID}" 2>/dev/null || { echo "ERROR: pid ${QEMU_PID} not running - check ${SERIAL_LOG}"; exit 1; }

### ---- Pin vCPU threads ----
i=0
for tid in $(ls /proc/${QEMU_PID}/task | tail -n +2); do
    comm=$(cat /proc/${QEMU_PID}/task/${tid}/comm)
    if [[ "$comm" == CPU* ]]; then
        taskset -pc ${VCPU_PIN[$i]} ${tid}
        i=$((i+1))
    fi
done

echo "Launched ${VM_NAME}, PID ${QEMU_PID}, VF ${VF_BDF} passed through, mgmt via ${MGMT_TAP}"
echo "Serial log: ${SERIAL_LOG}"
