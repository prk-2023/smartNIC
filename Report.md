# ConnectX-5 Virtualization Performance Benchmark Report
---

- Platform : Intel ( desktop i5 10th Gen ), 16GB DDR4, 
           Fedora 43 , Kernel: 6.18.16-200 
           PCIe : Gen 3 ( enough for testing 25 Gbps NIC )
           NIC Ports are connected with DAC in crossover configuration. 

- Mellanox CX-5 ( 25 Gbps )

## Benchmark : 

Evaluate virtualization network architecture on Mellanox CX-5 NIC adapter. 
Performance ( throughput /CPU usage) metrics between Pure VirtIO, SR-IOV, OVS-DPDK, vDPA. 

Pure VirtIO : buld TCP throughput and CPU efficiency.
SR-IOV: Near native HW Performancem by-passing Host software bridge. 
OVS-DPDK: Low latency and low packet drop rate ( as its by-passing OS network stack )
vDPA : vhost data path acceleration: CX-5 limitation. (using Linux generic vDPA, CX-5 unable to bind )

- Pure VirtIO: ( Deliver higher bulk TCP )


| Metric         | Pure VirtIO (single)  | PureVirtIO (double)|  OVS-DPDK     | SR-IOV (VF Direct) | vDPA       | Ideal / Best Scenario|
| :---           | :---                  | :---               | :---          | :---               | :---       | :---                 |
| **TCP Throughput** | 23.53 Gbps            | 21.71 Gbps     | 14.31 Gbps    | Pending Test       | N/A (CX6+) |Pure VirtIO (SaaS/Bulk Data) |
| **UDP Packet Rate**| "826,944 pps"         | "668,921 pps"  | "726,220 pps" | Pending Test       | N/A (CX6+) | OVS-DPDK (High PPS)   |
| **UDP Packet Loss**|                       |0.605%          | 0.525%        | Pending Test       | N/A (CX6+) | OVS-DPDK (Reliability)|
| **TCP Latency**    | 15.2 µs               |23.3 µs         | 15.8 µs       | Pending Test       | N/A (CX6+) | OVS-DPDK / SR-IOV (Low Latency) |
| **UDP Latency**    | 13.1 µs               |22.4 µs         | 16.5 µs       | Pending Test       | N/A (CX6+) | OVS-DPDK / SR-IOV (Low Latency) |
| **Host CPU Busy**  | 49.55%                |37.44%          | 44.08%        |   NA               | N/A (CX6+) | SR-IOV (Zero-copy hardware) |


## Test cases:

### Pure VirtIO: 

--- 

    Single Virtual Machine: VM1 [virtnet] <---> [PF0] <--- DAC ---> [PF1] Host 
    Dual Virtual Machines : VM1 [virtnet] <---> [PF0] <--- DAC ---> [PF1] <---> [virtnet] VM2 

**Single VM**
```mermaid 
graph LR

    %% Style definitions
    classDef vm fill:#319795,stroke:#234e52,color:#ffffff;
    classDef vnet fill:#2b6cb0,stroke:#1a365d,color:#ffffff;
    classDef nic fill:#2d3748,stroke:#1a202c,color:#ffffff;
    classDef host fill:#d69e2e,stroke:#744210,color:#ffffff;

    subgraph VM_Space ["Guest Virtual Machine"]
        VM["[VM] <br> (192.168.100.10)"]:::vm
    end

    subgraph Host_Virtual ["Host Virtual Network (L2)"]
        TAP["[tap0] <br> (vnet0)"]:::vnet
        BRIDGE["[bridge] <br> (br0)"]:::vnet
    end

    subgraph Physical_NIC ["ConnectX-5 Dual-Port NIC"]
        Port0["[enp1s0f0np0] <br> (Port 0)"]:::nic
        Port1["[enp1s0f1np1] <br> (Port 1 - 192.168.100.1)"]:::nic
    end

    %% Flow connections
    VM <--> |VirtIO-Net| TAP
    TAP <--> |Enslaved| BRIDGE
    BRIDGE <--> |L2 Bridge Port| Port0
    
    %% The physical loopback wire
    Port0 <===> |"Physical DAC Cable (Loopback)"| Port1
```

**Dual VM**

```
                                  PHYSICAL DAC LOOPBACK
                                            │
           ┌────────────────────────────────┴────────────────────────────────┐
           │                                                                 │
     [ enp1s0f0np0 ]                                                   [ enp1s0f1np1 ]
  (Standard Kernel Driver)                                          (Standard Kernel Driver)
           │                                                                 │
     +-----+---+                                                       +-----+---+
     | br-left |                                                       |br-right |  <-- Kernel OVS
     +-----+---+                                                       +-----+---+
           │                                                                 │
      [  vnet0  ] (TAP)                                                 [  vnet1  ] (TAP)
           │                                                                 │
      [ vhost-net ] (Kernel)                                            [ vhost-net ] (Kernel)
           │                                                                 │
       VM1 (Kernel)                                                    VM2 (Kernel)
   (Standard TCP/IP)  ◄─────────────────── iperf3 test ────────────────► (Standard TCP/IP)

```

```mermaid
flowchart LR
    %% Left side
    subgraph Left[" "]
        direction TB
        VM1["**Guest VM1 (ens3)**<br/>Static IP, iperf3 client"]
        VNET0["vnet0 (tap)<br/>vhost-net kernel thread"]
        BRLEFT["br-left<br/>Linux bridge, L2 only"]
        NIC0["enp1s0f0np0<br/>Standard kernel NIC driver"]

        VM1 --> VNET0
        VNET0 --> BRLEFT
        BRLEFT --> NIC0
    end

    %% Right side
    subgraph Right[" "]
        direction TB
        VM2["**Guest VM2 (ens3)**<br/>Static IP, iperf3/qperf server"]
        VNET1["vnet1 (tap)<br/>vhost-net kernel thread"]
        BRRIGHT["br-right<br/>Linux bridge, L2 only"]
        NIC1["enp1s0f1np1<br/>Standard kernel NIC driver"]

        VM2 --> VNET1
        VNET1 --> BRRIGHT
        BRRIGHT --> NIC1
    end

    %% Physical connection
    NIC0 <-->|DAC loopback cable| NIC1

    %% Styling
    classDef vm fill:#d9f0eb,stroke:#5aa89a,color:#083d3d,stroke-width:1px;
    classDef tap fill:#d9e8fb,stroke:#7aa6d8,color:#1f4b7a,stroke-width:1px;
    classDef bridge fill:#ece8ff,stroke:#8d83d6,color:#433b96,stroke-width:1px;
    classDef nic fill:#f6f2ea,stroke:#b7b0a5,color:#4a4a4a,stroke-width:1px;

    class VM1,VM2 vm;
    class VNET0,VNET1 tap;
    class BRLEFT,BRRIGHT bridge;
    class NIC0,NIC1 nic;
```


###  SR-IOV Passthrough Case: 

--- 

    Topology: VM1 [virtnet] <---> [VF] <--- Bridge ---> [VF] <---> [virtnet] VM2
    Blocking: SR-IOV bring up on second port fails:

This testing topology provides near wire-speed throughput and sub-10 µs latencies by shifting packet 
processing directly to hardware offload paths and bypassing host CPU queues completely.

Issue Supporting SR-IOV on Desktop chipsets: 

- Attempting to enable one SR-IOV Virtual Function (VF) on both ports of a single CX-5 card: 
- VF creation succeeds on the first port but fails on the second with error:

Error message: 
```bash 
$ sudo dmesg 
... 
mlx5_core 0000:01:00.1: mlx5_sriov_enable:195: pci_enable_sriov failed : -5
pci 0000:01:01.2: [15b3:1018] type 7f class 0xffffff conventional PCI
pci 0000:01:01.2: unknown header type 7f, ignoring device
... 
```
* Each PCIe function's VFs require a addressable function numbers under a PCI device slot.
* A device slot is normally limited to 8 functions (numbers 0–7).
* The first port's VF fit within that range (0000:01:00.2).
* The second port's VF needed function number 2 on a new device number 0000:01:01.2 which requires the 
  upstream PCIe root port to support and forward ARI (Alternate Routing-ID Interpretation).
* Without ARI supporting feature on the mother board, the kernel has no valid bus/device number to place 
  the second VF on. This causes `pci_enable_sriov()` fails immediately (errno -5, EIO) and the "device" the 
  kernel briefly sees at that address is uninitialized (type 7f, i.e. nothing responded).

* ARI support is a root cause and its a complex silicon feature, negotiated between the `NIC` and the `PCIe` 
  slot it's plugged into. 
* ARI support is generally supported by server/workstation chipsets, and commonly absent on desktop chipsets.


### OVS-DPDK: 

--- 

```
    +------------------------------------------------------------------------+
    |                             FEDORA 43 HOST                             |
    |                                                                        |
    |    +--------------------------------------------------------------+    |
    |    |                      BENCHMARK GUEST VM                      |    |
    |    |                                                              |    |
    |    |      [ VM1: (virtio-net]               [ VM2 (virtio-net]    |    |
    |    +--------------|-------------------------------------|---------+    |
    |                   | (vhost-user0)                       |(vhost-user1) |
    |    +--------------|-------------------------------------|---------+    |
    |    |           (br-left)                              (br-right)  |    |
    |    |          OVS-DPDK Switch                      OVS-DPDK Switch|    |
    |    +--------------|---------------------------------------|-------+    |
    |                   |                                       |            |
    |            [ enp1s0f0np0 ]                         [ enp1s0f1np1 ]     |
    |             (dpdk0 port0)                           (dpdk1 port1)      |
    +-------------------|---------------------------------------|------------+
                        +========== Physical DAC Loopback ======+
                            br-mgmt (local, SW only)
                            ssh into both VMs not measured. 
```

```txt 
                 Physical Network
                      │
          ┌───────────┴───────────┐
          │                       │
      PF0 (01:00.0)          PF1 (01:00.1)
          │                       │
      +---------+             +----------+
      | br-left |             | br-right |
      +---------+             +----------+
          │                       │
     vhost-user0             vhost-user1
          │                       │
       VM1 (DPDK)              VM2 (DPDK)

                 Separate management network

        Host (192.168.50.1)
               │
        Linux bridge br-mgmt
           │             │
      tap-mgmt1     tap-mgmt2
           │             │
          VM1           VM2
```

- prepare the system to use Open vSwitch (OVS) with DPDK as a very fast sw-switch connecting two physical
  NIC ports of CX5 to two VM using `vhost-user`. 


Additional info ./benchmark/OVS-DPDK/ovs-dpdk-test/readme.md 

### vDPA (vhost Data Path Acceleration) Limitation:

--- 

Not compatible with current HW.
Kernel support generic vDPA: ( workaround ): 
   Hardware acceleration for vDPA using `librte_vdpa_mlx5` or the kernel `mlx5_vdpa` module requires CX-6 
   family or higher. 
   CX-5 lacks the necessary internal firmware objects (DevX/Virtio layout offloads) needed to drive vDPA 
   datapaths directly in hardware.

More info @ : ./benchmark/vDPA/ 
