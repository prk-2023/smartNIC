#!/bin/bash
set -euo pipefail

# ============================================================================
# run_test_ovs_dpdk_dualvm.sh
#
# Runs the four-metric benchmark between VM1 and VM2, both on THIS host.
# Simpler than the SR-IOV cross-host version (run_test_vm_vf.sh) - both
# VMs' mgmt IPs are directly reachable, no SSH ProxyJump needed.
#
# VM1 acts as iperf3/qperf CLIENT, VM2 as SERVER. Traffic between them
# crosses: VM1 -> vhost-user0 -> br-left -> dpdk0(port0) -> DAC ->
# dpdk1(port1) -> br-right -> vhost-user1 -> VM2. Fully kernel-bypassed
# on the host side, single vhost-user hop per VM - directly comparable
# to the Native VirtIO and single-port OVS-DPDK legs' numbers.
# ============================================================================

RUN="${1:?Usage: $0 <run_name>   e.g. ovs_dpdk_dualvm_run1}"

VM1_MGMT_IP="192.168.50.11"
VM2_MGMT_IP="192.168.50.12"
VM2_DATA_IP="192.168.101.20"    # VM2's vhost-user-side IP - actual test target
GUEST_USER="bench"
SSH_KEY="${SSH_KEY:-$HOME/.ssh/id_rsa.pub}"
SSH_OPTS="-o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new -i ${SSH_KEY}"

DURATION=60
MONITOR_DURATION=$((DURATION + 10))
OUTDIR="./results/${RUN}"
mkdir -p "${OUTDIR}"

echo "===== OVS-DPDK dual-VM run: ${RUN} ====="

# ---- Pre-checks ----
ssh ${SSH_OPTS} ${GUEST_USER}@${VM1_MGMT_IP} true || { echo "ERROR: cannot reach VM1"; exit 1; }
ssh ${SSH_OPTS} ${GUEST_USER}@${VM2_MGMT_IP} true || { echo "ERROR: cannot reach VM2"; exit 1; }

# ---- PMD stats before (covers both br-left and br-right - one vswitchd instance) ----
sudo ovs-appctl dpif-netdev/pmd-stats-show > "${OUTDIR}/pmd_stats_before.txt" 2>/dev/null || true

# ---- Host CPU monitoring - expect near-zero on the DATA path cores, but
# note the PMD-assigned cores (2,3) WILL show ~100% by design (busy-poll).
# mpstat here captures ALL cores, so both effects are visible in one log -
# explain the PMD cores' number in the report, don't just quote the average.
mpstat -P ALL 1 ${MONITOR_DURATION} > "${OUTDIR}/host_cpu.log" &

# ---- Start guest-side monitoring on both VMs ----
ssh ${SSH_OPTS} ${GUEST_USER}@${VM1_MGMT_IP} "sudo systemctl start guest-monitor@${RUN}.service"
ssh ${SSH_OPTS} ${GUEST_USER}@${VM2_MGMT_IP} "sudo systemctl start guest-monitor@${RUN}.service"
sleep 2

# ---- 1. TCP throughput ----
echo "[1/3] TCP throughput..."
ssh ${SSH_OPTS} ${GUEST_USER}@${VM1_MGMT_IP} \
    "iperf3 -c ${VM2_DATA_IP} -p 5201 -t ${DURATION} -P 4 -J" > "${OUTDIR}/iperf3_tcp.json"

# ---- 2. UDP small-packet PPS - unlimited offered load (-b 0), same as other legs ----
echo "[2/3] UDP PPS..."
ssh ${SSH_OPTS} ${GUEST_USER}@${VM1_MGMT_IP} \
    "iperf3 -c ${VM2_DATA_IP} -p 5201 -u -l 64 -b 0 -t ${DURATION} -J" > "${OUTDIR}/iperf3_udp_pps.json"

# ---- 3. Latency ----
echo "[3/3] Latency (qperf)..."
ssh ${SSH_OPTS} ${GUEST_USER}@${VM1_MGMT_IP} \
    "qperf ${VM2_DATA_IP} tcp_lat udp_lat" > "${OUTDIR}/qperf_latency.txt" 2>&1 || \
    echo "qperf failed - check qperf-server.service on VM2" | tee -a "${OUTDIR}/qperf_latency.txt"

wait

# ---- PMD stats after ----
sudo ovs-appctl dpif-netdev/pmd-stats-show > "${OUTDIR}/pmd_stats_after.txt" 2>/dev/null || true
sudo ovs-appctl dpif-netdev/pmd-perf-show > "${OUTDIR}/pmd_perf_after.txt" 2>/dev/null || true

# ---- Pull guest logs from both VMs ----
# NOTE: guest-monitor.sh (inherited from build_sriov_vm_image.sh) looks for
# a driver=mlx5_core interface to snapshot ethtool stats - that check will
# find NOTHING here, since this leg's dataplane NIC is plain virtio-net
# (guest can't tell vhost-net from vhost-user apart). That's a known,
# harmless gap: only the optional ethtool_vf_after.txt file ends up empty,
# the core four metrics below are unaffected.
for VM in VM1:${VM1_MGMT_IP} VM2:${VM2_MGMT_IP}; do
    NAME="${VM%%:*}"; IP="${VM##*:}"
    until ssh ${SSH_OPTS} ${GUEST_USER}@${IP} "test -f /var/log/bench/${RUN}/DONE" 2>/dev/null; do sleep 2; done
    scp -rq ${SSH_OPTS} ${GUEST_USER}@${IP}:/var/log/bench/${RUN} "${OUTDIR}/${NAME}_logs"
done

# ---- Parse and summarize ----
python3 - "${OUTDIR}" <<'PYEOF'
import json, sys, re

outdir = sys.argv[1]
summary = {}

try:
    with open(f"{outdir}/iperf3_tcp.json") as f:
        d = json.load(f)
    summary['tcp_throughput_gbps'] = round(d['end']['sum_received']['bits_per_second'] / 1e9, 2)
except Exception as e:
    summary['tcp_throughput_gbps'] = f"ERROR: {e}"

try:
    with open(f"{outdir}/iperf3_udp_pps.json") as f:
        d = json.load(f)
    sent = d['end']['sum']['packets']
    dur = d['end']['sum']['seconds']
    summary['udp_pps'] = round(sent / dur, 0)
    summary['udp_lost_percent'] = round(d['end']['sum'].get('lost_percent', 0), 3)
except Exception as e:
    summary['udp_pps'] = f"ERROR: {e}"

try:
    with open(f"{outdir}/qperf_latency.txt") as f:
        txt = f.read()
    tcp_lat = re.search(r'tcp_lat:\s*\n\s*latency\s*=\s*([\d.]+)\s*(\w+)', txt)
    udp_lat = re.search(r'udp_lat:\s*\n\s*latency\s*=\s*([\d.]+)\s*(\w+)', txt)
    summary['tcp_latency'] = f"{tcp_lat.group(1)} {tcp_lat.group(2)}" if tcp_lat else "not found"
    summary['udp_latency'] = f"{udp_lat.group(1)} {udp_lat.group(2)}" if udp_lat else "not found"
except Exception as e:
    summary['latency'] = f"ERROR: {e}"

try:
    with open(f"{outdir}/host_cpu.log") as f:
        lines = [l for l in f if ' all ' in l and '%idle' not in l]
    idles = [float(l.split()[-1]) for l in lines if l.split()[-1].replace('.', '', 1).isdigit()]
    if idles:
        summary['host_cpu_busy_pct'] = round(100 - (sum(idles) / len(idles)), 2)
except Exception as e:
    summary['host_cpu_busy_pct'] = f"ERROR: {e}"

summary['note'] = ("host_cpu_busy_pct includes PMD threads busy-polling at ~100% "
                    "on their dedicated cores by design - see pmd_perf_after.txt "
                    "for the cycles-per-packet breakdown, don't read the raw "
                    "average as a straight regression vs the virtio leg")

with open(f"{outdir}/summary.json", "w") as f:
    json.dump(summary, f, indent=2)

print("\n===== SUMMARY =====")
for k, v in summary.items():
    print(f"  {k}: {v}")
PYEOF

echo
echo "Done. Full logs in ${OUTDIR}/"
