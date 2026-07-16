#!/bin/bash
set -euo pipefail

### ---- Config ----
RUN="${1:?Usage: $0 <run_name>   e.g. virtio_tcp_run1}"
GUEST_IP="192.168.100.10"
GUEST_USER="bench"
HOST_IFACE="enp1s0f1np1"     # port1 - the host-side interface completing the DAC loop
DURATION=60
MONITOR_BUFFER=10             # extra seconds so monitors outlast the workload
MONITOR_DURATION=$((DURATION + MONITOR_BUFFER))

OUTDIR="./results/${RUN}"
mkdir -p "${OUTDIR}"

echo "===== Run: ${RUN} ====="
echo "Output dir: ${OUTDIR}"

### ---- Pre-checks ----
ssh -o BatchMode=yes -o ConnectTimeout=5 ${GUEST_USER}@${GUEST_IP} true \
    || { echo "ERROR: cannot SSH to guest at ${GUEST_IP}"; exit 1; }

### ---- Snapshot counters before ----
ethtool -S ${HOST_IFACE} > "${OUTDIR}/ethtool_host_before.txt" 2>/dev/null || true
cat /proc/interrupts > "${OUTDIR}/interrupts_host_before.txt"
ssh ${GUEST_USER}@${GUEST_IP} "ethtool -S ens3 2>/dev/null; cat /proc/interrupts | grep virtio" \
    > "${OUTDIR}/guest_before.txt" || true

### ---- Start host-side monitoring (self-terminating) ----
mpstat -P ALL 1 ${MONITOR_DURATION}  > "${OUTDIR}/host_cpu.log" &
QEMU_PID=$(pgrep -f "qemu-.*${RUN%%_*}" || pidof qemu-system-x86_64 || true)
if [[ -n "${QEMU_PID}" ]]; then
    pidstat -t -p "${QEMU_PID}" 1 ${MONITOR_DURATION} > "${OUTDIR}/qemu_threads.log" &
fi
sar -n DEV 1 ${MONITOR_DURATION}     > "${OUTDIR}/host_network.log" &

### ---- Start guest-side monitoring ----
ssh ${GUEST_USER}@${GUEST_IP} "sudo systemctl start guest-monitor@${RUN}.service"

# give monitors a moment to actually start sampling before workload begins
sleep 2

### ---- 1. Throughput (TCP) ----
echo "[1/3] TCP throughput (${DURATION}s)..."
iperf3 -c ${GUEST_IP} -p 5201 -t ${DURATION} -P 4 -J > "${OUTDIR}/iperf3_tcp.json"

### ---- 2. Packet rate (small-packet UDP) ----
echo "[2/3] UDP small-packet PPS (${DURATION}s)..."
iperf3 -c ${GUEST_IP} -p 5201 -u -l 64 -b 5G -t ${DURATION} -J > "${OUTDIR}/iperf3_udp_pps.json"

### ---- 3. Latency ----
echo "[3/3] Latency (qperf tcp_lat, udp_lat)..."
qperf ${GUEST_IP} tcp_lat udp_lat > "${OUTDIR}/qperf_latency.txt" 2>&1 || \
    echo "qperf failed - check qperf-server.service status on guest" | tee -a "${OUTDIR}/qperf_latency.txt"

### ---- Wait for monitors to finish ----
wait

### ---- Snapshot counters after ----
ethtool -S ${HOST_IFACE} > "${OUTDIR}/ethtool_host_after.txt" 2>/dev/null || true
cat /proc/interrupts > "${OUTDIR}/interrupts_host_after.txt"

### ---- Pull guest logs ----
until ssh ${GUEST_USER}@${GUEST_IP} "test -f /var/log/bench/${RUN}/DONE" 2>/dev/null; do
    sleep 2
done
scp -rq ${GUEST_USER}@${GUEST_IP}:/var/log/bench/${RUN} "${OUTDIR}/guest_logs"
ssh ${GUEST_USER}@${GUEST_IP} "ethtool -S ens3 2>/dev/null" > "${OUTDIR}/guest_after.txt" || true

### ---- Parse and summarize ----
python3 - "${OUTDIR}" <<'PYEOF'
import json, sys, os, re

outdir = sys.argv[1]
summary = {}

# TCP throughput
try:
    with open(f"{outdir}/iperf3_tcp.json") as f:
        d = json.load(f)
    summary['tcp_throughput_gbps'] = round(d['end']['sum_received']['bits_per_second'] / 1e9, 2)
except Exception as e:
    summary['tcp_throughput_gbps'] = f"ERROR: {e}"

# UDP PPS
try:
    with open(f"{outdir}/iperf3_udp_pps.json") as f:
        d = json.load(f)
    sent = d['end']['sum']['packets']
    dur = d['end']['sum']['seconds']
    lost_pct = d['end']['sum'].get('lost_percent', 0)
    summary['udp_pps'] = round(sent / dur, 0)
    summary['udp_lost_percent'] = round(lost_pct, 3)
except Exception as e:
    summary['udp_pps'] = f"ERROR: {e}"

# Latency (qperf plain text output)
try:
    with open(f"{outdir}/qperf_latency.txt") as f:
        txt = f.read()
    tcp_lat = re.search(r'tcp_lat:\s*\n\s*latency\s*=\s*([\d.]+)\s*(\w+)', txt)
    udp_lat = re.search(r'udp_lat:\s*\n\s*latency\s*=\s*([\d.]+)\s*(\w+)', txt)
    summary['tcp_latency'] = f"{tcp_lat.group(1)} {tcp_lat.group(2)}" if tcp_lat else "not found"
    summary['udp_latency'] = f"{udp_lat.group(1)} {udp_lat.group(2)}" if udp_lat else "not found"
except Exception as e:
    summary['latency'] = f"ERROR: {e}"

# Host CPU average (last column avg across all cores, 'all' row)
try:
    with open(f"{outdir}/host_cpu.log") as f:
        lines = [l for l in f if ' all ' in l and '%idle' not in l]
    idles = [float(l.split()[-1]) for l in lines if l.split()[-1].replace('.','',1).isdigit()]
    if idles:
        avg_idle = sum(idles) / len(idles)
        summary['host_cpu_busy_pct'] = round(100 - avg_idle, 2)
except Exception as e:
    summary['host_cpu_busy_pct'] = f"ERROR: {e}"

with open(f"{outdir}/summary.json", "w") as f:
    json.dump(summary, f, indent=2)

print("\n===== SUMMARY =====")
for k, v in summary.items():
    print(f"  {k}: {v}")
PYEOF

echo
echo "Done. Full logs in ${OUTDIR}/"
echo "Summary: ${OUTDIR}/summary.json"
