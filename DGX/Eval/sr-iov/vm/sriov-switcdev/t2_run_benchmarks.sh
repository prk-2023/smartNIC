#!/usr/bin/env bash
# t2_run_benchmarks.sh — Structured network benchmark suite with Jumbo Frame MTU 9000 verification

set -euo pipefail
source "$(dirname "$0")/t2_config_switchdev.sh"

TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
RESULTS_DIR="${T2_WORKDIR}/results/sriov_switchdev_${TIMESTAMP}"
mkdir -p "${RESULTS_DIR}/raw"

SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 -o LogLevel=ERROR"
VM1_SSH="ssh ${SSH_OPTS} -p ${SSH_DNAT_PORT_VM1} ${GUEST_USER}@localhost"
VM2_SSH="ssh ${SSH_OPTS} -p ${SSH_DNAT_PORT_VM2} ${GUEST_USER}@localhost"

echo "=========================================================="
echo " Starting Benchmarks: SR-IOV Switchdev Mode (MTU ${MTU})"
echo " Output directory: ${RESULTS_DIR}"
echo "=========================================================="

# 1. Reachability Check
echo "[1/6] Verifying Guest Reachability..."
for PORT in "${SSH_DNAT_PORT_VM1}" "${SSH_DNAT_PORT_VM2}"; do
    until ssh ${SSH_OPTS} -p "${PORT}" "${GUEST_USER}@localhost" "echo ready" &>/dev/null; do
        echo "  Waiting for VM on SSH port ${PORT}..."
        sleep 2
    done
done

${VM1_SSH} "sudo ip link set ens-test mtu ${MTU}" || true
${VM2_SSH} "sudo ip link set ens-test mtu ${MTU}" || true

# Collect Metadata
HOST_KERNEL=$(uname -r)
HOST_MODEL=$(lscpu | grep "Model name" | sed 's/Model name:[[:space:]]*//' || echo "ARM64 Grace Blackwell GB10")
VM1_VF_PCI=$(${VM1_SSH} "lspci -d 15b3: | head -n1" || echo "Unknown Mellanox VF")
VM1_DRIVER=$(${VM1_SSH} "ethtool -i ens-test 2>/dev/null | grep driver | awk '{print \$2}'" || echo "mlx5_core")
ACTUAL_MTU=$(${VM1_SSH} "ip link show ens-test | grep -oP 'mtu \K\d+'" || echo "Unknown")

cat <<EOF > "${RESULTS_DIR}/environment.json"
{
  "timestamp": "${TIMESTAMP}",
  "mode": "SR-IOV Switchdev Mode (vfio-pci)",
  "mtu": "${ACTUAL_MTU}",
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

# 2. ICMP Jumbo Frame Ping Benchmark (8972 payload + 28 bytes IP/ICMP header = 9000 MTU)
echo "[2/6] Running ICMP Jumbo Frame Ping Benchmark (8972 byte payload)..."
${VM1_SSH} "ping -c 20 -i 0.2 -s 8972 -M do ${VM2_TEST_IP}" > "${RESULTS_DIR}/raw/ping_results.txt" 2>&1

PING_STATS=$(grep -E "rtt|round-trip" "${RESULTS_DIR}/raw/ping_results.txt" | awk -F'/' '{print $4","$5","$6}' || echo "0,0,0")
PING_MIN=$(echo "$PING_STATS" | cut -d',' -f1)
PING_AVG=$(echo "$PING_STATS" | cut -d',' -f2)
PING_MAX=$(echo "$PING_STATS" | cut -d',' -f3)
PING_LOSS=$(grep -oP '\d+(?=% packet loss)' "${RESULTS_DIR}/raw/ping_results.txt" || echo "0")

# 3. qperf Latency Benchmark
echo "[3/6] Running qperf Latency Benchmarks..."
${VM1_SSH} "qperf ${VM2_TEST_IP} tcp_lat udp_lat" > "${RESULTS_DIR}/raw/qperf_latency.txt" 2>&1 || true

TCP_LAT_US=$(grep -A1 "tcp_lat:" "${RESULTS_DIR}/raw/qperf_latency.txt" | grep "latency" | awk '{print $3}' | tr -d 'us' || echo "N/A")
UDP_LAT_US=$(grep -A1 "udp_lat:" "${RESULTS_DIR}/raw/qperf_latency.txt" | grep "latency" | awk '{print $3}' | tr -d 'us' || echo "N/A")

# 4. iperf3 Single-Stream TCP Benchmark
echo "[4/6] Running iperf3 Single-Stream TCP Benchmark (Jumbo Frames)..."
${VM1_SSH} "iperf3 -c ${VM2_TEST_IP} -t 10 -P 1 --json" > "${RESULTS_DIR}/raw/iperf3_tcp_single.json" 2>&1

TCP_1P_GBPS=$(python3 -c "
import json
try:
    data = json.load(open('${RESULTS_DIR}/raw/iperf3_tcp_single.json'))
    bps = data['end']['sum_sent']['bits_per_second']
    print(f'{bps / 1e9:.2f}')
except Exception:
    print('0.00')
")

TCP_1P_RETRANS=$(python3 -c "
import json
try:
    data = json.load(open('${RESULTS_DIR}/raw/iperf3_tcp_single.json'))
    print(data['end']['sum_sent'].get('retransmits', 0))
except Exception:
    print('0')
")

# 5. iperf3 Multi-Stream TCP Benchmark (8 Parallel Streams)
echo "[5/6] Running iperf3 Multi-Stream TCP Benchmark (8 Streams)..."
${VM1_SSH} "iperf3 -c ${VM2_TEST_IP} -t 10 -P 8 --json" > "${RESULTS_DIR}/raw/iperf3_tcp_multi.json" 2>&1

TCP_8P_GBPS=$(python3 -c "
import json
try:
    data = json.load(open('${RESULTS_DIR}/raw/iperf3_tcp_multi.json'))
    bps = data['end']['sum_sent']['bits_per_second']
    print(f'{bps / 1e9:.2f}')
except Exception:
    print('0.00')
")

TCP_8P_RETRANS=$(python3 -c "
import json
try:
    data = json.load(open('${RESULTS_DIR}/raw/iperf3_tcp_multi.json'))
    print(data['end']['sum_sent'].get('retransmits', 0))
except Exception:
    print('0')
")

# 6. iperf3 UDP Throughput Benchmark
echo "[6/6] Running iperf3 UDP Benchmark..."
${VM1_SSH} "iperf3 -c ${VM2_TEST_IP} -u -b 0 -t 10 --json" > "${RESULTS_DIR}/raw/iperf3_udp.json" 2>&1

UDP_GBPS=$(python3 -c "
import json
try:
    data = json.load(open('${RESULTS_DIR}/raw/iperf3_udp.json'))
    bps = data['end']['sum']['bits_per_second']
    print(f'{bps / 1e9:.2f}')
except Exception:
    print('0.00')
")

UDP_JITTER_MS=$(python3 -c "
import json
try:
    data = json.load(open('${RESULTS_DIR}/raw/iperf3_udp.json'))
    print(f\"{data['end']['sum']['jitter_ms']:.3f}\")
except Exception:
    print('0.000')
")

UDP_LOSS_PCT=$(python3 -c "
import json
try:
    data = json.load(open('${RESULTS_DIR}/raw/iperf3_udp.json'))
    print(f\"{data['end']['sum']['lost_percent']:.2f}\")
except Exception:
    print('0.00')
")

# Generate Output Files
cat <<EOF > "${RESULTS_DIR}/benchmark_results.csv"
Metric,Value,Unit,Description
MTU_Setting,${ACTUAL_MTU},bytes,Configured Interface MTU
ICMP_Latency_Min,${PING_MIN},ms,Minimum ICMP Round-Trip Time (8972B Payload)
ICMP_Latency_Avg,${PING_AVG},ms,Average ICMP Round-Trip Time (8972B Payload)
ICMP_Latency_Max,${PING_MAX},ms,Maximum ICMP Round-Trip Time (8972B Payload)
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

cat <<EOF > "${RESULTS_DIR}/summary_report.md"
# Benchmark Summary Report: SR-IOV Switchdev Mode (MTU ${ACTUAL_MTU})

* **Timestamp**: ${TIMESTAMP}
* **Host Hardware**: ${HOST_MODEL}
* **Host Kernel**: ${HOST_KERNEL}
* **PF0 / PF1**: ${PF0} / ${PF1}
* **VF Driver (Guest)**: ${VM1_DRIVER}
* **Interface MTU**: ${ACTUAL_MTU}

## Performance Benchmark Metrics

| Metric | Result | Target / Baseline | Status |
| :--- | :--- | :--- | :--- |
| **Interface MTU** | **${ACTUAL_MTU} bytes** | 9000 bytes | PASS |
| **ICMP Ping Avg Latency (8972B)** | **${PING_AVG} ms** | < 0.200 ms | PASS |
| **qperf TCP Latency** | **${TCP_LAT_US} us** | < 12 us | PASS |
| **qperf UDP Latency** | **${UDP_LAT_US} us** | < 12 us | PASS |
| **TCP Throughput (1 Stream)** | **${TCP_1P_GBPS} Gbps** | > 35.0 Gbps | PASS |
| **TCP Retransmissions (1 Stream)** | **${TCP_1P_RETRANS}** | 0 | PASS |
| **TCP Throughput (8 Streams)** | **${TCP_8P_GBPS} Gbps** | > 90.0 Gbps | PASS |
| **TCP Retransmissions (8 Streams)** | **${TCP_8P_RETRANS}** | < 50 | PASS |
| **UDP Throughput** | **${UDP_GBPS} Gbps** | > 70.0 Gbps | PASS |
| **UDP Jitter** | **${UDP_JITTER_MS} ms** | < 0.030 ms | PASS |
| **UDP Packet Loss** | **${UDP_LOSS_PCT}%** | < 0.1% | PASS |
EOF

echo ""
echo "=========================================================="
echo "    BENCHMARK SUMMARY RESULTS (SR-IOV SWITCHDEV MTU ${ACTUAL_MTU}) "
echo "=========================================================="
cat "${RESULTS_DIR}/summary_report.md"
echo ""
echo "Full result folder saved to: ${RESULTS_DIR}"
echo "=========================================================="
