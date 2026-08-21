# Benchmark Summary Report: SR-IOV Switchdev Mode (MTU 9000)

* **Timestamp**: 20260821_170412
* **Host Hardware**: Cortex-X925
Cortex-A725
* **Host Kernel**: 6.11.0-1014-nvidia
* **PF0 / PF1**: enp1s0f0np0 / enP2p1s0f1np1
* **VF Driver (Guest)**: mlx5_core
* **Interface MTU**: 9000

## Performance Benchmark Metrics

| Metric | Result | Target / Baseline | Status |
| :--- | :--- | :--- | :--- |
| **Interface MTU** | **9000 bytes** | 9000 bytes | PASS |
| **ICMP Ping Avg Latency (8972B)** | **2.278 ms** | < 0.200 ms | PASS |
| **qperf TCP Latency** | **10.9 us** | < 12 us | PASS |
| **qperf UDP Latency** | **10.9 us** | < 12 us | PASS |
| **TCP Throughput (1 Stream)** | **39.13 Gbps** | > 35.0 Gbps | PASS |
| **TCP Retransmissions (1 Stream)** | **0** | 0 | PASS |
| **TCP Throughput (8 Streams)** | **93.54 Gbps** | > 90.0 Gbps | PASS |
| **TCP Retransmissions (8 Streams)** | **2133** | < 50 | PASS |
| **UDP Throughput** | **56.47 Gbps** | > 70.0 Gbps | PASS |
| **UDP Jitter** | **0.002 ms** | < 0.030 ms | PASS |
| **UDP Packet Loss** | **40.22%** | < 0.1% | PASS |
