# OVS: 

Open vSwitch is a multilayer virtual network switch designed to enable massive network automation and 
programmatic control in virtualized environments. 

What OVS does:

- Virtual Switching: 
    Connects VM's or containers on the same physical host or across multiple physical servers.

- Replaces Native Bridges: 
    Acts as an advanced, high-performance alternative to standard Linux bridges.

- Software-Defined Networking (SDN): 
    Fully supports the OpenFlow protocol, allowing external controllers to program how traffic moves through
    the network.

Key features: 

- Standard Protocols: 
    Supports VLANs (802.1Q), link aggregation (LACP), and tunneling protocols like VXLAN, GRE, and Geneve.

- Network Visibility: 
    Includes monitoring tools like NetFlow, sFlow, and IPFIX to track and mirror network traffic.

- Quality of Service (QoS): 
    Allows administrators to manage bandwidth and prioritize specific types of network traffic.

- High Performance: 
    Uses an optimized Linux kernel module for fast pkt forwarding, with user-space and DPDK (Data Plane 
    Development Kit) options.

Use cases:
    - Cloud platforms
    - Container orchestration 
    - Hypervisors; ( KVM, Xex, Proxmos )


### working with ovs:

Configure OVS vSwitch:

- To configure a basic Open vSwitch (OVS) bridge:  `ovs-vsctl` tool to manages the OVS config database.

- Step-by-step commands to create a bridge, add ports, and verify your configuration.

    - Ensure the Open vSwitch service is running:
        `sudo systemctl start openvswitch-switch`

    - Create a New OVS Bridge ( bridge acts like a virtual switch.) 
        `sudo ovs-vsctl add-br br0`

    - Add an Interface to the Bridge ( connect your virtual switch to the physical network or another device,
      attach a network interface (e.g., eth1 or enp3s0):
        `sudo ovs-vsctl add-port br0 eth1`

    Note: Do not add your primary internet interface (like eth0), or you may lose your remote SSH connection
          unless you have configured IP migration.

    - Verify the Configuration ( Check the layout and status of your OVS switches, ports, and interfaces):
        `sudo ovs-vsctl show`

    - IP assignment ( Optional ) If you need the host OS to communicate through this bridge, assign an IP
      address to the internal bridge interface:
        `sudo ip a a 10.10.10.1/24 dev br0` 
        `sudo ip link set br0 up`

    - Delete a configuration ( rollback , remove port or completely delete the bridge )
        `sudo ovc-vsctl del-port br0 eth1`
        `sudo ovs-vsctl del-br br0`

    - Make setting persistent:
        - OVS automatically persists bridge and port layouts in its internal database (ovsdb-server). 
        - However, IP addrs assigned to the bridge via the `ip` command will disappear on reboot.

        Option A: ( modern Linux Netplan ) add bridge and Ip setting to config file ( debian/ ubuntu )
        ( /etc/netplan/01-netcfg.yaml )
        ```yaml 
        network:
            version: 2 
            renderer: networkd 
            ovs_bridges:
                br0:
      interfaces: [eth1]
      addresses: [192.168.1.50/24]

        ```
        Apply changes : `sudo netplan apply`

        Option B:  Enterprise Linux (NetworkManager - RHEL/Rocky/CentOS) 
        Run these commands to link NetworkManager with OVS:
        `sudo nmcli connection add type ovs-bridge conn-name br0 ifname br0`
        `sudo nmcli connection add type ovs-port conn-name br0-port-eth1 link br0 ifname eth1`
        `sudo nmcli connection add type ovs-interface conn-name br0-if type ovs-interface link br0-port-eth1 ifname br0 ip4 192.168.1.50/24`

    - How to Clear Everything, to quickly wipe out the IP settings, interfaces, and the vSwitch entirely:
        #1. Bring down the interface
        `sudo ip link set br0 down`
        #2. Delete the OVS bridge (automatically removes all attached ports)
        `sudo ovs-vsctl del-br br0`

        ( If you used Netplan or NetworkManager, remember to delete or revert those configuration 
          files/connections as well )

### Howto: OVS works with OpenFlow and SDN controllers:

OVS separates the network's control plane (decision making) from the data plane (packet forwarding).

When paired with OpenFlow and a Software-Defined Networking (SDN) controller (like OpenDaylight, ONOS, or
OpenStack's Neutron agent), OVS transforms from a simple switch into a programmable networking engine.


The Architecture: How They Interact

- The SDN Controller (The Brain): 
    An external application that maintains a global view of the entire network. It decides how traffic 
    should flow based on policies, security rules, and routing needs.

- OpenFlow (The Language): 
    The standard southbound API protocol used by the SDN controller to push down forwarding rules into the 
    OVS switch.

- Open vSwitch (The Muscle): 
    The switch that receives these rules and executes them directly in hardware or the Linux kernel.

    The Workflow: Packet Flow Step-by-Step
```
    [ SDN Controller ] 
           ^
           | OpenFlow Protocol (Secure TLS/TCP)
           v
    [ OVS vswitchd ] <--- Reactive Lookup (Packet-In)
           |
           | Fast Kernel Cache (Megaflows)
           v
    [ OVS Kernel Module ] ===> Forward / Drop / Modify Packets 
```
    - Step 1: Packet Arrival: 
        A packet arrives at an OVS port. The OVS kernel module checks its local cache (called the datapath)
        for a matching rule.

    - Step 2: Cache Hit (Fast Path):
        If a match exists, OVS instantly forwards, modifies, or drops the packet entirely within the Linux
        kernel. No external lookup is needed.

    - Step 3: Cache Miss & Packet-In (Slow Path) 
        If the kernel doesn't know what to do with the packet, it hands it up to the user-space daemon
        (ovs-vswitchd). If ovs-vswitchd also lacks a rule, it wraps the packet header into an OpenFlow
        "Packet-In" message and sends it over a secure TCP/TLS connection to the external SDN Controller.

    - Step 4: The Decision (Flow-Mod)
        The SDN controller analyzes the header. It calculates the optimal path and sends an OpenFlow
        "Flow-Mod" (Flow Modification) message back to OVS. This message contains explicit instructions: "If
        a packet matches these criteria (IP, MAC, or Port), execute these actions."

    - Step 5: Rule Execution
        OVS installs this new rule into its user-space flow tables and pushes a shortcut into the fast
        kernel cache. Subsequent packets of the same flow bypass the controller entirely and process at line
        rate.

Real-World Advantage:

This architecture is exactly how massive cloud environments like OpenStack achieve instantaneous,
programmatic multi-tenancy. Instead of manually logging into hundreds of physical switches to configure
VLANs, an orchestration tool automatically uses OpenFlow to isolate or connect thousands of virtual machines
on the fly.


## Flow table:

- A flow table is the routing database inside an Open vSwitch (OVS). Think of it as a highly advanced 
  lookup table that tells the switch exactly what to do with incoming network traffic.

- Instead of just looking at MAC addresses like a traditional hardware switch, a flow table analyzes 
  packets across multiple network layers (MAC, IP, TCP/UDP ports).

### How a Flow Table Works
When a pkt enters the switch, OVS processes it through the flow table by evaluating three components:

1. The Match: 
    OVS checks the packet headers against criteria like incoming port, source IP, or destination TCP port.

2. The Priority: 
    If a packet matches multiple rules, OVS executes the rule with the highest priority number.

3. The Action: 
    Once a match is found, OVS executes the corresponding instruction (e.g., forward out a port, drop the 
    packet, or modify a VLAN tag).

### Multi-Table Pipelining (The Advanced Part)

OVS doesn't just have one flow table; it can support up to 255 distinct tables (numbered 0 to 254). 
This is called a flow pipeline.

* Packets always start at Table 0.

* Instead of immediately forwarding a packet, an action can be resubmit, which passes the packet to Table 1 
  for further evaluation.

* This allows you to break complex logic into smaller, manageable steps (ex: Table 0 handles firewall 
  blocking, Table 1 handles VLAN tagging, and Table 2 handles final routing).

### Ex: Moving Packets Between Tables (Pipelining)

To send a packet from Table 0 to Table 1, use the resubmit action. This passes the pkt down the pipeline for
further processing.

Here is a two-step command example.

1. Table 0 Rule: 
    Match web traffic (TCP port 80) and send it to Table 1.
    `sudo ovs-ofctl add-flow br0 "table=0,priority=100,tcp,tp_dst=80,actions=resubmit(,1)"`

2. Table 1 Rule: Take that traffic from Table 1 and forward it out of Port 2.
    `sudo ovs-ofctl add-flow br0 "table=1,priority=100,tcp,actions=output:2"`
 
The two steps separates logic. Table 0 can focus entirely on filtering/security, while Table 1 focuses 
entirely on where the packets go.

### Ex: Exact-Match vs. Wildcard Tables

Inside the OVS software architecture, flow entries are processed using two different internal mechanism
styles to balance lookup speed and memory.

```text 
           [ Packet Arrives ]
                   │
                   ▼
       ┌───────────────────────┐
       │  Exact-Match Cache    │  ◄─── Ultra-fast, single lookup (Exact headers)
       └───────────┬───────────┘
                   │ Miss?
                   ▼
       ┌───────────────────────┐
       │    Wildcard Tables    │  ◄─── Slower, checks ranges/masks (Ternary Content-Addressable Memory style)
       └───────────────────────┘
```

### Exact-Match Tables (Microflow Cache)

* What they do: Every single packet header field must match the rule perfectly.

* How they work: OVS hashes the exact combination of MAC, IP, Ports, and VLAN tags into a single key.

* The Benefit: Lookup is near-instantaneous (O(1) time complexity).

* The Downside: Inflexible. If two packets are identical but have slightly different source ports, they
  require two separate exact-match entries.

### Wildcard Tables (Ternary / Megaflow Cache)

* What they do: They support "don't care" bits, subnets, and ranges.

* How they work: 
    Instead of matching an exact IP like 192.168.1.50, they can match a whole subnet using wildcards like
    192.168.1.0/24 or match any packet regardless of its source port. OVS uses a mechanism called Tuple
    Space Search (TSS) to evaluate these.

* The Benefit: Highly flexible. A single rule can handle millions of different individual connections.

* The Downside: Slower to process than an exact hash lookup because the switch has to evaluate multiple masks to find a match.

### How OVS Blends Both

Modern OVS uses Megaflows to combine the best of both worlds. The control plane writes flexible wildcard
rules, but as traffic passes through, the OVS kernel generates optimized, temporary exact-match paths for
active traffic streams to maximize forwarding speeds.


## OVS HW offloading with ConnectX:

CX network cards use an internal hardware component called an eSwitch (Embedded Switch) paired with ASAP 
(Accelerated Switching and Packet Processing) technology.

This combination enables Open vSwitch (OVS) Hardware Offloading, allowing the system to achieve 
near-line-rate forwarding speeds and freeing up the host CPU by shifting the heavy lifting of the data plane
into the NIC hardware.

### 1. The Core Architecture: Switchdev Mode 

To connect OVS to the [CX eSwitch](https://www.google.com/search?kgmid=FAILED_OR_SKIPPED), the network 
interface must be placed into `switchdev` mode (as opposed to standard legacy SR-IOV mode). 
This creates two crucial structures: 

* Virtual Functions (VFs): 
    These are pass-through PCIe channels mapped directly into Virtual Machines (VMs) or containers for
    ultra-low latency.

* VF Representors: 
    For every VF running in a VM, the host OS sees a matching "shadow" interface (a representor netdev,
    e.g., enp4s0f0_0).

* You plug the VF Representors into the OVS bridge, not the VFs themselves. OVS controls the switchdev 
  configuration through these representors.

### 2. How the Acceleration Workflow Works

The interaction between OVS and the [CX eSwitch](https://www.google.com/search?kgmid=FAILED_OR_SKIPPED) 
follows a "First Packet to Software, Consecutive Packets to Hardware" paradigm. 

```text 
 [ VM 1 (VF 1) ]                                      [ VM 2 (VF 2) ]
        │                                                    ▲
        │ (1) First Packet                                   │ (4) Offloaded Flow
        ▼                                                    │     Line-Rate
  ┌───────────┐   (2) Cache Miss                       ┌───────────┐
  │  eSwitch  │ ─────────────────────────────────────► │    OVS    │
  │ Hardware  │ ◄───────────────────────────────────── │ User/Kern │
  └─────┬─────┘         (3) Offload Flow Rule          └───────────┘
        │            (via tc-flower / DPDK rte_flow)
        │
        └───────────────── (5) Fast Path ────────────────────►
```

#### Step 1: The First Packet (The Slow Path Exception)

When a VM sends a packet belonging to a completely new connection, the packet passes through the internal 
ConnectX eSwitch. Because the hardware's lookup table doesn't have a matching rule yet, a cache miss occurs.

#### Step 2: Traversal to Software Control

The eSwitch automatically routes the packet up through its matching VF Representor into the host OS. 
The packet reaches the OVS data path (either the Linux Kernel or OVS-DPDK).

#### Step 3: Rule Generation and "Push-Down"

OVS processes the packet, checks its OpenFlow tables, and makes a routing decision. 
Crucially, if OVS hardware offload is enabled (other_config:hw-offload=true), OVS takes that exact 
forwarding rule and translates it into a hardware-compatible instruction.

- **If using OVS-Kernel**: OVS translates the rule into a Linux tc flower (Traffic Control) subsystem rule.

- **If using OVS-DPDK**: OVS translates the rule using DPDK rte_flow APIs.

#### Step 4: Programming the eSwitch

The CX mlx5 driver catches this `tc` or `rte_flow` command and programs the exact flow directly into the 
eSwitch's hardware flow tables. 

#### Step 5: Hardware Fast-Path Execution

When the second, third, and all subsequent pks of that connection arrive from the VM, the eSwitch hits the 
hardware rule. It performs actions like MAC switching, VLAN tagging, or VXLAN encapsulation/decapsulation 
natively on the ASIC. The packet jumps from VF-to-VF or VF-to-Physical port completely in silicon, bypassing
the host CPU entirely. 

### 3. What the ConnectX eSwitch Can Offload

CX hardware switches (especially modern iterations like CX-5, CX-6, and CX-7) can offload highly complex 
OVS operations natively: 

- **Packet Modifying & Steering**:
    L2 (MAC), L3 (IP), and L4 (TCP/UDP) matching and header rewriting.

- **Tunneling Encap/Decap**: 
    Processing Overlay Networks like VXLAN, GRE, and Geneve in silicon so the CPU doesn't waste cycles 
    packaging headers.

- **Connection Tracking (Conntrack)**: Advanced models (CX-6 Dx and newer) support hw-based stateful
  firewalls, tracking TCP state machine changes in hardware. 

### Summary Checklist for Enabling It

To make this work in the real world, administrators follow a tight hardware-to-software pipeline: 

   1. Enable SR-IOV in the system BIOS and ConnectX firmware configuration (mlxconfig).
   2. Set the NIC's eswitch mode to switchdev via the devlink tool.
   3. Enable hw-tc-offload on the interfaces via ethtool.
   4. Instruct OVS to leverage the hardware by executing:
   
   `sudo ovs-vsctl set Open_vSwitch . other_config:hw-offload=true`
   `sudo systemctl restart openvswitch-switch`

### References: 

[1] [https://networking-docs.nvidia.com](https://networking-docs.nvidia.com/mlnxofedswum/24.10-5.1.6.1lts/ovs-offload-using-asap2-direct)
[2] [https://www.openvswitch.org](https://www.openvswitch.org/support/ovscon2017/efraim.pdf)
[3] [https://developer.arm.com](https://developer.arm.com/community/arm-community-blogs/b/tools-software-ides-blog/posts/open-vswitch-offload-by-smartnics-on-arm)
[4] [https://blog.csdn.net](https://blog.csdn.net/essencelite/article/details/136796457)
[5] [https://networking-docs.nvidia.com](https://networking-docs.nvidia.com/doca/archive/3-4-0/ovs-doca-hardware-acceleration)
[6] [https://github.com](https://github.com/ovn-org/ovn-kubernetes/issues/773)
[7] [https://docs.redhat.com](https://docs.redhat.com/en/documentation/red_hat_openstack_platform/17.1/html/configuring_network_functions_virtualization/config-ovs-hwol_rhosp-nfv)
[8] [https://www.openvswitch.org](https://www.openvswitch.org/support/ovscon2019/day2/1125-dibbiny-tragler-iskra-shern-efraim.pdf)
[9] [https://enterprise-support.nvidia.com](https://enterprise-support.nvidia.com/s/article/getting-started-with-mellanox-asap-2)
[10] [https://www.cnblogs.com](https://www.cnblogs.com/dream397/p/14435673.html)


