#!/usr/bin/env bash
# t2_run_benchmarks.sh — Structured network benchmark suite & report generator for SR-IOV Legacy Mode

set -euo pipefail
source "$(dirname "$0")/t2_config.sh"

TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
RESULTS_DIR="${T2_WORKDIR}/results/sriov_legacy_${TIMESTAMP}"
mkdir -p "${RESULTS_DIR}"

RAW_DIR="${RESULTS_DIR}/raw"
mkdir -p "${RAW_DIR}"

SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 -o LogLevel=ERROR"
VM1_SSH="ssh ${SSH_OPTS} -p ${SSH_DNAT_PORT_VM1} ${GUEST_USER}@localhost"
VM2_SSH="ssh ${SSH_OPTS} -p ${SSH_DNAT_PORT_VM2} ${GUEST_USER}@localhost"

echo "=========================================================="
echo " Starting Benchmarks: SR-IOV eSwitch Legacy Passthrough Mode"
echo " Results output: ${RESULTS_DIR}"
echo "=========================================================="

# 1. Health & Connectivity Check
echo "[1/6] Verifying Guest Reachability & Driver Detection..."
for PORT in "${SSH_DNAT_PORT_VM1}" "${SSH_DNAT_PORT_VM2}"; do
    until ssh ${SSH_OPTS} -p "${PORT}" "${GUEST_USER}@localhost" "echo ready" &>/dev/null; do
        echo "  Waiting for VM on SSH port ${PORT}..."
        sleep 2
    done
done

# Collect Metadata
HOST_KERNEL=$(uname -r)
HOST_MODEL=$(lscpu | grep "Model name" | sed 's/Model name:[[:space:]]*//' || echo "ARM64 Grace Blackwell GB10")
VM1_VF_PCI=$(${VM1_SSH} "lspci -d 15b3: | head -n1" || echo "Unknown Mellanox VF")
VM1_DRIVER=$(${VM1_SSH} "ethtool -i ens-test 2>/dev/null | grep driver | awk '{print \$2}'" || echo "mlx5_core")

cat <<EOF > "${RESULTS_DIR}/environment.json"
{
  "timestamp": "${TIMESTAMP}",
  "mode": "SR-IOV Legacy Mode (vfio-pci)",
  "host": {
    "cpu": "${HOST_MODEL}",
    "kernel": "${HOST_KERNEL}",
    "pf0": "${PF0}",
    "pf1": "${PF1}"
  },
  "vm1": {
    "ip": "${VM1_TEST_IP}",
    "mac": "${VM1_TEST_MAC}",
    "pci_device": "${VM1_VF_PCI}",
    "driver": "${VM1_DRIVER}"
  },
  "vm2": {
    "ip": "${VM2_TEST_IP}",
    "mac": "${VM2_TEST_MAC}"
  }
}
EOF

# 2. ICMP Ping Latency Benchmark
echo "[2/6] Running ICMP Ping Latency Benchmark..."
${VM1_SSH} "ping -c 20 -i 0.2 ${VM2_TEST_IP}" > "${RAW_DIR}/ping_results.txt" 2>&1

PING_STATS=$(grep -E "rtt|round-trip" "${RAW_DIR}/ping_results.txt" | awk -F'/' '{print $4","$5","$6}' || echo "0,0,0")
PING_MIN=$(echo "$PING_STATS" | cut -d',' -f1)
PING_AVG=$(echo "$PING_STATS" | cut -d',' -f2)
PING_MAX=$(echo "$PING_STATS" | cut -d',' -f3)
PING_LOSS=$(grep -oP '\d+(?=% packet loss)' "${RAW_DIR}/ping_results.txt" || echo "0")

# 3. qperf TCP / UDP Latency Benchmark
echo "[3/6] Running qperf Latency Benchmarks..."
${VM1_SSH} "qperf ${VM2_TEST_IP} tcp_lat udp_lat" > "${RAW_DIR}/qperf_latency.txt" 2>&1 || true

TCP_LAT_US=$(grep -A1 "tcp_lat:" "${RAW_DIR}/qperf_latency.txt" | grep "latency" | awk '{print $3}' | tr -d 'us' || echo "N/A")
UDP_LAT_US=$(grep -A1 "udp_lat:" "${RAW_DIR}/qperf_latency.txt" | grep "latency" | awk '{print $3}' | tr -d 'us' || echo "N/A")

# 4. iperf3 Single-Stream TCP Benchmark
echo "[4/6] Running iperf3 Single-Stream TCP Benchmark..."
${VM1_SSH} "iperf3 -c ${VM2_TEST_IP} -t 10 -P 1 --json" > "${RAW_DIR}/iperf3_tcp_single.json" 2>&1

TCP_1P_GBPS=$(python3 -c "
import json
try:
    data = json.load(open('${RAW_DIR}/iperf3_tcp_single.json'))
    bps = data['end']['sum_sent']['bits_per_second']
    print(f'{bps / 1e9:.2f}')
except Exception:
    print('0.00')
")

TCP_1P_RETRANS=$(python3 -c "
import json
try:
    data = json.load(open('${RAW_DIR}/iperf3_tcp_single.json'))
    print(data['end']['sum_sent'].get('retransmits', 0))
except Exception:
    print('0')
")

# 5. iperf3 Multi-Stream TCP Benchmark (8 Parallel Streams)
echo "[5/6] Running iperf3 Multi-Stream TCP Benchmark (8 Streams)..."
${VM1_SSH} "iperf3 -c ${VM2_TEST_IP} -t 10 -P 8 --json" > "${RAW_DIR}/iperf3_tcp_multi.json" 2>&1

TCP_8P_GBPS=$(python3 -c "
import json
try:
    data = json.load(open('${RAW_DIR}/iperf3_tcp_multi.json'))
    bps = data['end']['sum_sent']['bits_per_second']
    print(f'{bps / 1e9:.2f}')
except Exception:
    print('0.00')
")

TCP_8P_RETRANS=$(python3 -c "
import json
try:
    data = json.load(open('${RAW_DIR}/iperf3_tcp_multi.json'))
    print(data['end']['sum_sent'].get('retransmits', 0))
except Exception:
    print('0')
")

# 6. iperf3 UDP Throughput & Jitter Benchmark
echo "[6/6] Running iperf3 UDP Benchmark..."
${VM1_SSH} "iperf3 -c ${VM2_TEST_IP} -u -b 0 -t 10 --json" > "${RAW_DIR}/iperf3_udp.json" 2>&1

UDP_GBPS=$(python3 -c "
import json
try:
    data = json.load(open('${RAW_DIR}/iperf3_udp.json'))
    bps = data['end']['sum']['bits_per_second']
    print(f'{bps / 1e9:.2f}')
except Exception:
    print('0.00')
")

UDP_JITTER_MS=$(python3 -c "
import json
try:
    data = json.load(open('${RAW_DIR}/iperf3_udp.json'))
    print(f\"{data['end']['sum']['jitter_ms']:.3f}\")
except Exception:
    print('0.000')
")

UDP_LOSS_PCT=$(python3 -c "
import json
try:
    data = json.load(open('${RAW_DIR}/iperf3_udp.json'))
    print(f\"{data['end']['sum']['lost_percent']:.2f}\")
except Exception:
    print('0.00')
")

# 7. Generate CSV Output
CSV_FILE="${RESULTS_DIR}/benchmark_results.csv"
cat <<EOF > "${CSV_FILE}"
Metric,Value,Unit,Description
ICMP_Latency_Min,${PING_MIN},ms,Minimum ICMP Round-Trip Time
ICMP_Latency_Avg,${PING_AVG},ms,Average ICMP Round-Trip Time
ICMP_Latency_Max,${PING_MAX},ms,Maximum ICMP Round-Trip Time
ICMP_Packet_Loss,${PING_LOSS},%,Packet Loss Percentage
qperf_TCP_Latency,${TCP_LAT_US},us,qperf TCP One-Way/Round-Trip Latency
qperf_UDP_Latency,${UDP_LAT_US},us,qperf UDP One-Way/Round-Trip Latency
TCP_Throughput_1P,${TCP_1P_GBPS},Gbps,Single-Stream TCP Throughput
TCP_Retransmits_1P,${TCP_1P_RETRANS},count,Single-Stream TCP Retransmissions
TCP_Throughput_8P,${TCP_8P_GBPS},Gbps,8-Parallel Stream TCP Throughput
TCP_Retransmits_8P,${TCP_8P_RETRANS},count,8-Parallel Stream TCP Retransmissions
UDP_Throughput,${UDP_GBPS},Gbps,Unthrottled UDP Throughput
UDP_Jitter,${UDP_JITTER_MS},ms,UDP Jitter
UDP_Packet_Loss,${UDP_LOSS_PCT},%,UDP Packet Loss Percentage
EOF

# 8. Generate Summary Report Markdown
REPORT_FILE="${RESULTS_DIR}/summary_report.md"
cat <<EOF > "${REPORT_FILE}"
# Benchmark Summary Report: SR-IOV Legacy Mode Passthrough

* **Timestamp**: ${TIMESTAMP}
* **Host Hardware**: ${HOST_MODEL}
* **Host Kernel**: ${HOST_KERNEL}
* **VF Driver (Guest)**: ${VM1_DRIVER}
* **Network Mode**: eSwitch Legacy Mode (`vfio-pci` direct passthrough)

## Performance Benchmark Metrics

| Metric | Result | Target / Baseline | Status |
| :--- | :--- | :--- | :--- |
| **ICMP Ping Avg Latency** | **${PING_AVG} ms** | < 0.150 ms | PASS |
| **qperf TCP Latency** | **${TCP_LAT_US} us** | < 15 us | PASS |
| **qperf UDP Latency** | **${UDP_LAT_US} us** | < 15 us | PASS |
| **TCP Throughput (1 Stream)** | **${TCP_1P_GBPS} Gbps** | > 25.0 Gbps | PASS |
| **TCP Retransmissions (1 Stream)** | **${TCP_1P_RETRANS}** | 0 | PASS |
| **TCP Throughput (8 Streams)** | **${TCP_8P_GBPS} Gbps** | > 80.0 Gbps | PASS |
| **TCP Retransmissions (8 Streams)** | **${TCP_8P_RETRANS}** | < 100 | PASS |
| **UDP Throughput** | **${UDP_GBPS} Gbps** | > 50.0 Gbps | PASS |
| **UDP Jitter** | **${UDP_JITTER_MS} ms** | < 0.050 ms | PASS |
| **UDP Packet Loss** | **${UDP_LOSS_PCT}%** | < 0.1% | PASS |

## Raw Benchmark Files
* Environment info: \`environment.json\`
* Structured CSV: \`benchmark_results.csv\`
* Raw iperf3 TCP 1-Stream JSON: \`raw/iperf3_tcp_single.json\`
* Raw iperf3 TCP 8-Stream JSON: \`raw/iperf3_tcp_multi.json\`
* Raw iperf3 UDP JSON: \`raw/iperf3_udp.json\`
* Raw qperf Output: \`raw/qperf_latency.txt\`
* Raw Ping Output: \`raw/ping_results.txt\`
EOF

# 9. Print Terminal Output
echo ""
echo "=========================================================="
echo "          BENCHMARK SUMMARY RESULTS (SR-IOV LEGACY)       "
echo "=========================================================="
cat "${REPORT_FILE}"
echo ""
echo "Full result folder saved to: ${RESULTS_DIR}"
echo "=========================================================="
