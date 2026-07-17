Benchmark Results :

- Measure 3 different usecase to compare the throughput of virtual machines using
  - Pure VirtIO, ( With PF0 and PF1, and with PF0:VF0, PF1:VF0 ) 
  - OVS-DPDK 
  - vDPA 

Note: 
- SR-IOV: ARI/PCIe bus limitation: explained at the bottom of the document.

- **vDPA**: both the Linux kernel's `mlx5_vdpa` driver and DPDK's `vdpa/mlx5`  PMD, requires the NIC to
  implement virtio ring/virtqueue processing directly in hardware (NVIDIA's "ASAP" hardware virtio
  emulation). That capability was introduced starting with the ConnectX-6 / ConnectX-6 Dx generation.

- **vDPA in-kernel without DPDK**: kernel has a fully independent, DPDK-free vDPA path `drivers/vdpa/mlx5` +
  the `vhost_vdpa` character device, consumed by QEMU's `-netdev vhost-vdpa`). 
  This also depends on the identical NIC hardware capability as the DPDK PMD, and looks its only exposes a 
  different software interface, going kernel-only does not route around the ConnectX-5 limitation.

- OVS-DPDK achieves noticeably lower latency for both TCP and UDP:OVS-DPDK achieves noticeably lower latency
  for both TCP and UDP: VirtIO Performance:

CX5:
Host System:

| Metric          |    Pure VirtIO |        OVS-DPDK | Better                    |
| --------------- | -------------: | --------------: | :------------------------ |
| TCP Throughput  | **21.71 Gbps** |      14.31 Gbps | **Pure VirtIO**: achives higher bulk TCP throughput|
| UDP Packet Rate |    668,921 pps | **726,220 pps** | **OVS-DPDK**: forwards more pkts per second        |
| UDP Packet Loss |         0.605% |      **0.525%** | **OVS-DPDK**: Drops fewer packets per second       |
| TCP Latency     |        23.3 µs |     **15.8 µs** | **OVS-DPDK**: lower TCP latency                    |
| UDP Latency     |        22.4 µs |     **16.5 µs** | **OVS-DPDK**: lower UDP latency                    |
| Host CPU Busy   |     **37.44%** |          44.08% | *Not directly comparable* measured differently     |

Benchmark workload between **VM1** and **VM2**. 

Difference between them is the forwarding path (Linux bridge + VirtIO/vhost-net versus OVS-DPDK). 

Traffic-generation commands and measured metrics  are identical:

| Metric                    | Command executed from VM1                                 | Result extracted                      |
| ------------------------- | --------------------------------------------------------- | ------------------------------------- |
| **TCP Throughput**        | `iperf3 -c 192.168.101.20 -p 5201 -t 60 -P 4 -J`          | `sum_received.bits_per_second` → Gbps |
| **UDP Packet Rate (PPS)** | `iperf3 -c 192.168.101.20 -p 5201 -u -l 64 -b 0 -t 60 -J` | `packets / seconds` → packets/sec     |
| **UDP Packet Loss**       | Same UDP `iperf3` command                                 | `lost_percent`                        |
| **TCP Latency**           | `qperf 192.168.101.20 tcp_lat udp_lat`                    | `tcp_lat` latency                     |
| **UDP Latency**           | `qperf 192.168.101.20 tcp_lat udp_lat`                    | `udp_lat` latency                     |
| **Host CPU Busy**         | `mpstat -P ALL 1 145` (executed on the host)              | `100 − average(%idle)`                |


### Benchmark Commands

#### 1. TCP Throughput

```bash
iperf3 -c 192.168.101.20 -p 5201 -t 60 -P 4 -J
```

* Client: VM1
* Server: VM2 (running `iperf3 -s`)
* Measures aggregate TCP throughput using 4 parallel streams.

Pure VirtIO delivers higher throughput than OVS-DPDK
=> Linux networking stach with `vhost-net` is more efficient at transfering large TCP. 
( Modern kernel has mature TCP optimization for Generic Receive Offloading (GRO), Generic Segmentation
Offloading (GSO) and TCP Segmentation Offloading (TSO) these reduce protocol-processing overhead and improve
bulk throughput. )

---

#### 2. UDP Packet Rate

```bash
iperf3 -c 192.168.101.20 \
    -p 5201 \
    -u \
    -l 64 \
    -b 0 \
    -t 60 \
    -J
```

Measures:

* UDP packet rate (PPS)
* UDP packet loss (%)

```text
UDP PPS = packets / seconds
UDP Packet Loss = lost_percent
```

OVS-DPDK process about 8.6% more pkts per second and also has  lower packet loss. 
Consistent with DPDK architecture, pkts by-pass kernel network stack and processed @ user-space by PMD
thread ( dedicated thread ) => reduced per pkt processing overhead. 

---

#### 3. TCP & UDP Latency

```bash
qperf 192.168.101.20 tcp_lat udp_lat
```

Measures:

* TCP request-response latency
* UDP request-response latency

OVS-DPDK has lower latency for both TCP and UDP:
- TCP latency lower ~ 32% 
- UDP latency lower by 26% 
In consistent with DPDK architecture as it eliminated kernel context switching, interrupt handling and
schedulers role during pkt forwarding. 

---

#### 4. Host CPU Busy

```bash
mpstat -P ALL 1 145
```

```text
Host CPU Busy (%) =
100 − Average CPU Idle (%)
```

- For pure VirtIO: 
    * CPU usage => actual work performed by the kernel's networking stack and `vhost-net` threads. 
    * Idle periods results in lower CPU utilization. 

- For OVS-DPDK: 
    * PMD threads continuously poll NIC threads ( Busy polling) even when the traffic is low or zero. 
    * The reason for higher CPU utilization is mainly by 100% of the CPU Core that is used for polling. 

---

## Metrics Collected

* **Pure VirtIO** (Linux bridge + vhost-net)
* **OVS-DPDK** (userspace datapath with PMD threads)

The Pure VirtIO  additionally records **vhost-net thread placement** and **physical NIC kernel
counters**, while the OVS-DPDK script records **PMD statistics** and **PMD performance counters** to
characterize the forwarding datapath. These are verification and diagnostic measurements rather than
benchmark performance metrics.

Pure VirtIO: Higher TCP throughput and shows lower measured CPU utilization. And suggests for larger TCP
transfers between Linux VMs, Kernels bridge and `vhost-net` datapath is efficient in using the HW resources. 

OVS-DPDK: PMD threads intensionally do busy poll network queues even in idle periods, results in higher CPU
utilization, but this is not directly comparable with VirtIO testing case. 

---

## SR-IOV : 

Attempting to enable one SR-IOV Virtual Function (VF) on both ports of a single CX-5 card:
VF creation succeeds on the first port but fails on the second
with error:
```bash 
dmesg:
mlx5_core 0000:01:00.1: mlx5_sriov_enable:195: pci_enable_sriov failed : -5
pci 0000:01:01.2: [15b3:1018] type 7f class 0xffffff conventional PCI
pci 0000:01:01.2: unknown header type 7f, ignoring device
```

Cause: 

- Each PCIe function's VFs need addressable function numbers under a PCI device slot. 
- A device slot is normally limited to 8 functions (numbers 0–7). 
- The first port's VF fit within that range (0000:01:00.2). 
- The second port's VF needed function number 2 on a new device number `0000:01:01.2` which requires the
  upstream PCIe root port to support and forward ARI (Alternate Routing-ID Interpretation). 
- Without ARI, the kernel has no valid bus/device number to place the second VF on, so `pci_enable_sriov()`
  fails immediately (errno -5, EIO) and the "device" the kernel briefly sees  at that address is
  uninitialized (type 7f, i.e. nothing responded).

- ARI support is a root-complex silicon feature, negotiated between the NIC and the PCIe slot it's plugged
  into. It's common on server/workstation chipsets, and commonly absent on desktop/consumer chipsets.

---

## Compare test results with cpu governor = performance

compare between powersave and performance governer:

$ echo performance | sudo tee /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor

Case 1: Pure virtIO:

| Metric          |       Powersave | Performance |                Change |
| --------------- | --------------: | ----------: | --------------------: |
| TCP Throughput  |  **21.62 Gbps** |  21.36 Gbps |                 −1.2% |
| UDP Packet Rate | **661,029 pps** | 651,038 pps |                 −1.5% |
| UDP Packet Loss |      **0.682%** |      0.806% |        Slightly worse |
| TCP Latency     |     **23.9 µs** |     24.8 µs |               +0.9 µs |
| UDP Latency     |     **22.0 µs** |     22.1 µs | Essentially unchanged |
| Host CPU Busy   |          37.61% |      37.46% |  No meaningful change |

Changing the CPU frequency governor from powersave to performance had negligible impact on the Pure VirtIO
datapath. Across all measured metrics—including TCP throughput, UDP packet rate, packet loss, latency, and
host CPU utilization—the observed differences were within normal benchmark variation.

Case 2: ovs-dpdk:

| Metric          |   Powersave |     Performance |                        Change |
| --------------- | ----------: | --------------: | ----------------------------: |
| TCP Throughput  |  13.27 Gbps |      13.04 Gbps | −1.7% (no significant change) |
| UDP Packet Rate | 501,083 pps | **752,894 pps** |                    **+50.3%** |
| UDP Packet Loss |  **0.148%** |          3.011% |                     Increased |
| TCP Latency     |     16.8 µs |     **16.3 µs** |                         −3.0% |
| UDP Latency     | **15.4 µs** |         15.6 µs |         No significant change |
| Host CPU Busy   |      43.80% |          43.56% |         No significant change |

Switching from the powersave governor to the performance governor has little effect on bulk TCP throughput 
or CPU utilization, but has a increased packet-processing capacity of OVS-DPDK. 
The higher CPU frequency enables PMD threads to forward approximately 50% more UDP packets per second, 
=> improved packet-processing capability.


--- 
| VirtIO Performance  | Native VirtIO | OVS + DPDK   | CX5 vDPA |
| :--- | :--- | :--- | :--- |
| Small Pkt Fwd Efficiency (Mpps)  |  |  | |
| Transmission Bandwidth capabilitya| | | |
| Average Latency | | | |
| Host CPU Usage| | | |


