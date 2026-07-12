#!/bin/bash
set -euo pipefail

# ============================================================================
# run_test_vm_vf.sh
#
# Runs the Test 2 (VM-to-VM via VF passthrough) benchmark, cross-host.
# Execute this ON PC1. VM1's mgmt IP is reachable directly (same host,
# local br-mgmt). VM2's mgmt IP is only reachable from INSIDE PC2 (its
# br-mgmt is local to PC2 and never bridged anywhere) - so we reach it
# via SSH ProxyJump: PC1 -> PC2 (management network) -> VM2 (local mgmt).
#
# IMPORTANT: both VM images must have been built with the SAME SSH public
# key (same SSH_PUBKEY_PATH when running build_sriov_vm_image.sh for both
# vm1 and vm2), so this host's private key authenticates to both VMs
# without needing the key to be present on PC2 itself - ProxyJump tunnels
# the connection through PC2 but authenticates using PC1's local key.
#
# Prereqs:
#   - host_vf_vfio_setup.sh run on both PC1 and PC2
#   - VM1 built+launched on PC1, VM2 built+launched on PC2
#     (build_sriov_vm_image.sh / launch_sriov_vm.sh from the earlier leg)
#   - normal SSH access from PC1 to PC2's regular hostname (management LAN)
#
# Usage: ./run_test_vm_vf.sh <run_name>
# ============================================================================

RUN="${1:?Usage: $0 <run_name>   e.g. vm_vf_run1}"

# ---- Config - EDIT THESE for your environment ----
VM1_MGMT_IP="192.168.50.11"        # VM1, reachable directly from PC1
VM2_MGMT_IP="192.168.50.11"        # VM2's mgmt IP as seen FROM INSIDE PC2's br-mgmt
                                     # (can reuse the same address as VM1 since the
                                     #  two br-mgmt bridges are on different hosts
                                     #  and never connected to each other)
VM2_VF_IP="192.168.101.20"         # VM2's VF IP - the actual test target, over DAC
PC2_MGMT_HOST="pc2.local"          # PC2's NORMAL ssh-reachable hostname (office LAN)
PC2_MGMT_USER="$(whoami)"
GUEST_USER="bench"
SSH_KEY="${SSH_KEY:-$HOME/.ssh/id_rsa.pub}"
SSH_OPTS="-o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new -i ${SSH_KEY}"

DURATION=60
MONITOR_DURATION=$((DURATION + 10))
OUTDIR="./results/${RUN}"
mkdir -p "${OUTDIR}"

# Helper: run a command inside VM2, tunneled through PC2
vm2_ssh() {
    ssh ${SSH_OPTS} -J ${PC2_MGMT_USER}@${PC2_MGMT_HOST} ${GUEST_USER}@${VM2_MGMT_IP} "$@"
}
vm2_scp() {
    scp ${SSH_OPTS} -o "ProxyJump=${PC2_MGMT_USER}@${PC2_MGMT_HOST}" -r \
        ${GUEST_USER}@${VM2_MGMT_IP}:"$1" "$2"
}

echo "===== VM-to-VM VF passthrough run: ${RUN} ====="

# ---- Pre-checks ----
ssh ${SSH_OPTS} ${GUEST_USER}@${VM1_MGMT_IP} true || { echo "ERROR: cannot reach VM1"; exit 1; }
vm2_ssh true || { echo "ERROR: cannot reach VM2 via PC2 jump"; exit 1; }

# ---- Host CPU monitoring on BOTH physical hosts ----
# This is the key validation metric: both should be near-zero, proving
# the VF path genuinely bypasses each host's kernel networking stack,
# same as the single-host SR-IOV design.
mpstat -P ALL 1 ${MONITOR_DURATION} > "${OUTDIR}/pc1_host_cpu.log" &
ssh ${SSH_OPTS} ${PC2_MGMT_USER}@${PC2_MGMT_HOST} \
    "mpstat -P ALL 1 ${MONITOR_DURATION} > /tmp/${RUN}_pc2_host_cpu.log" &

# ---- Start guest-side monitoring on both VMs ----
ssh ${SSH_OPTS} ${GUEST_USER}@${VM1_MGMT_IP} "sudo systemctl start guest-monitor@${RUN}.service"
vm2_ssh "sudo systemctl start guest-monitor@${RUN}.service"
sleep 2

# ---- 1. TCP throughput (VM1 -> VM2 over VF/DAC path) ----
echo "[1/3] TCP throughput..."
ssh ${SSH_OPTS} ${GUEST_USER}@${VM1_MGMT_IP} \
    "iperf3 -c ${VM2_VF_IP} -p 5201 -t ${DURATION} -P 4 -J" > "${OUTDIR}/iperf3_tcp.json"

# ---- 2. UDP small-packet PPS ----
echo "[2/3] UDP PPS..."
ssh ${SSH_OPTS} ${GUEST_USER}@${VM1_MGMT_IP} \
    "iperf3 -c ${VM2_VF_IP} -p 5201 -u -l 64 -b 20G -t ${DURATION} -J" > "${OUTDIR}/iperf3_udp_pps.json"

# ---- 3. Latency ----
echo "[3/3] Latency (qperf)..."
ssh ${SSH_OPTS} ${GUEST_USER}@${VM1_MGMT_IP} \
    "qperf ${VM2_VF_IP} tcp_lat udp_lat" > "${OUTDIR}/qperf_latency.txt" 2>&1 || \
    echo "qperf failed - check qperf-server.service on VM2" | tee -a "${OUTDIR}/qperf_latency.txt"

wait

# ---- Pull guest logs from both VMs, and PC2's host CPU log ----
until ssh ${SSH_OPTS} ${GUEST_USER}@${VM1_MGMT_IP} "test -f /var/log/bench/${RUN}/DONE" 2>/dev/null; do sleep 2; done
scp ${SSH_OPTS} -r ${GUEST_USER}@${VM1_MGMT_IP}:/var/log/bench/${RUN} "${OUTDIR}/vm1_logs"

until vm2_ssh "test -f /var/log/bench/${RUN}/DONE" 2>/dev/null; do sleep 2; done
vm2_scp "/var/log/bench/${RUN}" "${OUTDIR}/vm2_logs"

scp ${SSH_OPTS} ${PC2_MGMT_USER}@${PC2_MGMT_HOST}:/tmp/${RUN}_pc2_host_cpu.log "${OUTDIR}/pc2_host_cpu.log"

# ---- Parse and summarize (same format as previous legs) ----
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

for host, fname, key in [("pc1", "pc1_host_cpu.log", "pc1_host_cpu_busy_pct"),
                          ("pc2", "pc2_host_cpu.log", "pc2_host_cpu_busy_pct")]:
    try:
        with open(f"{outdir}/{fname}") as f:
            lines = [l for l in f if ' all ' in l and '%idle' not in l]
        idles = [float(l.split()[-1]) for l in lines if l.split()[-1].replace('.', '', 1).isdigit()]
        if idles:
            summary[key] = round(100 - (sum(idles) / len(idles)), 2)
    except Exception as e:
        summary[key] = f"ERROR: {e}"

summary['note'] = "VM-to-VM via VF passthrough: both pc*_host_cpu_busy_pct should be near-zero, confirming host-stack bypass"

with open(f"{outdir}/summary.json", "w") as f:
    json.dump(summary, f, indent=2)

print("\n===== SUMMARY =====")
for k, v in summary.items():
    print(f"  {k}: {v}")
PYEOF

echo
echo "Done. Full logs in ${OUTDIR}/"
