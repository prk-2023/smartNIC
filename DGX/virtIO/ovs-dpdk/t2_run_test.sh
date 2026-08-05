#!/usr/bin/env bash
# t2_run_test.sh <run_name> — runs the VM1<->VM2 throughput test over the virtio/vhost-net
# test path (br-left/PF0 <-> DAC <-> PF1/br-right). The host SSHes into VM1 (via the NAT'd
# mgmt network) and tells IT to run the iperf3/qperf client against VM2's test IP - the
# actual benchmarked traffic never involves the host's mgmt path at all.

set -euo pipefail
source "$(dirname "$0")/t2_config.sh"

RUN="${1:?Usage: $0 <run_name>   e.g. t2_run1}"
SSH1="ssh -o BatchMode=yes -o ConnectTimeout=5 -p ${SSH_DNAT_PORT_VM1} ${GUEST_USER}@localhost"
SSH2="ssh -o BatchMode=yes -o ConnectTimeout=5 -p ${SSH_DNAT_PORT_VM2} ${GUEST_USER}@localhost"
VM2_TEST_IP_ONLY="${VM2_TEST_IP}"
DURATION=60
MONITOR_BUFFER=10
MONITOR_DURATION=$((DURATION + MONITOR_BUFFER))

OUTDIR="./t2_results/${RUN}"
mkdir -p "${OUTDIR}"

echo "===== Run: ${RUN} ====="
echo "Output dir: ${OUTDIR}"

### ---- Pre-checks ----
$SSH1 true || { echo "ERROR: cannot SSH to VM1 (localhost:${SSH_DNAT_PORT_VM1} via SLIRP hostfwd)"; exit 1; }
$SSH2 true || { echo "ERROR: cannot SSH to VM2 (localhost:${SSH_DNAT_PORT_VM2} via SLIRP hostfwd)"; exit 1; }

### ---- Snapshot host-side PHY counters (both PFs) — the key sanity check for this topology ----
echo "[sanity] Snapshotting ${PF0}/${PF1} counters before the run"
ethtool -S "${PF0}" > "${OUTDIR}/pf0_before.txt" 2>/dev/null || true
ethtool -S "${PF1}" > "${OUTDIR}/pf1_before.txt" 2>/dev/null || true

### ---- Resolve each VM's real test-interface name by MAC (not "ens-test" literally - see t2_build_guest_image.sh fix) ----
resolve_iface_cmd() {
    local mac="$1"
    echo "for f in /sys/class/net/*/address; do grep -qi '${mac}' \"\$f\" && basename \"\$(dirname \"\$f\")\" && break; done"
}
VM1_TEST_IFACE=$($SSH1 "$(resolve_iface_cmd "$VM1_TEST_MAC")")
VM2_TEST_IFACE=$($SSH2 "$(resolve_iface_cmd "$VM2_TEST_MAC")")
echo "  VM1 test iface resolved: ${VM1_TEST_IFACE:-NOT FOUND}"
echo "  VM2 test iface resolved: ${VM2_TEST_IFACE:-NOT FOUND}"

### ---- Snapshot guest counters before ----
$SSH1 "ethtool -S ${VM1_TEST_IFACE:-unknown} 2>/dev/null; cat /proc/interrupts | grep -i virtio" > "${OUTDIR}/vm1_before.txt" || true
$SSH2 "ethtool -S ${VM2_TEST_IFACE:-unknown} 2>/dev/null; cat /proc/interrupts | grep -i virtio" > "${OUTDIR}/vm2_before.txt" || true

### ---- Host-side CPU monitor (NOT expected to be idle here — unlike PCI passthrough,
### the host's mlx5_core/bridge/vhost-net stack IS in this datapath) ----
mpstat -P ALL 1 ${MONITOR_DURATION} > "${OUTDIR}/host_cpu.log" &

### ---- Guest-side monitoring on both VMs ----
$SSH1 "sudo systemctl start guest-monitor@${RUN}.service"
$SSH2 "sudo systemctl start guest-monitor@${RUN}.service"
sleep 2

### ---- 1. Throughput (TCP) - driven from VM1, targeting VM2's real test IP ----
echo "[1/3] TCP throughput (${DURATION}s), VM1 -> VM2 over the DAC..."
$SSH1 "iperf3 -c ${VM2_TEST_IP_ONLY} -p 5201 -t ${DURATION} -P 4 -J" > "${OUTDIR}/iperf3_tcp.json"

### ---- 2. Packet rate (small-packet UDP) ----
echo "[2/3] UDP small-packet PPS (${DURATION}s)..."
$SSH1 "iperf3 -c ${VM2_TEST_IP_ONLY} -p 5201 -u -l 64 -b 5G -P 4 -t ${DURATION} -J" > "${OUTDIR}/iperf3_udp_pps.json"

### ---- 3. Latency ----
echo "[3/3] Latency (qperf tcp_lat, udp_lat)..."
$SSH1 "qperf ${VM2_TEST_IP_ONLY} tcp_lat udp_lat" > "${OUTDIR}/qperf_latency.txt" 2>&1 || \
    echo "qperf failed - check qperf-server.service status on VM2" | tee -a "${OUTDIR}/qperf_latency.txt"

wait

### ---- Snapshot counters after ----
ethtool -S "${PF0}" > "${OUTDIR}/pf0_after.txt" 2>/dev/null || true
ethtool -S "${PF1}" > "${OUTDIR}/pf1_after.txt" 2>/dev/null || true
$SSH1 "ethtool -S ${VM1_TEST_IFACE:-unknown} 2>/dev/null" > "${OUTDIR}/vm1_after.txt" || true
$SSH2 "ethtool -S ${VM2_TEST_IFACE:-unknown} 2>/dev/null" > "${OUTDIR}/vm2_after.txt" || true

### ---- PHY usage sanity check: did traffic actually cross the DAC between PF0 and PF1? ----
for LABEL_IFACE in "PF0:${PF0}" "PF1:${PF1}"; do
    LABEL="${LABEL_IFACE%%:*}"; IFACE="${LABEL_IFACE##*:}"
    BEFORE="${OUTDIR}/${LABEL,,}_before.txt"; AFTER="${OUTDIR}/${LABEL,,}_after.txt"
    TX_BEFORE=$(awk -F': ' '/^ *tx_packets:/{print $2; exit}' "$BEFORE" 2>/dev/null)
    TX_AFTER=$(awk -F': ' '/^ *tx_packets:/{print $2; exit}' "$AFTER" 2>/dev/null)
    if [[ -n "$TX_BEFORE" && -n "$TX_AFTER" ]]; then
        DELTA=$((TX_AFTER - TX_BEFORE))
        echo "  ${LABEL} (${IFACE}) tx_packets delta during this run: ${DELTA}"
        [[ "$DELTA" -lt 1000 ]] && echo "  !!! WARNING: ${LABEL} saw almost no TX traffic - check br-left/br-right wiring"
    fi
done

### ---- Pull guest monitor logs ----
for VM in 1 2; do
    SSH_VAR="SSH${VM}"
    SSH_CMD="${!SSH_VAR}"
    PORT_VAR="SSH_DNAT_PORT_VM${VM}"
    PORT="${!PORT_VAR}"
    until $SSH_CMD "test -f /var/log/bench/${RUN}/DONE" 2>/dev/null; do sleep 2; done
    scp -rq -P "${PORT}" -o BatchMode=yes "${GUEST_USER}@localhost:/var/log/bench/${RUN}" "${OUTDIR}/vm${VM}_guest_logs"
done

### ---- Parse and summarize ----
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
    lost_pct = d['end']['sum'].get('lost_percent', 0)
    summary['udp_pps'] = round(sent / dur, 0)
    summary['udp_lost_percent'] = round(lost_pct, 3)
except Exception as e:
    summary['udp_pps'] = f"ERROR: {e}"

try:
    with open(f"{outdir}/qperf_latency.txt") as f:
        txt = f.read()
    tcp_lat = re.search(r'tcp_lat:\s*\n\s*latency\s*=\s*([\d.]+)\s*(\w+)', txt)
    udp_lat = re.search(r'udp_lat:\s*\n\s*latency\s*=\s*([\d.]+)\s*(\w+)', txt)
    summary['tcp_latency'] = f"{tcp_lat.group(1)} {tcp_lat.group(2)}" if tcp_lat else "not found (check qperf_latency.txt raw output)"
    summary['udp_latency'] = f"{udp_lat.group(1)} {udp_lat.group(2)}" if udp_lat else "not found (check qperf_latency.txt raw output)"
except Exception as e:
    summary['latency'] = f"ERROR: {e}"

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
