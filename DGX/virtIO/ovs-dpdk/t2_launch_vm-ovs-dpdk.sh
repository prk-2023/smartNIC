#!/usr/bin/env bash
# t2_launch_vm.sh <1|2> — launches one VM with two virtio-net NICs:
#   ens-test: vhost-user client, connecting to OVS-DPDK's vhost-vm1/vhost-vm2 port
#             (QEMU listens as SERVER on the socket; OVS connects OUT to it as client -
#             this is the OVS-recommended "dpdkvhostuserclient" pairing) — the benchmarked path
#   ens-mgmt: QEMU SLIRP (user-mode networking) — internet + SSH, not part of the benchmark
# Run t2_host_setup.sh (OVS-DPDK version) and t2_build_guest_image.sh for this VM_NUM first.
#
# Debug console: set DEBUG_CONSOLE=1 to get -serial stdio (foreground, blocks this
# terminal, lets you log in at the console) instead of the default daemonized/log-to-file
# mode. Example: DEBUG_CONSOLE=1 ./t2_launch_vm.sh 1

set -euo pipefail
source "$(dirname "$0")/t2_config.sh"

VM_NUM="${1:?Usage: $0 <1|2>}"
[[ "$VM_NUM" == "1" || "$VM_NUM" == "2" ]] || { echo "VM_NUM must be 1 or 2"; exit 1; }

if [[ "$VM_NUM" == "1" ]]; then
    VHOST_SOCK="$VHOST_SOCK_VM1"; TEST_MAC="$VM1_TEST_MAC"
    MGMT_MAC="$MGMT_MAC_VM1"; SSH_PORT="$SSH_DNAT_PORT_VM1"
    MGMT_DHCPSTART="$MGMT_DHCPSTART_VM1"
else
    VHOST_SOCK="$VHOST_SOCK_VM2"; TEST_MAC="$VM2_TEST_MAC"
    MGMT_MAC="$MGMT_MAC_VM2"; SSH_PORT="$SSH_DNAT_PORT_VM2"
    MGMT_DHCPSTART="$MGMT_DHCPSTART_VM2"
fi

RUN="t2_vm${VM_NUM}"
DISK="$(realpath "./t2_guest-vm${VM_NUM}.qcow2")"
SEED="$(realpath "./t2_seed-vm${VM_NUM}.iso")"
MONITOR_SOCK="/tmp/qemu-monitor-${RUN}.sock"
SERIAL_LOG="/tmp/qemu-${RUN}-serial.log"
AAVMF_VARS_PERVM="/tmp/qemu-${RUN}-vars.fd"

# !!! PLACEHOLDER - Grace's cores are heterogeneous (performance + efficiency clusters).
# Run `lscpu -e` and `cat /sys/class/net/<PF>/device/numa_node` (from t2_perf_status.sh),
# then pick DISJOINT core sets for VM1 vs VM2 (they run concurrently) - reusing the same
# core numbers for both VMs would have them fight each other for the same physical cores.
if [[ "$VM_NUM" == "1" ]]; then
    VCPU_PIN=(16 17 18 19)
else
    VCPU_PIN=(20 21 22 23)
fi

[[ -f "${DISK}" ]] || { echo "ERROR: ${DISK} not found - run t2_build_guest_image.sh ${VM_NUM} first"; exit 1; }
[[ -f "${SEED}" ]] || { echo "ERROR: ${SEED} not found"; exit 1; }
[[ -f "${AAVMF_CODE}" ]] || { echo "ERROR: ${AAVMF_CODE} not found - install: sudo apt install qemu-efi-aarch64"; exit 1; }
[[ -f "${AAVMF_VARS_TEMPLATE}" ]] || { echo "ERROR: ${AAVMF_VARS_TEMPLATE} not found"; exit 1; }


if [[ "$VM_NUM" == "1" ]]; then
sudo ovs-vsctl list-ports "${BR_LEFT}"  2>/dev/null | grep -q "^vhost-vm${VM_NUM}$" \
    || { echo "ERROR: vhost-vm${VM_NUM} OVS port missing - run t2_host_setup.sh first"; exit 1; }
fi 


if [[ "$VM_NUM" == "2" ]]; then
sudo ovs-vsctl list-ports "${BR_RIGHT}" 2>/dev/null | grep -q "^vhost-vm${VM_NUM}$" \
    || { echo "ERROR: vhost-vm${VM_NUM} OVS port missing - run t2_host_setup.sh first"; exit 1; }
fi 

if [[ ${#VCPU_PIN[@]} -eq 0 ]]; then
    echo "ERROR: VCPU_PIN is an empty placeholder - run 'lscpu -e' and fill it in (see comment above)."
    exit 1
fi

FREE_HP=$(grep HugePages_Free /proc/meminfo | awk '{print $2}')
if [[ "${FREE_HP}" -lt "${HUGEPAGES_PER_VM}" ]]; then
    echo "ERROR: only ${FREE_HP} free hugepages, need ${HUGEPAGES_PER_VM} for this VM (${VM_MEM})."
    echo "       Run t2_perf_apply.sh, or check if the OTHER VM is already running and has"
    echo "       claimed the rest of the pool."
    exit 1
fi

pgrep -f "qemu-${RUN}\$" >/dev/null && { echo "ERROR: ${RUN} already running"; exit 1; }
rm -f "/tmp/qemu-${RUN}.pid" "${MONITOR_SOCK}"

cp -f "${AAVMF_VARS_TEMPLATE}" "${AAVMF_VARS_PERVM}"

# Debug console toggle: same qemu invocation either way, just the serial/daemonize tail differs.
if [[ "${DEBUG_CONSOLE:-0}" == "1" ]]; then
    SERIAL_ARGS=(-serial stdio -display none)
    DAEMON_ARGS=()
    echo "[*] DEBUG_CONSOLE=1: foreground console mode - this terminal will block until the VM exits."
    echo "    CPU pinning below will NOT run in this mode (script can't proceed until qemu exits)."
else
    SERIAL_ARGS=(-serial "file:${SERIAL_LOG}" -display none)
    DAEMON_ARGS=(-daemonize)
fi

qemu-system-aarch64 \
  -name guest,process=qemu-${RUN} \
  -machine virt,gic-version=${GIC_VERSION} \
  -accel kvm \
  -cpu host \
  -smp ${VM_VCPUS},sockets=1,cores=${VM_VCPUS},threads=1 \
  -m ${VM_MEM} \
  -drive if=pflash,format=raw,file=${AAVMF_CODE},readonly=on \
  -drive if=pflash,format=raw,file=${AAVMF_VARS_PERVM} \
  -object memory-backend-file,id=mem,size=${VM_MEM},mem-path=/dev/hugepages,share=on \
  -numa node,memdev=mem \
  -drive file=${DISK},if=virtio,format=qcow2,cache=none,aio=native \
  -drive file=${SEED},if=virtio,format=raw,readonly=on \
  -chardev socket,id=char0,path=${VHOST_SOCK},server=on \
  -netdev vhost-user,id=net0,chardev=char0,queues=${VM_VCPUS} \
  -device virtio-net-pci,netdev=net0,mq=on,vectors=$((2*VM_VCPUS+2)),mac=${TEST_MAC} \
  -netdev user,id=mgmt0,net=${MGMT_NET},host=${MGMT_GW},dns=${MGMT_DNS},dhcpstart=${MGMT_DHCPSTART},hostfwd=tcp::${SSH_PORT}-:22 \
  -device virtio-net-pci,netdev=mgmt0,mac=${MGMT_MAC} \
  -monitor unix:${MONITOR_SOCK},server,nowait \
  "${SERIAL_ARGS[@]}" \
  "${DAEMON_ARGS[@]}" \
  -pidfile /tmp/qemu-${RUN}.pid

sleep 2
[[ -f "/tmp/qemu-${RUN}.pid" ]] || { echo "ERROR: QEMU failed to start - check ${SERIAL_LOG}"; exit 1; }
QEMU_PID=$(cat "/tmp/qemu-${RUN}.pid")
kill -0 "${QEMU_PID}" 2>/dev/null || { echo "ERROR: QEMU pid ${QEMU_PID} not running - check ${SERIAL_LOG}"; exit 1; }

i=0
for tid in $(ls /proc/${QEMU_PID}/task | tail -n +2); do
    comm=$(cat /proc/${QEMU_PID}/task/${tid}/comm)
    if [[ "$comm" == CPU* ]]; then
        taskset -pc ${VCPU_PIN[$i]} ${tid}
        i=$((i+1))
    fi
done

echo "VM${VM_NUM} launched, PID ${QEMU_PID}"
echo "Serial console log: ${SERIAL_LOG}"
echo "SSH (once cloud-init finishes, ~1-2 min):"
echo "  from the DGX host itself : ssh -p ${SSH_PORT} ${GUEST_USER}@localhost"
echo "  from elsewhere (home)    : ssh -p ${SSH_PORT} ${GUEST_USER}@<dgx-real-ip>"
echo "NOTE: no vhost-net kernel threads to pin in this mode - packet polling for the test"
echo "      NIC happens in OVS-DPDK's own PMD threads, already pinned via PMD_CPU_MASK"
echo "      in t2_host_setup.sh, not per-VM kernel threads."
