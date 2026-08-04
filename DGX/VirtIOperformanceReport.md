VirtIO performance 

1. Benchmarking VirtIO-based virtual machines with in the system ( using bridge).

2. Benchmarking VirtIO-based virtual machines across independent physical ports (PF0 and PF1) 
creates severe architectural and performance limitations.

CX NICs implment an internal HW eSwitch where each PF and VFs operate as independent, isolated routing and
switching domains. 

- No native cross port bridging: 
- Cross port traffic on single host requires Linux kernel (net.ipv4.ip_forward=1) or SW beidge, 
  this is heavy tax on CPU. 
  


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

```VM1
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



2. 
