#!/bin/bash
set -euo pipefail

# ============================================================================
# 03-launch_virtio_vm_generic.sh
# PURE VIRTIO launch (no DPDK, no vhost-user). Data NIC is a persistent tap
# (created by 01-host_virtio_dualport_setup.sh) accelerated by the kernel's
# vhost-net. Runs in the foreground with a GTK console - no -daemonize, to
# avoid the socket/permission issues daemonizing caused during setup.
# Guest RAM stays hugepage-backed and vCPU pinning is unchanged from the
# OVS-DPDK runs, so the benchmark isolates the network dataplane only.
# ============================================================================

VM_NAME="${1:?Usage: $0 <vm_name> <data_tap> <data_mac> <mgmt_tap> <mgmt_mac> <vcpu_pin_csv>}"
DATA_TAP="${2:?missing data_tap, e.g. vnet0}"
DATA_MAC="${3:?missing data_mac}"
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
ip link show ${MGMT_TAP} &>/dev/null || { echo "ERROR: ${MGMT_TAP} missing - run 02b setup first"; exit 1; }
ip link show ${DATA_TAP} &>/dev/null || { echo "ERROR: ${DATA_TAP} missing - run 02b setup first"; exit 1; }
lsmod | grep -q '^vhost_net' || echo "WARNING: vhost_net not loaded - data path will fall back to slower pure userspace virtio"

# Page-Size Aware Hugepage verification (guest RAM only - unrelated to the
# network dataplane, kept identical to the DPDK launch script for a fair A/B)
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
rm -f "/tmp/qemu-${VM_NAME}.pid" "${MONITOR_SOCK}"

### ---- Launch (foreground, GTK console - matches your current workflow) ----
qemu-system-x86_64 \
  -name guest,process=qemu-${VM_NAME} \
  -enable-kvm -cpu host,host-cache-info=on -smp ${VCPUS},sockets=1,cores=${VCPUS},threads=1 \
  -m ${MEM} \
  -object memory-backend-file,id=mem,size=${MEM},mem-path=/dev/hugepages,share=on \
  -numa node,memdev=mem \
  -drive file=${DISK},if=virtio,format=qcow2,cache=none,aio=native \
  -drive file=${SEED},if=virtio,format=raw,readonly=on \
  -netdev tap,id=datanet,ifname=${DATA_TAP},script=no,downscript=no,vhost=on \
  -device virtio-net-pci,netdev=datanet,mac=${DATA_MAC} \
  -netdev tap,id=mgmtnet,ifname=${MGMT_TAP},script=no,downscript=no,vhost=on \
  -device virtio-net-pci,netdev=mgmtnet,mac=${MGMT_MAC} \
  -monitor unix:${MONITOR_SOCK},server,nowait \
  -serial file:${SERIAL_LOG} \
  -display gtk \
  &
QEMU_PID=$!
echo "${QEMU_PID}" > /tmp/qemu-${VM_NAME}.pid

### ---- Confirm started ----
sleep 2
kill -0 "${QEMU_PID}" 2>/dev/null || { echo "ERROR: qemu exited immediately - check ${SERIAL_LOG}"; exit 1; }

### ---- Pin vCPU threads (identical approach to the DPDK launch script) ----
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

echo "Launched ${VM_NAME} successfully (pure virtio / vhost-net dataplane)."
