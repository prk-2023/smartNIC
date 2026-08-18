# CX6 PC test


1. Baremetal: ( namespaces )
| Test            |            TCP |         UDP RX |   UDP loss |    UDP PPS |   Latency |    CPU |
| --------------- | -------------: | -------------: | ---------: | ---------: | --------: | -----: |
| Pure bare metal | **47.67 Gbps** | **20.22 Gbps** | **35.36%** | 436.9 Kpps | **72 µs** | 32.58% |


2. OVS Baremetal: ( namespaces ) ( redo make sure that every element in data path supports Jumbo frame )

| Metric                  |                    Result |
| ----------------------- | ------------------------: |
| TCP throughput          |            **47.44 Gbps** |
| UDP offered load        |               **50 Gbps** |
| UDP received throughput |            **12.13 Gbps** |
| UDP PPS                 |           **347,325 pps** |
| UDP loss                |               **51.199%** |
| UDP jitter              | **0.002956 ms / 2.96 µs** |
| TCP/ICMP latency        |      **0.095 ms / 95 µs** |
| Host CPU                |                **33.87%** |
| UDP packet size         |            **8948 bytes** |


3. OVS-DPDK:  ( used result/CX6test/iperf3_udp_pps.json for UDP results ) 

| Metric                  |                    Result |
| ----------------------- | ------------------------: |
| TCP throughput          |            **15.22 Gbps** | ( MTU 1500 )
| udp throughput          |            **6.99 Gbps**  |
| UDP offered load        |            **40 Gbps**    |
| UDP received throughput |            **6.97 Gbps**  |
| UDP PPS                 |           **603,685**     | 
| UDP loss                |               **0.37%**   | 
| UDP jitter              | **0.000851 ms / 8.5 µs**  |
| TCP/ICMP latency        |      **0.095 ms / 95 µs** |
| Host CPU                |                **33.87%** |
| UDP packet size         |            **1500 bytes** |

MTU: 9000 TODO: 

--------------------------------------

Compare:
NOTE: PC chipset supports PCIe Gen 3.0 


--------------------------------------------------------
Observations:

On standard Linux host, traditional kernel based bridge or sw-based OVS setups treats NICs as a standard
PCIe endpoint, and software does the heavy lifting. 

On GB-10: The arch has a single interface is shared with CPU and GPU.
Adding on to the complexisty the CX  its own eSwitch, steering, hardware filtering, representors, SR-IOV, switchdev, 
etc. The integration with standard linux cause specific HW behaviour. Which is because the CX behaves as a smartNIC
with its own internal eSwitch. When this switch is set to run in `switchdev` mode legacy SW bridge fails or seriously
degrades because packet steering, the flow tables, and representor ports offload traffic directly into the hardware ASIC.

This has impact on evaluating VirtIO throughput/latency against HW accelerated paths ( SR-IOV, vDPA )

1. SW VirtIO-Net ( Baseline reference path )
Datapath: 
    VM1 virtIO driver -> 
        TAP dev -> 
            SW OVS/linux bridge(CPU) ->
                Physical NIC 
=> full CPU processing and high overhead and context switching. 

2. OVS-DPDK with VirtIO user / vHost-user
DataPath:
        VM1 virtIO driver -> 
            vHost-User port ->
                OVS-DPDK PMD Cores -> 
                    DPDK CX PMD -> Wire
Bypasses kernel network stack entirely using DPDK polling.
Has higher throughput and lower jitter than traditional kernel bridges
but heavily consumes Host CPU cores ( PMDs )

3. SR-IOV with Switchdev Offload (ASIC Path)
Datapath: 
    VM1 ConnectX VF Driver -> 
        VF Interface -> 
            CX HW eSwitch (ASIC Flow Rules) -> Wire
                
=> Direct passthrough: Guest uses a native VF driver ( ex: mlx5_core )
=> Switchdev Steering: OVS offloads TC ( flower )flow rules straight 
   to the HW eSwitch via representor ports.
=> Lowest latency and higher pkt rate (Mpps), completely bypasses CPU 
   copy overhead 
   
4. vDPA (VirtIO Data Path Acceleration)
Datapath: 
    VM1 Standard VirtIO Driver -> 
        vDPA Kernel Subsystem -> 
            CX eSwitch HW -> Wire
            
=> Control Plane: The guest VM sees a standard, vendor-agnostic
   VirtIO-net device (maintaining VM live-migration capabilities).
=> Data Plane: Ring descriptors and packet buffers are wired directly
   into the CX HW eSwitch.
=> Eliminates CPU overhead while using standard VirtIO drivers inside the guest.


-----

SwitchDev: References:
- https://docs.kernel.org/networking/device_drivers/ethernet/mellanox/mlx5/switchdev.html

SR-IOV: References:
- https://networking-docs.nvidia.com/doca/archive/3-4-0/sr-iov

- https://networking-docs.nvidia.com/doca/archive/3-4-0/sr-iov-live-migration


-----

# Nvidia CX NICs:

- CX NICs  are more than traditional network adapters; they are high-performance SmartNICs equipped with an 
  embedded HW switch (eSwitch) capable of offloading advanced networking, security, and virtualization tasks 
  directly to the silicon.
  
- Understanding how to leverage features like SR-IOV, switchdev, representors, and hardware steering is essential 
  for modern cloud-native, high-performance computing (HPC), and telco environments.

--- 

## 1. Core Architecture & Concepts

### SR-IOV (Single Root I/O Virtualization)

- SR-IOV allows a single physical NIC (PF - Physical Function) to bypass the hypervisor 
  or host OS software data path by splitting itself into multiple virtual interfaces called Virtual Functions (VFs). 
  Each VF can be directly assigned to a virtual machine (VM) or container, providing near-native throughput and 
  ultra-low latency.
  
### eSwitch (Embedded Switch)

- Inside the ConnectX ASIC sits a hardware-based Layer 2 switch. 

- The eSwitch manages traffic flowing between the physical ports, the host CPU (PF), and all the generated VFs.

#### Switchdev Mode
By default, CX NICs operate in legacy mode (where PF and VFs act independently). 
By switching the NIC to switchdev mode, the hardware eSwitch is exposed to the Linux kernel as an independent 
software-programmable switch. 
This bridges the gap between hardware acceleration and standard Linux networking tools (like tc and iproute2).

#### Representors (Network Representor Ports)
When operating in switchdev mode, the Linux kernel creates a representor for every VF (e.g., enp8s0f0_0).
- A representor is a 1:1 software proxy in the host OS representing the VF's port on the hardware eSwitch.

- Administrators use representors to apply firewall rules, traffic shaping, and monitoring to a specific VM/container 
  traffic path from the host, without needing to log into the guest OS.
  
#### Hardware Steering & Filtering (TC Offload)

CX NICs feature packet-processing engines (such as ASAP2 - Accelerated Switching and Packet Processing). 
Using the Linux Traffic Control (tc) subsystem with the infra or flower classifier, rules are offloaded directly to the
NIC hardware. This means matching packets (ACLs, routing, encapsulation/decapsulation like VXLAN) are processed at line 
rate by the ASIC, completely bypassing the CPU.

--- 

## 2. Practical Guide: Inspection & Verification Commands


To explore, configure, and troubleshoot a ConnectX NIC's advanced features, use the following Linux command sequence.

**Step 1**: Identify the Hardware and Firmware

Locate your Mellanox/Nvidia device and check the driver and firmware versions.
```
    # Check loaded drivers and PCI details
    lspci -nnk | grep -i net -A3
    
    # Check OFED/mlx5 version and firmware details using mget_fw or ethtool
    ethtool -i <interface_name>
```

**Step 2**: Check SR-IOV Status and Configure VFs

Verify if SR-IOV is supported and check how many VFs are currently enabled.

```
    # Check maximum supported VFs vs currently enabled VFs
    cat /sys/class/net/<physical_interface>/device/sriov_totalvfs
    cat /sys/class/net/<physical_interface>/device/sriov_numvfs

    # Enable, for example, 4 VFs (must be done or unbound first)
    echo 4 > /sys/class/net/<physical_interface>/device/sriov_numvfs
```

**Step 3**: Inspect and Switch to switchdev Mode

To use representors and hardware offload, the NIC must be placed in switchdev mode. We use devlink for this.

```
# Check current devlink device mode
    devlink dev info pci/0000:01:00.0
    devlink dev eswitch show pci/0000:01:00.1

    # Switch the eSwitch mode from 'legacy' to 'switchdev'
    devlink dev eswitch set pci/0000:08:00.0 mode switchdev
```
Note: Changing modes usually requires unbinding and rebinding the VFs or restarting the driver.

**Step 4**: View Representor Ports

Once in switchdev mode, list your network interfaces to see the newly spawned representors.

```
# List interfaces to find representors (usually named after the PF with suffixes like _0, _1)
ip link show | grep -E "enp|rep"
```

**Step 5**: Verify Hardware Offloads (tc and ethtool)
Ensure that hardware offloading is enabled on your interfaces so rules go straight to the ASIC.

```
    # Check ethtool offload configurations
    ethtool -k <interface_name> | grep "hw-tc-offload"

    # Enable hardware TC offload if disabled
    ethtool -K <interface_name> hw-tc-offload on

    # List active hardware-offloaded Traffic Control (tc) rules
    tc filter show dev <representor_name> ingress
```

| Feature | Without CX Acceleration | With CX acceleration & switchdev |
| :---: | :--- | :--- |  
| Data Path | Handled by Linux Bridge / Open </br>vSwitch (OVS) in SW | Offloaded to ASIC HW (ASAP2)| 
| CPU Utilization| High ( scales with pkt rate & security rules) | Near Zero ( line rate HW execution) |
| Visibility | Limited to Guest OS or complex SW taps | Managed centrally via host side representor port|




==> So getting eSwitch mode right is the key step before building your network topology, as it fundamentally changes how the Linux kernel and HW interact with traffic. 


### 1. Legacy Mode ( traditional networking )

- How it works:
  The eSwitch acts as a basic, transparent pipe. The physical function (PF) and Virtual Functions (VFs) operate independently.


> https://blog.csdn.net/qq_42824983/article/details/148044109#:~:text=legacy%20mode%EF%BC%88%E4%BC%A0%E7%BB%9F%E6%A8%A1%E5%BC%8F%EF%BC%89%E6%98%AF%E6%8C%87%E7%BD%91%E5%8D%A1%E4%BB%A5%E6%99%AE%E9%80%9A%E4%BB%A5%E5%A4%AA%E7%BD%91%E5%8D%A1%E7%9A%84%E6%96%B9%E5%BC%8F%E5%B7%A5%E4%BD%9C%EF%BC%8C%E6%89%80%E6%9C%89%E7%BD%91%E7%BB%9C%E5%8A%9F%E8%83%BD%EF%BC%88%E5%A6%82%E8%BD%AC%E5%8F%91%E3%80%81%E8%BF%87%E6%BB%A4%E3%80%81%E6%A1%A5%E6%8E%A5%E7%AD%89%EF%BC%89%E9%83%BD%E7%94%B1Linux%20%E5%86%85%E6%A0%B8%E5%9C%A8CPU%20%E4%B8%8A%E5%A4%84%E7%90%86%E3%80%82

- Use Case: 
  Best for standard hypervisors, bare-metal setups, or traditional Linux bridging/bonding where you don't need host-level hardware acceleration over VM/container traffic. 

- Switching decisions rely purely on standard MAC/VLAN learning inside the OS software stack.

#### 2. Switchdev Mode (Advanced/Cloud-Native Networking)

- How it works: 

  The embedded hardware switch is exposed to the Linux kernel via the switchdev framework. It spawns representor ports for every VF/SF, merging hardware capabilities with standard kernel control tools (tc, bridge, Open vSwitch). 

- Use Case: 
  Essential when you want hardware offloading (ASAP2) for packet filtering, ACLs, encapsulation (VXLAN/Geneve), or software-defined networking (SDN) controllers like Open vSwitch (OVS) or OVN. It shifts heavy packet-inspection overhead from your host CPU directly to the ConnectX ASIC.
  

#### Example use-cases: Standard Linux bridge:

With a standard Linux Bridge, it depends entirely on whether you want hardware acceleration or if you are fine doing everything in software:

**1. Standard Linux Bridge in Legacy Mode (Software Path)**

- How it works: 
    The Linux bridge operates completely in software on the host CPU. 
    You attach your physical interface (PF) or VFs directly to the bridge 
    (ip link set enp8s0f0 master br0).
    
- The Result: The CX NIC acts merely as a dumb pipe. All Layer 2 switching, MAC learning, 
  STP , and pkt forwarding are calculated by the host CPU. 
  This consumes CPU cycles but requires zero specialized configuration on the eSwitch.
  
**2. Standard Linux Bridge in Switchdev Mode (Hardware Bridge Offload)**

- How it works: 
    Modern Linux kernels (v5.15+) support Linux Bridge Offloads with Nvidia ConnectX cards. 
    When the NIC is in switchdev mode, you attach the representor ports (not the raw VFs)
    to the Linux bridge. 
    
- The Result: The Linux bridge acts as the control plane, but it automatically pushes 
  forwarding database (FDB) entries, VLAN filtering rules, and MAC learning directly down to 
  the CX eSwitch ASIC HW. Once the HW learns a flow, packets route at wire speed directly through
  the ASIC, bypassing the host CPU entirely.
  
```bash 
# Example: Offloading a Linux bridge using switchdev representors
ip link add name br0 type bridge      # create linux br0
ip link set br0 type bridge vlan_filtering 1  # enable per-port VLAN filter on br0 
ip link set dev enp8s0f0_0 master br0  # Attach the VF representor to the bridge
ip link set dev br0 up
```
This config sets up Linux SW beidge with VLAN filtering and attaches switchdev VF representor 
which here is enp8s0f0_0. 
The VLAN Filter keeps track of which VLANs are allowed on each bridge port and only forwards VLAN 
traffic where it it permitted. 

so 
$sudo  ip link set br0 type bridge vlan_filtering 1

now br0 maintains a VLAB table which looks as below:
```
Port        Allowed VLANs
-------------------------
port1       10,20
port2       20
port3       10
```
for ex:
```
port1 -- VLAN 10 --> br0 -- VLAN 10 --> port3   ✓
port1 -- VLAN 10 --> br0 -- VLAN 10 --> port2   ✗
port1 -- VLAN 20 --> br0 -- VLAN 20 --> port2   ✓
```
You configure that table with bridge vlan:

```
bridge vlan add dev enp8s0f0_0 vid 10
bridge vlan add dev enp8s0f0_0 vid 20
``` 
In your example, enp8s0f0_0 is a VF representor. 
With VLAN filtering enabled, the Linux bridge can express policies such as:

```
VF representor
    │
    ├── VLAN 10 ✓
    ├── VLAN 20 ✓
    └── VLAN 30 ✗
```

On a switchdev-capable NIC, the driver can potentially translate those bridge/VLAN rules into 
hardware switch rules, so packets are filtered/forwarded by the NIC rather than going through 
the Linux networking stack for every packet.

> Note enable VLAN filter does not itself configure VLANs, it enables the VLAN-aware behaviour;
> You normally populate the VLAN membership with  `bridge vlan ...` commands



**sub modes:**

Legacy and Switchdev are two primary operational modes, the kernels `devlink` framework and Nvidia `mlx5`
driver recognize a couple of other specialized states and sub-modes:

1. `switchdev_inactive` ( specialized switchdev state) 

Its a varient of switchdev mode where the eSwitch initializes into switchdev capabilities, but starts 
completely inactive ( https://docs.kernel.org/networking/devlink/devlink-eswitch-attr.html )

This state prevents any traffic from passing through the VFs/representors until cloud orchestrators 
or container management tools have finished pushing all initial security rules, ACLs and pipeline 
configurations. 
This state avoid race conditions or traffic leaks during boot-up or VM provisioning. 


2. `none` Disabled/cleared state 

In older driver versions or specific configurations, setting the eSwitch mode to `none` effecitively 
deactivates the embedded switch features when SR-IOV is turned off or stripped down.

**Attributes**

( https://docs.kernel.org/networking/devlink/devlink-eswitch-attr.html )

Other critical eSwitch sub-attributes which can be confused as Modes:

When tuning a CX eSwitch via devlink, you will also configure sub-parameters that drastically change
how data travels through the hardware:

- `inline-mode` ( `none`|`link`|`network`|`transport`)
    - Tells the VF driver how much pkt header data to push directly onto the TX descriptor. 
      Because the ASIC needs to parse headers instantly for hardware steering/matching, complex overlay
      networks sometimes require pushing L2, L3, or L4 headers straight to the hardware descriptor ring 
      so the eSwitch doesn't have to look them up separately. 
      
- `encap-mode` ( `none`|`basic` )
    - Globally toggles hardware-level tunnel encapsulation and decapsulation (such as VXLAN or Geneve). Setting this to basic allows the ConnectX ASIC to wrap and unwrap overlay tunnels at line rate without involving the host CPU.

Example Usage:

```bash
# enable switchdev mode
$ devlink dev eswitch set pci/0000:08:00.0 mode switchdev

# set inline-mode and encap-mode
$ devlink dev eswitch set pci/0000:08:00.0 inline-mode none encap-mode basic

# display devlink device eswitch attributes
$ devlink dev eswitch show pci/0000:08:00.0
  pci/0000:08:00.0: mode switchdev inline-mode none encap-mode basic

# enable encap-mode with legacy mode
$ devlink dev eswitch set pci/0000:08:00.0 mode legacy inline-mode none encap-mode basic

# start switchdev mode in inactive state
$ devlink dev eswitch set pci/0000:08:00.0 mode switchdev_inactive

# setup switchdev configurations, representors, FDB entries, etc..
...

# activate switchdev mode to allow traffic
$ devlink dev eswitch set pci/0000:08:00.0 mode switchdev
```

--------


# Working with CX and cloud infrastructure:

Deploying NVIDIA ConnectX NICs in cloud infrastructure depends entirely on whether you are running 
workloads on Bare Metal or inside Virtual Machines (VMs), and whether you need raw performance 
or advanced software-defined networking (SDN) features.

## Host setup for performance and optimization:

Ref: https://docs.nvidia.com/dccpu/grace-perf-tuning-guide/optimizing-io.html 

### 1. NUMA affinity and CPU pinning 

Running benchmarking tools like `iperf3` , `netperf` and `TRex` on Random CPU cores causes cross-socket
PCIe traffic, destroying latency and throughput numbers. 

Always map the NIC to its local NUMA node 
( cat /sys/class/net/<interface>/device/numa_node )
and pin benchmark processes using `numactl` or `taskset` to cores residing on that exact socket. 

### 2. Ring Buffer and Channel scaling: 

Leaving `ethtool` ring buffers and combined channels at default OS limits causes packet drops under 
high loads.

To fix: maximize ring buffers:
`$sudo  ethtool -G <interface> rx 8192 tx 8192` 

Match channel counts to local CPU core counts:
`$sudo ethtool -L <interface> combined <N>

### 3. Disabling Interrupt Balancing (irqbalance)

Allowing the OS daemon `irqbalance` to dynamically shift NIC interrupts across cores introduces 
jitter and inconsistent benchmark results.

=>  Stop irqbalance during benchmarking: systemctl stop irqbalance.

### 4. Hardware Offload Verification for Switchdev

If we assume rules are hitting the ASIC in switchdev mode when they are actually falling back to 
software processing.

In this case check `tc filter show dev <representor> ingress` to verify that packet counters increment 
on hardware offload rules (`in_hw`).

### 5. MTU and PCIe Performance Flags

Testing high-speed adapters (100G/200G/400G) with a 1500 MTU or sub-optimal PCIe read parameters
can result in underperformant results.

Enable Jumbo Frames (mtu 9000) and check advanced firmware settings via mlxconfig 
(such as ensuring `MAX_ACC_OUT_READ` and PCIe Relaxed Ordering are tuned for your specific CX generation). 

---

## 1. Bare Metal Deployment 

In BM mode workloads run directly on host OS depending on the isolation and switching needs, 
you choose between using the Physical Function (PF) directly of varving out Virtual Functions (VFs)

### Using PFs directly:

HPC, high frequency trading, storage nodes (NVMe-oF) or heavy database nodes requiring max raw throughput
lowest possible latency, and direct HW utilization. 

In this case host OS interacts with the physical port. ( enp1s0f0np0, enp1s0f1np1 )

- Keep the eSwitch in **legacy mode** ( default )
- Configure IP addes MTU, jumbo frames `mtu 9000`) and queue counts directly on the PF:
```bash
$ sudo ip link set dev enp8s0f0 up
$ sudo ip addr add 192.168.100.10/24 dev enp8s0f0

# tune ring buffers 
$ sudo ethtool -G enp8s0f0 rx 4096 tx 4096 
```

###  Using Virtual Functions (VFs) on Bare Metal

Multi-tenant bare-metal clouds (like OpenStack Ironic or specialized Kubernetes nodes) where a 
single physical server hosts multiple isolated applications or containers that need dedicated 
hardware queues.

The PFs create VFs which are then bound to different local apps/namespaces. 
This requires to enable VFs, which can be done via sysfs:

`$ echo 2 > /sys/class/net/enp8s0f0/device/sriov_numvfs`

this creates 2 VFs

Bind the generated VFs to apps or network namespaces for direct, isolated hardware access.


## 2. Virtual Machine (VM) Deployment

When virtualizing infrastructure (using KVM, QEMU, OpenStack, or Proxmox), ConnectX NICs allow
you to pass networking down to VMs using two distinct paradigms: 

**Direct SR-IOV Passthrough** or **Hardware-Accelerated vDPA**.

### Method A: SR-IOV VF Passthrough (Maximum Performance)

The hypervisor creates a Virtual Function on the host and passes that physical PCIe device directly
through to the guest VM.

- The guest OS loads the native NVIDIA mlx5_core driver. 
- To the guest VM, it looks like it owns a physical Nvidia network card.

Near-native wire speed, minimal hypervisor CPU overhead, and hardware offloads (like RDMA/RoCE)
function seamlessly inside the VM.

Live migration can be complex because stateful hardware queues are tied directly to the physical ASIC.


#### Step-by-Step Configuration Workflow:

1. Enable IOMMU in Host BIOS & Kernel: (Mandatory for passing PCIe devices)
Add `intel_iommu=on iommu=pt` to your kernel boot parameters (GRUB).

2. Configure eSwitch & Spawn VFs on the Host:

```bash 
# Switch to switchdev if using host-side OVS/Linux bridge integration, or keep legacy if VM handles its own switching
devlink dev eswitch set pci/0000:01:00.0 mode switchdev

# Generate VFs
echo 2 > /sys/class/net/enp8s0f0/device/sriov_numvfs
```

3. Unbind VFs from Host Driver & Attach to VM (Libvirt/QEMU Example):

```bash
# Find VF PCI addresses (e.g., 0000:08:00.1)
virsh nodedev-dumpxml pci_0000_01_00_1
```

Pass the PCI address into your VM XML configuration file (domain.xml):

```xml
<hostdev mode='subsystem' type='pci' managed='yes'>
  <source>
    <address domain='0x0000' bus='0x08' slot='0x00' function='0x1'/>
  </source>
</hostdev>
```
Method B: vDPA (Virtual Data Path Acceleration) — The Modern Cloud Standard


### Method B: vDPA (Virtual Data Path Acceleration): The Modern Cloud Standard


Ref: https://networking-docs.nvidia.com/doca/archive/2-5-4/openvswitch-offload#:~:text=When%20using%20ASAP2%20data%20plane%20over%20SR%2DIOV,on%20the%20host%20by%20the%20vDPA%20application.


If you want the hardware performance of SR-IOV combined with the live-migration 
capabilities and standard management of virtual interfaces, NVIDIA and the Linux kernel use vDPA.

vDPA:  Instead of passing a raw proprietary NVIDIA VF into the VM, the host converts the VF data path
       into an open, standard VirtIO interface using a kernel shim layer. 
       The VM simply loads a standard virtio-net driver, while the ConnectX ASIC hardware accelerates the 
       actual packet movement. 

This supports seamless VM live migration while maintaining hardware-accelerated wire speeds and 
OVS/OVN offloading.

#### Step-by-Step Configuration Workflow (Host-Side):

1. Ensure Switchdev Mode is Active:

```bash 
$ sudo devlink dev eswitch set pci/0000:08:00.0 mode switchdev 
```

2. create a scalable function (SF) or VF for vDPA. 

```bash 
# Instantiate the vDPA device framework over the target VF/SF
vdpa dev add name vdpa1 mgmtdev pci/0000:08:00.0
```

3. Expose to QEMU/Hypervisor:

The hypervisor attaches `vdpa1` as a standard VirtIO disk/network backend to the VM, allowing 
cloud orchestration layers (like OpenStack or Kubernetes with KubeVirt) to manage cloud-native 
networking seamlessly.













