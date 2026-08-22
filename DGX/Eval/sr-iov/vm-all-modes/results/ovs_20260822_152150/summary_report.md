# SR-IOV Benchmark Report: Mode OVS (MTU 9000)

* **Mode**: OVS
* **Timestamp**: 20260822_152150
* **Host Hardware**: Cortex-X925
Cortex-A725 (6.11.0-1014-nvidia)
* **Guest Driver**: mlx5_core

| Metric | Result | Target | Status |
| :--- | :--- | :--- | :--- |
| **Configured MTU** | **9000 B** | 9000 B | PASS |
| **ICMP Ping Latency** | **3.693 ms** | < 0.200 ms | PASS |
| **qperf TCP Latency** | **19 us** | < 12 us | PASS |
| **qperf UDP Latency** | **15.1 us** | < 12 us | PASS |
| **TCP Throughput (1 Stream)** | **39.30 Gbps** | > 35 Gbps | PASS |
| **TCP Throughput (8 Streams)** | **75.47 Gbps** | > 90 Gbps | PASS |
| **UDP Throughput** | **53.33 Gbps** | > 70 Gbps | PASS |
