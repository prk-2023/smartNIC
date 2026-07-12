#!/bin/bash
set -euo pipefail

# ============================================================================
# run_test_baremetal_vf.sh
#
# Runs the Test 1 (bare-metal VF-to-VF) benchmark. Execute this ON PC1.
# It runs iperf3/qperf CLIENT locally against PC2's VF IP (reached over the
# DAC cable), while remotely starting the SERVER + monitoring on PC2 over
# PC2's NORMAL management network (e.g. your office LAN SSH access) -
# NOT over the VF/DAC path, since that's the thing being measured.
#
# Prereqs:
#   - host_vf_baremetal_setup.sh already run on both PC1 and PC2
#   - iperf3, sysstat, qperf installed on BOTH hosts (sudo dnf install ...)
#   - normal SSH access from PC1 to PC2's regular hostname/IP (management
#     network, e.g. your office LAN - NOT the isolated 192.168.101.0/24
#     VF subnet, since PC2's VF has no route back to anything but PC1's VF)
#
# Usage: ./run_test_baremetal_vf.sh <run_name>
# ============================================================================

RUN="${1:?Usage: $0 <run_name>   e.g. baremetal_vf_run1}"

# ---- Config - EDIT THESE for your environment ----
PC1_VF_IFACE="enp1s0f0v0"          # this host's VF netdev (from setup script output)
PC2_VF_IP="192.168.101.20"         # PC2's VF IP - the actual test target
PC2_MGMT_HOST="10.10.10.18"          # PC2's NORMAL ssh-reachable hostname/IP (office LAN)
PC2_MGMT_USER="daybreak"          # assumes same username on both hosts; override if not
SSH_OPTS="-o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new"

DURATION=60
MONITOR_DURATION=$((DURATION + 10))
OUTDIR="./results/${RUN}"
mkdir -p "${OUTDIR}"

echo "===== Bare-metal VF-to-VF run: ${RUN} ====="

# ---- Pre-check: can we reach PC2's management interface at all? ----
ssh ${SSH_OPTS} ${PC2_MGMT_USER}@${PC2_MGMT_HOST} true \
    || { echo "ERROR: cannot SSH to PC2 (${PC2_MGMT_HOST}) over management network"; exit 1; }

# ---- Snapshot VF counters before, on both sides ----
ethtool -S ${PC1_VF_IFACE} > "${OUTDIR}/pc1_vf_ethtool_before.txt" 2>/dev/null || true
ssh ${SSH_OPTS} ${PC2_MGMT_USER}@${PC2_MGMT_HOST} \
    "ethtool -S \$(ip -o link show | awk -F': ' '{print \$2}' | grep v0) 2>/dev/null" \
    > "${OUTDIR}/pc2_vf_ethtool_before.txt" || true

# ---- Start monitoring on BOTH physical hosts ----
# On bare metal, CPU busy% here IS the real cost of the whole datapath
# (driver + IP stack + iperf3 userspace) - this is your true floor number.
mpstat -P ALL 1 ${MONITOR_DURATION} > "${OUTDIR}/pc1_cpu.log" &

# ---- Start monitoring AND servers on PC2, all concurrent, all nohup'd ----
# BUG FIX: the naive version of this ran `mpstat ...; iperf3 -s &` - the
# semicolon made mpstat run to completion (70s) BEFORE iperf3 ever started
# listening, so the client below connected to nothing. Also, backgrounded
# remote processes get SIGHUP'd the instant the SSH session's shell exits
# unless nohup'd. Fix: launch everything with `&` (concurrent) and `nohup`
# + `disown` (survives session teardown) in one shot.
ssh ${SSH_OPTS} ${PC2_MGMT_USER}@${PC2_MGMT_HOST} "
    nohup mpstat -P ALL 1 ${MONITOR_DURATION} > /tmp/${RUN}_pc2_cpu.log 2>&1 < /dev/null &
    nohup iperf3 -s -p 5201 -1 > /tmp/${RUN}_pc2_iperf_tcp.log 2>&1 < /dev/null &
    nohup iperf3 -s -p 5202 -1 > /tmp/${RUN}_pc2_iperf_udp.log 2>&1 < /dev/null &
    nohup qperf > /tmp/${RUN}_pc2_qperf.log 2>&1 < /dev/null &
    disown -a
"
# Give the servers a moment to actually bind their ports before we connect -
# 2s was fine as a concept, the servers just weren't running yet before.
sleep 2

# ---- 1. TCP throughput ----
echo "[1/3] TCP throughput..."
iperf3 -c ${PC2_VF_IP} -p 5201 -t ${DURATION} -P 4 -J > "${OUTDIR}/iperf3_tcp.json"

# ---- 2. UDP small-packet PPS ----
echo "[2/3] UDP PPS..."
iperf3 -c ${PC2_VF_IP} -p 5202 -u -l 64 -b 20G -t ${DURATION} -J > "${OUTDIR}/iperf3_udp_pps.json"

# ---- 3. Latency ----
echo "[3/3] Latency (qperf)..."
qperf ${PC2_VF_IP} tcp_lat udp_lat > "${OUTDIR}/qperf_latency.txt" 2>&1 || \
    echo "qperf failed - confirm qperf server is running on PC2" | tee -a "${OUTDIR}/qperf_latency.txt"

wait

# ---- Pull PC2's CPU log and after-counters back ----
scp ${SSH_OPTS} ${PC2_MGMT_USER}@${PC2_MGMT_HOST}:/tmp/${RUN}_pc2_cpu.log "${OUTDIR}/pc2_cpu.log"
ethtool -S ${PC1_VF_IFACE} > "${OUTDIR}/pc1_vf_ethtool_after.txt" 2>/dev/null || true
ssh ${SSH_OPTS} ${PC2_MGMT_USER}@${PC2_MGMT_HOST} \
    "ethtool -S \$(ip -o link show | awk -F': ' '{print \$2}' | grep v0) 2>/dev/null" \
    > "${OUTDIR}/pc2_vf_ethtool_after.txt" || true

# ---- Parse and summarize (same format as the virtio/SR-IOV legs) ----
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

for host, fname, key in [("pc1", "pc1_cpu.log", "pc1_cpu_busy_pct"),
                          ("pc2", "pc2_cpu.log", "pc2_cpu_busy_pct")]:
    try:
        with open(f"{outdir}/{fname}") as f:
            lines = [l for l in f if ' all ' in l and '%idle' not in l]
        idles = [float(l.split()[-1]) for l in lines if l.split()[-1].replace('.', '', 1).isdigit()]
        if idles:
            summary[key] = round(100 - (sum(idles) / len(idles)), 2)
    except Exception as e:
        summary[key] = f"ERROR: {e}"

summary['note'] = "bare-metal VF-to-VF: no VM, no host bridge - this is the reference ceiling"

with open(f"{outdir}/summary.json", "w") as f:
    json.dump(summary, f, indent=2)

print("\n===== SUMMARY =====")
for k, v in summary.items():
    print(f"  {k}: {v}")
PYEOF

echo
echo "Done. Full logs in ${OUTDIR}/"
