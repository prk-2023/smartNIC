#!/usr/bin/env bash
# t2_perf_status.sh — READ-ONLY audit of settings relevant to VirtIO/vhost-net VM<->VM
# network performance. Makes no changes. Run t2_perf_apply.sh to fix WARN/FAIL items.

set -uo pipefail
source "$(dirname "$0")/t2_config.sh"

PASS=0; WARN=0; FAIL=0
row() {
    local status="$1" label="$2" detail="$3"
    case "$status" in
        PASS) PASS=$((PASS+1)); printf "  [PASS] %-42s %s\n" "$label" "$detail" ;;
        WARN) WARN=$((WARN+1)); printf "  [WARN] %-42s %s\n" "$label" "$detail" ;;
        FAIL) FAIL=$((FAIL+1)); printf "  [FAIL] %-42s %s\n" "$label" "$detail" ;;
    esac
}

echo "===== t2 performance audit (VirtIO/vhost-net path) ====="

echo; echo "-- IOMMU / SMMU --"
if dmesg 2>/dev/null | grep -qi "arm-smmu-v3.*ias.*oas" || journalctl -k 2>/dev/null | grep -qi "arm-smmu-v3.*ias.*oas"; then
    row PASS "SMMU active" "confirmed via kernel log"
else
    row WARN "SMMU active" "could not confirm (dmesg ring buffer may have scrolled) - check 'journalctl -k | grep -i smmu'"
fi

echo; echo "-- vhost-net --"
lsmod | grep -q "^vhost_net" \
    && row PASS "vhost_net module" "loaded" \
    || row WARN "vhost_net module" "not loaded - t2_perf_apply.sh will load it"
[[ -e /dev/vhost-net ]] \
    && row PASS "/dev/vhost-net" "present" \
    || row WARN "/dev/vhost-net" "missing - depends on vhost_net module load above"

echo; echo "-- PF driver + multiqueue (host processes traffic via mlx5_core for this test) --"
for BDF_IFACE in "PF0:${PF0}" "PF1:${PF1}"; do
    LABEL="${BDF_IFACE%%:*}"; IFACE="${BDF_IFACE##*:}"
    if [[ -e "/sys/class/net/${IFACE}" ]]; then
        DRV=$(basename "$(readlink -f "/sys/class/net/${IFACE}/device/driver" 2>/dev/null)" 2>/dev/null || echo "unknown")
        [[ "$DRV" == "mlx5_core" ]] \
            && row PASS "${LABEL} (${IFACE}) driver" "mlx5_core - correct for a bridged/virtio path" \
            || row WARN "${LABEL} (${IFACE}) driver" "${DRV} - expected mlx5_core; if this was previously used for PCI passthrough (vfio-pci), rebind it first"
        QUEUES=$(ethtool -l "${IFACE}" 2>/dev/null | awk '/Combined:/{print $2; exit}')
        row PASS "${LABEL} (${IFACE}) queue count" "${QUEUES:-unknown} combined queues (multiqueue helps vhost-net scale across vCPUs)"
    else
        row FAIL "${LABEL} (${IFACE})" "interface not found - check 'ip -br link', may still be bound to vfio-pci from a prior t2 (passthrough) run"
    fi
done

echo; echo "-- NIC offloads (host-side, matters here since traffic transits the host's mlx5_core + bridge, unlike passthrough) --"
for BDF_IFACE in "PF0:${PF0}" "PF1:${PF1}"; do
    LABEL="${BDF_IFACE%%:*}"; IFACE="${BDF_IFACE##*:}"
    [[ -e "/sys/class/net/${IFACE}" ]] || continue
    for FEATURE in tx-checksumming rx-checksumming tcp-segmentation-offload generic-receive-offload; do
        STATE=$(ethtool -k "${IFACE}" 2>/dev/null | awk -F': ' -v f="$FEATURE" '$1==f{print $2}' | awk '{print $1}')
        [[ "$STATE" == "on" ]] \
            && row PASS "${LABEL} ${FEATURE}" "on" \
            || row WARN "${LABEL} ${FEATURE}" "${STATE:-unknown} - offloads generally help virtio-net throughput, t2_perf_apply.sh will enable"
    done
done

echo; echo "-- Hugepages --"
if [[ -d "/sys/kernel/mm/hugepages/hugepages-${HUGEPAGE_SIZE_KB}kB" ]]; then
    row PASS "${HUGEPAGE_SIZE_KB}kB hugepage size supported" "matches HUGEPAGE_SIZE_KB in t2_config.sh"
else
    AVAIL=$(ls /sys/kernel/mm/hugepages/ 2>/dev/null | tr '\n' ' ')
    row FAIL "${HUGEPAGE_SIZE_KB}kB hugepage size NOT supported" "available on this platform: ${AVAIL:-none} - update HUGEPAGE_SIZE_KB in t2_config.sh"
fi
CURRENT_HP=$(grep HugePages_Total /proc/meminfo | awk '{print $2}')
FREE_HP=$(grep HugePages_Free /proc/meminfo | awk '{print $2}')
if [[ "$CURRENT_HP" -ge "$TOTAL_HUGEPAGES" ]]; then
    row PASS "Hugepages allocated" "${CURRENT_HP} total, ${FREE_HP} free (need ${TOTAL_HUGEPAGES} for 2x ${VM_MEM} VMs)"
else
    row WARN "Hugepages allocated" "${CURRENT_HP} total, need ${TOTAL_HUGEPAGES} - t2_perf_apply.sh will fix"
fi
mountpoint -q /dev/hugepages \
    && row PASS "hugetlbfs mounted" "/dev/hugepages" \
    || row WARN "hugetlbfs mounted" "not mounted - t2_perf_apply.sh will fix"

echo; echo "-- NUMA topology and PF affinity --"
NUMA_NODES=$(lscpu | awk -F: '/NUMA node\(s\)/{print $2}' | tr -d ' ')
row PASS "NUMA node count" "${NUMA_NODES:-unknown} (Grace is a single SoC - multiple nodes would be unusual, but don't assume, check)"
for BDF_IFACE in "PF0:${PF0}" "PF1:${PF1}"; do
    LABEL="${BDF_IFACE%%:*}"; IFACE="${BDF_IFACE##*:}"
    [[ -e "/sys/class/net/${IFACE}" ]] || continue
    NODE=$(cat "/sys/class/net/${IFACE}/device/numa_node" 2>/dev/null || echo "unknown")
    row PASS "${LABEL} (${IFACE}) NUMA node" "${NODE} (pin that VM's vCPUs + vhost threads to cores on this node in t2_launch_vm.sh)"
done

echo; echo "-- CPU governor / idle states --"
GOV_SAMPLE=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo "unavailable")
[[ "$GOV_SAMPLE" == "performance" ]] \
    && row PASS "CPU governor" "performance" \
    || row WARN "CPU governor" "cpu0=${GOV_SAMPLE}, want 'performance' - t2_perf_apply.sh will fix"
DEEP_STATES_ENABLED=$(for f in /sys/devices/system/cpu/cpu0/cpuidle/state*/disable; do [[ -f "$f" ]] && cat "$f"; done | grep -c '^0' || true)
if [[ "${DEEP_STATES_ENABLED:-0}" -le 1 ]]; then
    row PASS "Deep C-states" "disabled (only shallow/no idle state active)"
else
    row WARN "Deep C-states" "${DEEP_STATES_ENABLED} idle states still enabled on cpu0 - adds wake latency, t2_perf_apply.sh can disable"
fi

echo; echo "-- KSM / THP --"
KSM=$(cat /sys/kernel/mm/ksm/run 2>/dev/null || echo "unavailable")
[[ "$KSM" == "0" ]] && row PASS "KSM" "off" || row WARN "KSM" "run=${KSM} (want 0) - adds background CPU scanning overhead"
THP=$(cat /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null | grep -oP '\[\K[^\]]+' || echo "unavailable")
[[ "$THP" == "madvise" || "$THP" == "never" ]] \
    && row PASS "THP" "${THP}" \
    || row WARN "THP" "${THP} (want madvise/never - 'always' can cause khugepaged compaction jitter during benchmarks)"

echo; echo "-- irqbalance --"
systemctl is-active --quiet irqbalance 2>/dev/null \
    && row WARN "irqbalance" "active - can fight manual IRQ/CPU pinning, t2_perf_apply.sh will stop it" \
    || row PASS "irqbalance" "inactive"

echo; echo "-- Bridges (informational — expect these to NOT exist yet if t2_host_setup.sh hasn't run) --"
for BR in "$BR_LEFT" "$BR_RIGHT"; do
    ip link show "$BR" &>/dev/null \
        && row PASS "${BR}" "exists" \
        || row WARN "${BR}" "does not exist yet - normal before t2_host_setup.sh, otherwise run it"
done

echo
echo "===== Summary: ${PASS} pass, ${WARN} warn, ${FAIL} fail ====="
[[ "$FAIL" -gt 0 ]] && echo "FAIL items should be resolved first (esp. missing PF interfaces)."
[[ "$WARN" -gt 0 ]] && echo "Run t2_perf_apply.sh to fix WARN items (some require a reboot - it will tell you which)."
exit 0
