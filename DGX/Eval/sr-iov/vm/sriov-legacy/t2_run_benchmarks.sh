#!/usr/bin/env bash
# t2_run_benchmarks.sh — Triggers performance tests (iperf3 throughput & qperf latency) across SR-IOV VMs

set -euo pipefail
source "$(dirname "$0")/t2_config.sh"

SSH_KEY="${HOME}/.ssh/id_rsa"
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5"

echo "=========================================================="
echo " Running Benchmarks: SR-IOV Legacy Passthrough Mode"
echo "=========================================================="

# 1. Verify SSH connectivity to VM1 and VM2
echo "[1/4] Checking VM reachability via management port..."
for PORT in "${SSH_DNAT_PORT_VM1}" "${SSH_DNAT_PORT_VM2}"; do
    until ssh ${SSH_OPTS} -p "${PORT}" "${GUEST_USER}@localhost" "echo ready" &>/dev/null; do
        echo "  Waiting for VM on port ${PORT} to boot..."
        sleep 3
    done
done
echo "Both VMs reachable."

# 2. Verify mlx5 driver and interface in Guest
echo "[2/4] Verifying Guest hardware VF driver status..."
ssh ${SSH_OPTS} -p "${SSH_DNAT_PORT_VM1}" "${GUEST_USER}@localhost" "lspci | grep -i mellanox; ip link show ens-test"

# 3. ICMP Ping Test
echo "[3/4] Running ICMP Ping test (VM1 -> VM2)..."
ssh ${SSH_OPTS} -p "${SSH_DNAT_PORT_VM1}" "${GUEST_USER}@localhost" "ping -c 5 ${VM2_TEST_IP}"

# 4. Throughput Test (iperf3 single-stream & multi-stream)
echo "[4/4] Executing iperf3 benchmarks..."
echo "--- Single Stream TCP Throughput ---"
ssh ${SSH_OPTS} -p "${SSH_DNAT_PORT_VM1}" "${GUEST_USER}@localhost" \
    "iperf3 -c ${VM2_TEST_IP} -t 10 -P 1"

echo "--- 8-Parallel Streams TCP Throughput ---"
ssh ${SSH_OPTS} -p "${SSH_DNAT_PORT_VM1}" "${GUEST_USER}@localhost" \
    "iperf3 -c ${VM2_TEST_IP} -t 10 -P 8"

echo "--- UDP Throughput & Jitter ---"
ssh ${SSH_OPTS} -p "${SSH_DNAT_PORT_VM1}" "${GUEST_USER}@localhost" \
    "iperf3 -c ${VM2_TEST_IP} -u -b 0 -t 10"

echo "=========================================================="
echo " Benchmarking Complete."
echo "=========================================================="

