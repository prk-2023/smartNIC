# Benchmark Summary Report: SR-IOV Legacy Mode Passthrough

* **Timestamp**: 20260821_162250
* **Host Hardware**: Cortex-X925
Cortex-A725
* **Host Kernel**: 6.11.0-1014-nvidia
* **VF Driver (Guest)**: mlx5_core
* **Network Mode**: eSwitch Legacy Mode ( direct passthrough)

## Performance Benchmark Metrics

| Metric | Result | Target / Baseline | Status |
| :--- | :--- | :--- | :--- |
| **ICMP Ping Avg Latency** | **0.059 ms** | < 0.150 ms | PASS |
| **qperf TCP Latency** | **10 us** | < 15 us | PASS |
| **qperf UDP Latency** | **10.2 us** | < 15 us | PASS |
| **TCP Throughput (1 Stream)** | **29.54 Gbps** | > 25.0 Gbps | PASS |
| **TCP Retransmissions (1 Stream)** | **0** | 0 | PASS |
| **TCP Throughput (8 Streams)** | **70.19 Gbps** | > 80.0 Gbps | PASS |
| **TCP Retransmissions (8 Streams)** | **10423** | < 100 | PASS |
| **UDP Throughput** | **8.27 Gbps** | > 50.0 Gbps | PASS |
| **UDP Jitter** | **0.004 ms** | < 0.050 ms | PASS |
| **UDP Packet Loss** | **0.04%** | < 0.1% | PASS |

## Raw Benchmark Files
* Environment info: `environment.json`
* Structured CSV: `benchmark_results.csv`
* Raw iperf3 TCP 1-Stream JSON: `raw/iperf3_tcp_single.json`
* Raw iperf3 TCP 8-Stream JSON: `raw/iperf3_tcp_multi.json`
* Raw iperf3 UDP JSON: `raw/iperf3_udp.json`
* Raw qperf Output: `raw/qperf_latency.txt`
* Raw Ping Output: `raw/ping_results.txt`
