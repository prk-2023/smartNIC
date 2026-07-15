#!/bin/bash
set -euo pipefail

# ============================================================================
# run_test_ovs_dpdk_dualvm.sh
# ============================================================================

RUN="${1:?Usage: $0 <run_name>   e.g. ovs_dpdk_dualvm_run1}"

VM1_MGMT_IP="192.168.50.11"
VM2_MGMT_IP="192.168.50.12"
VM2_DATA_IP="192.168.101.20"    
GUEST_USER="bench"
SSH_KEY="${SSH_KEY:-$HOME/.ssh/id_rsa}"
SSH_OPTS="-o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new -i ${SSH_KEY}"

DURATION=60
# OPTIMIZATION: Window extended to 145s to protect metric logging timeline safely
MONITOR_DURATION=145 
OUTDIR="./results/${RUN}"
mkdir -p "${OUTDIR}"

echo "===== OVS-DPDK dual-VM run: ${RUN} ====="

# ---- Pre-checks ----
ssh ${SSH_OPTS} ${GUEST_USER}@${VM1_MGMT_IP} true || { echo "ERROR: cannot reach VM1"; exit 1; }
ssh ${SSH_OPTS} ${GUEST_USER}@${VM2_MGMT_IP} true || { echo "ERROR: cannot reach VM2"; exit 1; }

# ---- PMD stats before ----
sudo ovs-appctl dpif-netdev/pmd-stats-show > "${OUTDIR}/pmd_stats_before.txt" 2>/dev/null || true

# ---- Host CPU monitoring ----
mpstat -P ALL 1 ${MONITOR_DURATION} > "${OUTDIR}/host_cpu.log" &

# ---- Start guest-side monitoring on both VMs ----
ssh ${SSH_OPTS} ${GUEST_USER}@${VM1_MGMT_IP} "sudo systemctl start guest-monitor@${RUN}.service"
ssh ${SSH_OPTS} ${GUEST_USER}@${VM2_MGMT_IP} "sudo systemctl start guest-monitor@${RUN}.service"
sleep 2

# ---- 1. TCP throughput ----
echo "[1/3] TCP throughput..."
ssh ${SSH_OPTS} ${GUEST_USER}@${VM1_MGMT_IP} \
    "iperf3 -c ${VM2_DATA_IP} -p 5201 -t ${DURATION} -P 4 -J" > "${OUTDIR}/iperf3_tcp.json"

# ---- 2. UDP small-packet PPS ----
echo "[2/3] UDP PPS (Note: limited by guest kernel socket speed)..."
ssh ${SSH_OPTS} ${GUEST_USER}@${VM1_MGMT_IP} \
    "iperf3 -c ${VM2_DATA_IP} -p 5201 -u -l 64 -b 0 -t ${DURATION} -J" > "${OUTDIR}/iperf3_udp_pps.json"

# ---- 3. Latency ----
echo "[3/3] Latency (qperf)..."
ssh ${SSH_OPTS} ${GUEST_USER}@${VM1_MGMT_IP} \
    "qperf ${VM2_DATA_IP} tcp_lat udp_lat" > "${OUTDIR}/qperf_latency.txt" 2>&1 || \
    echo "qperf failed" | tee -a "${OUTDIR}/qperf_latency.txt"

wait

# ---- PMD stats after ----
sudo ovs-appctl dpif-netdev/pmd-stats-show > "${OUTDIR}/pmd_stats_after.txt" 2>/dev/null || true
sudo ovs-appctl dpif-netdev/pmd-perf-show > "${OUTDIR}/pmd_perf_after.txt" 2>/dev/null || true

# ---- Pull guest logs from both VMs ----
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
    # OPTIMIZATION: Guard regex checks to prevent tracebacks if text is unexpected
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
                    "on their dedicated cores by design. Use 'ovs-appctl dpif-netdev/pmd-stats-show' "
                    "for precise processing vs. idle polling splits.")

with open(f"{outdir}/summary.json", "w") as f:
    json.dump(summary, f, indent=2)

print("\n===== SUMMARY =====")
for k, v in summary.items():
    print(f"  {k}: {v}")
PYEOF

echo
echo "Done. Full logs in ${OUTDIR}/"
