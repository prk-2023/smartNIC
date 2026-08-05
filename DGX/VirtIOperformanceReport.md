VirtIO performance 

1. Benchmarking VirtIO-based virtual machines with in the system ( using bridge).

2. Benchmarking VirtIO-based virtual machines across independent physical ports (PF0 and PF1) 
creates severe architectural and performance limitations.

CX NICs implment an internal HW eSwitch where each PF and VFs operate as independent, isolated routing and
switching domains. 

- No native cross port bridging: 
- Cross port traffic on single host requires Linux kernel (net.ipv4.ip_forward=1) or SW beidge, 
  this is heavy tax on CPU. 
  
----------------------------------------


1. CX ports not a L2 bridge between each other ( PFs and VFs )

=> can not use Two VM's on a single CX system with multiple ports:

ConnectX cards treat PF0, PF1 or SR-IOV VF's  as completely independent network domains.
i.e the ports are independent routing/switching domains. 
   
And they do not natively or automatically bridge or route traddic across different physical/SR-IOV
virtual ports.

Ref:
https://forums.developer.nvidia.com/t/connectx-6-dx-mcx621102an-ada-hardware-accelerated-port-to-port-forwarding/353018/2
   
=> Suggestion: Use external switch. ( QQ )

Any solution involving switchdev, Linux bridge, or tc will involve the host datapath and consumes CPU.

Have verified with the below setup :

```
 VM1
  |
vnet0
  |
br-left
  |
 PF0
======== DAC ========
 PF1
  |
br-right
  |
vnet1
  |
 VM2
```
Ping from VM1 -> virt-net-> tap0 -> br-left -> PF0 === DAC === PF1 -> br-right -> tap1 -> virt-net -> VM2
Host tcpdump PF1: can see request/reply
     tcpdum PF0: only ARP request 

set the eSwitch on NIC to legacy and swichdev 

$ sudo devlink dev show
pci/0000:01:00.0
auxiliary/mlx5_core.eth.0
pci/0000:01:00.1
auxiliary/mlx5_core.eth.1
pci/0002:01:00.0
auxiliary/mlx5_core.eth.2
pci/0002:01:00.1
auxiliary/mlx5_core.eth.3
$ sudo devlink dev eswitch set pci/0000:01:00.0 mode switchdev
$ sudo devlink dev eswitch set pci/0000:01:00.1 mode switchdev

Result: VM1 and VM2 can not reach as before. 
For L2 traffic forwarding can be further checked by Forwarding Database (FDB), which the hardware 
uses to know which MAC addr are behind which physical port. 
For bridge/OVS to forward packets it must have entry in its FDB mapping the destination VM's MAC address to the
correct port. 

By using ping from both sides  VM1 <==> VM2  and check the fdb on the host:

realtek@gb10-rtk:/tmp/new$ bridge fdb show dev enp1s0f0np0
01:00:5e:00:00:01 self permanent
33:33:00:00:00:01 self permanent
33:33:ff:3c:65:ab self permanent
33:33:00:00:00:fb self permanent
realtek@gb10-rtk:/tmp/new$ bridge fdb show dev enp1s0f1np1
01:00:5e:00:00:01 self permanent
33:33:00:00:00:01 self permanent
33:33:ff:53:4a:4e self permanent
33:33:00:00:00:fb self permanent

We see  FDB entries are multicast and permanent entries.
[ Note: 
- 01:00:5e:00:00:01: IPv4 Link-local multicast address (commonly known as all-hosts multicast group, equivalent to 224.0.0.1)

- 33:33:00:00:00:fb: IPv6 Multicast address used for mDNS (Multicast DNS, equivalent to ff02::fb).

- `self permanent` Means this entry is programmed directly into the hardware/driver of the specific physical network device (enp1s0f0np0 / enp1s0f1np1), bypassing or working independently of the software bridge master layer (master). This is common for NIC offloading or hardware switch integration (such as switchdev).
- for true L2 forwarding we should see an entry ex:`aa:bb:cc:11:22:33 master static` 

- Force adding mac of enp1s0f0np0 to fdb entry:
$ sudo bridge fdb add 4c:bb:47:2f:ba:b2  dev enp1s0f1np1 master static
  RTNETLINK answers: Operation not supported
=> should be asseting that attempt to program the HW with forward rule between cx's ports is rejected. 

]



Note: 

`devlink`: it a modern Linux networking tool and kernel subsystem designed to configure manage and query
device-wide and ASIC wide parameters that do not belong to a single traditional network Interface. 

The reason for a new tool while we had ifconfig, ip and ethtool:
these old traditional tools are focused strictly on specific netdev interfacem, but modern smartNICs 
class of NIC act as a independent computer containing complex internal multi-port switches, firmware
instances, HW acceleration engines and VFs. 

`devlink` is created to give admins a unified interface to control these device level HW attributes. 
E-switch mgmt: `devlink dev eswitch`Control internal embedded switch mode of smartNIC ( legacy/switchdev )
FW upgrade and Flash: `devlink dev flash `allows to updating of NICs fw image directly from host system.
HW health and diag: `devlink health`
device info: `devlink dev info`

----------------------------------------


2. OVS:

```
                 Physical Network (DAC crossover)
                        |
               +----------------+
               |                |
             PF0              PF1
      enp1s0f0np0        enp1s0f1np1
               |                |
      +----------------+  +----------------+
      |   OVS br-left  |  |  OVS br-right  |
      +----------------+  +----------------+
               |                |
          tap-left         tap-right
               |                |
        virtio-net NIC    virtio-net NIC
          (ens-test)        (ens-test)
               |                |
             VM1              VM2
               |                |
        virtio-net NIC    virtio-net NIC
          (ens-mgmt)        (ens-mgmt)
               |                |
          QEMU SLIRP        QEMU SLIRP
       (SSH :2201)        (SSH :2202)
```
Data flow:
```text 
   VM1
 ens-test
    │
    ▼
tap-left
    │
    ▼
OVS br-left
    │
    ▼
   PF0
    │
==== DAC ====
    │
    ▼
   PF1
    │
    ▼
OVS br-right
    │
    ▼
tap-right
    │
    ▼
   VM2
```

Outcome: No internal PF switch or bridge:
```
            ConnectX NIC

      +-----------------------+
      |                       |
      |      No internal      |
      |   PF0 <-> PF1 switch  |
      |      or bridge        |
      |                       |
      +-----------------------+

      PF0                 PF1
       │                   │
       ▼                   ▼
   OVS br-left        OVS br-right
```

Each OVS bridge controls only its local PF and TAP. The ConnectX NIC does not provide an internal Layer-2 forwarding path between PF0 and PF1 simply because they are connected by a DAC cable. For end-to-end forwarding between the VMs, you need either:

an external Ethernet switch between PF0 and PF1, or
a topology where both TAP interfaces are attached to the same OVS bridge (keeping switching entirely within the host).

----------------------------------------

3. Pure SW  VM1 <=> VM2

modify the above OVS setup and add both tap0 and tap1 to PVS br-left:

sudo ovs-vsctl show
sudo ovs-vsctl del-port br-right enp1s0f1np1
sudo ovs-vsctl del-port br-right vnet1
sudo ovs-vsctl del-br br-right
sudo ovs-vsctl add-port br-left vnet1
sudo ovs-vsctl show

./t2_run_test ovs-sw => result/ovs-sw/summart.json

----------------------------------------

4. OVS-DPDK 


OVS-DPDK Architecture
```
                        Linux Host
+---------------------------------------------------------------------+

                Open vSwitch (DPDK datapath)

      +-----------------------------------------------+
      |                                               |
      |               datapath_type=netdev            |
      |                                               |
      +-----------------------------------------------+
              |                               |
              |                               |
              |                               |
      +-------+------+                 +------+-------+
      |    br-left   |                 |   br-right   |
      +--------------+                 +--------------+
             |                                 |
             |                                 |
     +-------+-------+                 +-------+-------+
     |               |                 |               |
     |               |                 |               |
dpdk-p0         vhost-vm1         dpdk-p1         vhost-vm2
(type=dpdk) (dpdkvhostuserclient) (type=dpdk) (dpdkvhostuserclient)
     |               |                 |               |
     |               |                 |               |
 PCI BDF PF0     Unix Socket       PCI BDF PF1     Unix Socket
     |               |                 |               |
     |               |                 |               |
 ConnectX-7      /tmp/vhost/...    ConnectX-7     /tmp/vhost/...
 ```
 
VM Connectivity:
```
                     QEMU VM1                          QEMU VM2
                +----------------+               +----------------+
                | virtio-net     |               | virtio-net     |
                |                |               |                |
                +--------+-------+               +--------+-------+
                         |                                |
                         | vhost-user                     | vhost-user
                         | UNIX socket                    | UNIX socket
                         |                                |
                +--------v----------------+     +---------v---------------+
                | OVS vhost-vm1           |     | OVS vhost-vm2           |
                | dpdkvhostuserclient     |     | dpdkvhostuserclient     |
                +------------+------------+     +------------+------------+
                             |                               |
                             |                               |
                     +-------v-------+               +-------v-------+
                     |   br-left     |               |   br-right    |
                     +-------+-------+               +-------+-------+
                             |                               |
                             |                               |
                        dpdk-p0                         dpdk-p1
                             |                               |
                             |                               |
                      ConnectX-7 PF0                 ConnectX-7 PF1
```

Data Path:
```
                 External Network
                        ^
                        |
                  ConnectX-7 PF0
                        ^
                        |
                 dpdk-p0 (OVS DPDK)
                        ^
                        |
                  +-------------+
                  |  br-left    |
                  +-------------+
                        ^
                        |
             vhost-user UNIX socket
                        ^
                        |
              QEMU vhost backend
                        ^
                        |
               virtio-net (VM1)
```

The right side is identical:
```
VM2
 │
 ▼
virtio-net
 │
 ▼
QEMU vhost-user
 │
 ▼
vhost-vm2
 │
 ▼
br-right
 │
 ▼
dpdk-p1
 │
 ▼
ConnectX-7 PF1
```

Resource Relationships

```
                    t2_config.sh
                          |
        +-----------------+------------------+
        |                 |                  |
        |                 |                  |
   CPU masks        Hugepage config     PCI addresses
        |                 |                  |
        v                 v                  v

+----------------+  +--------------+  +----------------+
| OVS DPDK PMDs  |  | Memory pool  |  | PF0 / PF1 NICs |
+----------------+  +--------------+  +----------------+
        |                 |                  |
        +-----------------+------------------+
                          |
                          v
                 Open vSwitch DPDK
                          |
           +--------------+--------------+
           |                             |
      br-left                       br-right
           |                             |
      vhost-vm1                     vhost-vm2
           |                             |
           |                             |
        VM1 QEMU                      VM2 QEMU
```

What Changes Compared to a Traditional OVS Setup:
```
Traditional Linux OVS

VM
 │
virtio-net
 │
tap
 │
vhost-net
 │
Linux Kernel
 │
OVS (kernel datapath)
 │
Physical NIC


            becomes


OVS-DPDK

VM
 │
virtio-net
 │
vhost-user
 │
OVS userspace (DPDK)
 │
DPDK PMD
 │
ConnectX-7
```

