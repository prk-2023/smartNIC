
| Metric          |    Pure VirtIO |        OVS-DPDK | Better                    |
| --------------- | -------------: | --------------: | :------------------------ |
| TCP Throughput  | **21.71 Gbps** |      14.31 Gbps | **Pure VirtIO**           |
| UDP Packet Rate |    668,921 pps | **726,220 pps** | **OVS-DPDK**              |
| UDP Packet Loss |         0.605% |      **0.525%** | **OVS-DPDK**              |
| TCP Latency     |        23.3 µs |     **15.8 µs** | **OVS-DPDK**              |
| UDP Latency     |        22.4 µs |     **16.5 µs** | **OVS-DPDK**              |
| Host CPU Busy   |     **37.44%** |          44.08% | *Not directly comparable* |

## 1. TCP Throughput

Pure VirtIO achieved approximately **21.7 Gbps**, compared to **14.3 Gbps** for OVS-DPDK.

This is unexpected, as DPDK is often associated with higher throughput. 

Factors to explain this behaviour :

* Traffic is between only **two VMs**, so the Linux networking stack may already be highly optimized.
* `VirtIO` with `vhost-net` performs efficient zero-copy operations for many workloads.
* `OVS-DPDK` introduces additional packet processing stages in userspace before forwarding packets.
* The benchmark may not have fully saturated the PMD cores or exploited DPDK's strengths, which are more 
  apparent under high packet-rate or multi-flow workloads.

For this workload, the Linux bridge and VirtIO datapath delivered higher sustained TCP throughput.

---

## 2. UDP Packet Processing

OVS-DPDK processed **726 kpps**   compared to  **669 kpps** for Pure VirtIO.

UDP benchmarking with 64-byte packets stresses packet processing rather than bandwidth. 

OVS-DPDK bypasses much of the Linux kernel networking stack and processes packets in userspace using 
Poll Mode Drivers (PMDs), reducing per-packet overhead.

The improvement is approx  **8.6%**, ( => OVS-DPDK handles high packet-rate workloads more efficiently )

---

## 3. UDP Packet Loss

| Pure VirtIO | OVS-DPDK |
| ----------- | -------- |
| 0.605%      | 0.525%   |

The difference is small.
Lower packet loss => OVS-DPDK was able to keep up slightly better with the high-rate UDP stream, this can be 
due to reduced interrupt overhead and continuous polling.

---

## 4. TCP Latency

| Pure VirtIO | OVS-DPDK |
| ----------- | -------- |
| 23.3 µs     | 15.8 µs  |

`OVS-DPDK` reduced TCP latency by approximately 32% 

$$
\frac{23.3-15.8}{23.3}\times100
\approx32%
$$

This improvement is for PMD threads continuously poll receive queues instead of waiting for interrupts, 
reducing packet delivery delay.

---

## 5. UDP Latency

| Pure VirtIO | OVS-DPDK |
| ----------- | -------- |
| 22.4 µs     | 16.5 µs  |

UDP latency improved by roughly

$$
\frac{22.4-16.5}{22.4}\times100
\approx26%
$$

=> lower software latency introduced by userspace packet processing.

---

## 6. CPU Utilisation

This metric requires careful interpretation.

| Pure VirtIO | OVS-DPDK |
| ----------- | -------- |
| 37.44%      | 44.08%   |

OVS-DPDK appears to consume more CPU.
This is due to PMD threads busy-polling ~100% on their dedicated cores. 
`pure-virtio` (Linux bridge + vhost-net) resuls show `host_cpu_busy_pct` includes `vhost-net` kernel worker
threads, which only consume CPU while actively forwarding packets (unlike DPDK PMD threads, which busy-poll
at ~100% even when idle). Check vhost_threads_before/after.txt for kernel thread placement 
(psr column = host core) and ethtool_*_before/after.txt to confirm rx/tx_packets  climbed on the physical
NICs during the run.

### Pure VirtIO

The CPU utilisation includes:

* Linux bridge processing
* kernel networking
* `vhost-net` kernel worker threads

Importantly,

> `vhost-net` threads consume CPU **only while forwarding packets**.

When traffic stops, CPU utilisation decreases accordingly.

---

### OVS-DPDK

The CPU utilisation includes:

* PMD threads

PMD threads use **busy polling**, meaning they continuously poll NIC receive queues, even when no packets 
are arriving.

As a result:

* PMD cores typically remain close to 100% utilisation by design.
* A higher CPU utilisation does **not necessarily indicate more useful work**.
* It reflects a deliberate design choice to minimise latency.

Therefore, comparing the raw CPU percentages is not entirely fair.

A better comparison would exclude the dedicated PMD cores or use OVS PMD statistics (for example,
`ovs-appctl dpif-netdev/pmd-stats-show`) to distinguish between cycles spent processing packets and cycles
spent idle polling.

---

**Conclusion's :**

The benchmarking results indicate that the two datapaths exhibit different performance characteristics.

* **Pure VirtIO** achieved substantially higher TCP throughput while also showing lower measured host CPU
  utilisation. This suggests that, for large TCP transfers between two virtual machines, the Linux bridge
  and `vhost-net` datapath can efficiently exploit the available hardware resources.

* **OVS-DPDK** outperformed Pure VirtIO in packet-processing metrics, achieving higher UDP packet rates,
  lower packet loss, and significantly lower TCP and UDP latencies. These improvements are consistent with
  the userspace polling architecture of DPDK, which avoids interrupt-driven packet reception and reduces
  forwarding latency.

* The higher host CPU utilisation observed for OVS-DPDK should not be interpreted as lower efficiency
  without further analysis, because PMD threads intentionally busy-poll network queues even during idle
  periods. Consequently, CPU utilisation is not directly comparable between the two architectures.

Overall, these results suggest that **Pure VirtIO is more effective for maximizing bulk TCP throughput in
this experimental setup**, whereas **OVS-DPDK is better suited to latency-sensitive and high packet-rate
workloads**, where its polling-based architecture provides lower forwarding latency and slightly improved
packet processing performance. This aligns with the intended design goals of each networking approach.

