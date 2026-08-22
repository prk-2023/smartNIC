# SR-IOV Benchmark Report: Mode TC (MTU 9000)

* **Mode**: TC
* **Timestamp**: 20260822_153040
* **Host Hardware**: Cortex-X925
Cortex-A725 (6.11.0-1014-nvidia)
* **Guest Driver**: mlx5_core

| Metric | Result | Target | Status |
| :--- | :--- | :--- | :--- |
| **Configured MTU** | **9000 B** | 9000 B | PASS |
| **ICMP Ping Latency** | **1.457 ms** | < 0.200 ms | PASS |
| **qperf TCP Latency** | **83.6 us** | < 12 us | PASS |
| **qperf UDP Latency** | **142 us** | < 12 us | PASS |
| **TCP Throughput (1 Stream)** | **41.26 Gbps** | > 35 Gbps | PASS |
| **TCP Throughput (8 Streams)** | **91.14 Gbps** | > 90 Gbps | PASS |
| **UDP Throughput** | **43.15 Gbps** | > 70 Gbps | PASS |
