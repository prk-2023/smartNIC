#!/bin/bash
set -euo pipefail

# ============================================================================
# launch_ovs_dpdk_vm_generic.sh
# ============================================================================

VM_NAME="${1:?Usage: $0 <vm_name> <vhost_socket> <vhost_mac> <mgmt_tap> <mgmt_mac> <vcpu_pin_csv>}"
VHOST_SOCKET="${2:?missing vhost_socket path}"
VHOST_MAC="${3:?missing vhost_mac}"
MGMT_TAP="${4:?missing mgmt_tap}"
MGMT_MAC="${5:?missing mgmt_mac}"
VCPU_PIN_CSV="${6:?missing vcpu_pin_csv, e.g. 4,5}"
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
ip link show ${MGMT_TAP} &>/dev/null || { echo "ERROR: ${MGMT_TAP} missing"; exit 1; }

# Page-Size Aware Hugepage verification
HUGEPAGE_SIZE_KB=$(grep Hugepagesize /proc/meminfo | awk '{print $2}')
HUGEPAGE_SIZE_BYTES=$((HUGEPAGE_SIZE_KB * 1024))
MEM_BYTES=$(( $(numfmt --from=iec "${MEM}") ))
NEEDED_PAGES=$(( (MEM_BYTES + HUGEPAGE_SIZE_BYTES - 1) / HUGEPAGE_SIZE_BYTES ))

FREE_HP=$(grep HugePages_Free /proc/meminfo | awk '{print $2}')
echo "Hugepage size: $((HUGEPAGE_SIZE_KB / 1024)) MB | Free: ${FREE_HP} | Needed: ${NEEDED_PAGES}"
[[ "${FREE_HP}" -ge "${NEEDED_PAGES}" ]] || { echo "ERROR: only ${FREE_HP} free hugepages, need >=${NEEDED_PAGES}"; exit 1; }

mount | grep -q "on /dev/hugepages type hugetlbfs" \
    || { echo "ERROR: /dev/hugepages is not mounted as hugetlbfs"; exit 1; }

pgrep -f "qemu-${VM_NAME}" >/dev/null && { echo "ERROR: qemu-${VM_NAME} already running"; exit 1; }
rm -f "/tmp/qemu-${VM_NAME}.pid" "${MONITOR_SOCK}" "${VHOST_SOCKET}"

### ---- Launch ----
# OPTIMIZATION: Open umask temporarily so socket is created with accessible permissions
OLD_UMASK=$(umask)
umask 0000

qemu-system-x86_64 \
  -name guest,process=qemu-${VM_NAME} \
  -enable-kvm -cpu host,host-cache-info=on -smp ${VCPUS},sockets=1,cores=${VCPUS},threads=1 \
  -m ${MEM} \
  -object memory-backend-file,id=mem,size=${MEM},mem-path=/dev/hugepages,share=on \
  -numa node,memdev=mem \
  -drive file=${DISK},if=virtio,format=qcow2,cache=none,aio=native \
  -drive file=${SEED},if=virtio,format=raw,readonly=on \
  -chardev socket,id=vhostchar,path=${VHOST_SOCKET},server=on,wait=off \
  -netdev vhost-user,id=vhostnet,chardev=vhostchar,queues=1 \
  -device virtio-net-pci,netdev=vhostnet,mac=${VHOST_MAC},mq=off \
  -netdev tap,id=mgmtnet,ifname=${MGMT_TAP},script=no,downscript=no,vhost=on \
  -device virtio-net-pci,netdev=mgmtnet,mac=${MGMT_MAC} \
  -monitor unix:${MONITOR_SOCK},server,nowait \
  -serial file:${SERIAL_LOG} \
  -display none \
  -daemonize \
  -pidfile /tmp/qemu-${VM_NAME}.pid

# NOTE (fixed): OVS ports in 02-host_ovs_dpdk_dualport_setup.sh are created as
# type=dpdkvhostuserclient, meaning OVS connects OUT to the socket rather than
# creating/listening on it. QEMU must therefore be the vhost-user SERVER
# (server=on,wait=off) so it creates the socket file and OVS can connect to it.
# The previous server=off here made QEMU a client too, so neither side ever
# created the socket and the VM failed to start.
umask "${OLD_UMASK}"

### ---- Confirm started ----
sleep 2
[[ -f "/tmp/qemu-${VM_NAME}.pid" ]] || { echo "ERROR: failed to start - check ${SERIAL_LOG}"; exit 1; }
QEMU_PID=$(cat /tmp/qemu-${VM_NAME}.pid)

### ---- Pin vCPU threads ----
# OPTIMIZATION: Strict named mapping parsing from 'comm' to protect sequential layout order
echo "Pinning vCPU threads for PID ${QEMU_PID}..."
for tid in /proc/${QEMU_PID}/task/*; do
    tid_num=$(basename "${tid}")
    if [ -f "${tid}/comm" ]; then
        comm=$(cat "${tid}/comm")
        if [[ "${comm}" =~ CPU[[:space:]]+([0-9]+) ]]; then
            vcpu_idx="${BASH_REMATCH[1]}"
            if [ "${vcpu_idx}" -lt "${VCPUS}" ]; then
                target_core="${VCPU_PIN[${vcpu_idx}]}"
                taskset -pc "${target_core}" "${tid_num}" > /dev/null
                echo "  Mapped vCPU ${vcpu_idx} (TID ${tid_num}) -> Host Core ${target_core}"
            fi
        fi
    fi
done

echo "Launched ${VM_NAME} successfully."
