# vDPA Hardware Acceleration Report: Mode OVS (MTU 1500)

* **Mode**: OVS
* **Timestamp**: 20260831_163719
* **Host Hardware**: Cortex-X925 Cortex-A725 (6.11.0-1014-nvidia)
* **Guest Driver**: virtio_net
* **Host CPU Util (TCP 1P)**: 29.57%

| Metric | Result | Target | Status |
| :--- | :--- | :--- | :--- |
| **Configured MTU** | **1500 B** | 9000 B | FAIL |
| **ICMP Ping Latency** | **0.147 ms** | < 0.200 ms | PASS |
| **qperf TCP Latency** | **38.3 us** | < 12 us | FAIL |
| **qperf UDP Latency** | **38.5 us** | < 12 us | FAIL |
| **TCP Throughput (1 Stream)** | **5.90 Gbps** | > 35 Gbps | FAIL |
| **TCP Throughput (8 Streams)** | **4.38 Gbps** | > 90 Gbps | FAIL |
| **UDP Throughput** | **3.00 Gbps** | > 70 Gbps | FAIL |
