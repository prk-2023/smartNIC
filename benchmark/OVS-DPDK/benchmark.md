# benchmark: OVS-DPDK:


Benchmark `OVS-DPDK` using your dual-port CX-5 card in a physical loopback setup 
(enp1s0f0np0 <=> enp1s0f1np1), 

=> you need a test architecture that injects traffic into one port and receives it on the other.

Aim: is to benchmarking Pure Virtio performance, we will route traffic through a Virtual Machine (VM) 
     running DPDK/testpmd inside your linux host ( Fedora 43 )

### 1. Benchmark Topology:

```txt
    +------------------------------------------------------------------------+
    |                             FEDORA 43 HOST                             |
    |                                                                        |
    |    +--------------------------------------------------------------+    |
    |    |                      BENCHMARK GUEST VM                      |    |
    |    |                                                              |    |
    |    |      [ Virtio Port 0 ]                [ Virtio Port 1 ]      |    |
    |    +--------------|---------------------------------------|-------+    |
    |                   | (vhost-user)                          |(vhost-user)|
    |    +--------------|---------------------------------------|-------+    |
    |    |           (br-left)                              (br-right)  |    |
    |    |          OVS-DPDK Switch                      OVS-DPDK Switch|    |
    |    +--------------|---------------------------------------|-------+    |
    |                   |                                       |            |
    |            [ enp1s0f0np0 ]                         [ enp1s0f1np1 ]     |
    |               (Physical)                              (Physical)       |
    +-------------------|---------------------------------------|------------+
                        +========== Physical DAC Loopback ======+

```
```txt
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

In this architecture:

- A sw pkt generator running on the host (like DPDK-Pktgen) sends traffic via br-left out of physical 
  interface `enp1s0f0np0`.

- Packets cross the physical DAC cable and enter `enp1s0f1np1`.

- `br-right` intercepts the packets and forwards them to Virtio Port 1 of the VM.

The VM loops the traffic internally to Virtio Port 0, which forwards it back down to `br-left`.

### 2. Step 1: Host Operating System Preparation

DPDK requires isolated CPU cores and massive memory blocks (Hugepages) to eliminate kernel bottlenecks.

**Allocate Hugepages & Isolate CPUs**

Edit your bootloader options. 

Assuming a 16-core CPU, we will reserve cores 2–7 for DPDK (Host + VM) and allocate 1GB hugepages.

1. `/etc/default/grub` and modify `GRUB_CMDLINE_LINUX`:

```
GRUB_CMDLINE_LINUX="... default_hugepagesz=1G hugepagesz=1G hugepages=16 isolcpus=2-7 nohz_full=2-7 rcu_nocbs=2-7"
```

2. Regenerate your GRUB configuration and reboot:

```
sudo grub2-mkconfig -o /boot/grub2/grub.cfg
sudo reboot
```

3. Mount the hugepages after rebooting:

```bash 
sudo mkdir -p /dev/hugepages
sudo mount -t hugetlbfs nodev /dev/hugepages
```

### 3. Step 2: Configure OVS-DPDK on Fedora 43

Initialize `OVS` to run in `DPDK` mode and pin its Poll Mode Driver (`PMD`) threads to dedicated cores.

```bash 
# 1. Enable DPDK in OVS
sudo ovs-vsctl --no-wait set Open_vSwitch . other_config:dpdk-init=true

# 2. Allocate DPDK memory (e.g., 2GB per NUMA socket)
sudo ovs-vsctl --no-wait set Open_vSwitch . other_config:dpdk-socket-mem="2048,0"

# 3. Dedicate Host Cores 2 and 3 strictly for OVS-DPDK Polling (PMD mask: 0xc = cores 2,3)
sudo ovs-vsctl --no-wait set Open_vSwitch . other_config:pmd-cpu-mask=0xc

# 4. Restart OVS to apply changes
sudo systemctl restart openvswitch
```

**Build the OVS Bridges & vhost-user Ports**

We will create the two bridges and expose `vhost-user` sockets for the Virtio VM to attach to.

```bash 
# Create Bridges
sudo ovs-vsctl add-br br-left -- set bridge br-left datapath_type=netdev
sudo ovs-vsctl add-br br-right -- set bridge br-right datapath_type=netdev

# Attach ConnectX-5 physical ports (DPDK interfaces use options:dpdk-devargs)
# Note: Locate your PCIe bus IDs via 'lspci | grep Mellanox' (e.g., 0000:01:00.0)
sudo ovs-vsctl add-port br-left dpdk0 -- set Interface dpdk0 type=dpdk options:dpdk-devargs=0000:01:00.0
sudo ovs-vsctl add-port br-right dpdk1 -- set Interface dpdk1 type=dpdk options:dpdk-devargs=0000:01:00.1

# Create vhost-user client ports for the Virtio VM
sudo ovs-vsctl add-port br-left vhost-vm0 -- set Interface vhost-vm0 type=dpdkvhostuserclient options:vhost-server-path=/var/run/openvswitch/vhost-vm0
sudo ovs-vsctl add-port br-right vhost-vm1 -- set Interface vhost-vm1 type=dpdkvhostuserclient options:vhost-server-path=/var/run/openvswitch/vhost-vm1
```

### 4. Step 3: Deploy the Virtio Benchmarking VM

Launch a high-performance VM using QEMU/KVM. The guest VM will use standard virtio-net drivers but will map
onto the OVS-DPDK user-space sockets.

Pin the VM to isolated cores 4 and 5 to avoid resource conflicts with the OVS PMD threads.

```bash
sudo qemu-system-x86_64 \
  -name dpdk-guest-vm -cpu host,migratable=off -enable-kvm -m 4096 \
  -object memory-backend-file,id=mem,size=4G,mem-path=/dev/hugepages,share=on \
  -numa node,memdev=mem \
  -smp 2,sockets=1,cores=2,threads=1 \
  -chardev socket,id=char0,path=/var/run/openvswitch/vhost-vm0,server=on \
  -netdev type=vhost-user,id=net0,chardev=char0,vhostforce=on \
  -device virtio-net-pci,netdev=net0,mac=52:54:00:12:34:56,csum=off,gso=off,guest_tso4=off,guest_tso6=off,guest_ecn=off \
  -chardev socket,id=char1,path=/var/run/openvswitch/vhost-vm1,server=on \
  -netdev type=vhost-user,id=net1,chardev=char1,vhostforce=on \
  -device virtio-net-pci,netdev=net1,mac=52:54:00:12:34:57,csum=off,gso=off,guest_tso4=off,guest_tso6=off,guest_ecn=off \
  -drive file=/var/lib/libvirt/images/fedora-testing.qcow2,format=qcow2 \
  -nographic

```
Note: Ensure taskset or QEMU pinning parameters pin this process to host cores 4 and 5.

Inside the Guest VM, run testpmd (part of the DPDK package) in io forwarding mode to loop traffic
between Virtio interfaces seamlessly:

```bash 
sudo dpdk-testpmd -l 0-1 -n 4 -- -i --forward-mode=io
testpmd> start
```

### 5. Step 4: Executing the Benchmark Matrix

To extract your four targeting metrics, execute these benchmark protocols using a software tool like
DPDK-Pktgen or TRex targeting the host's OVS interfaces.

1. Pure Virtio Packet Forwarding Efficiency (Mpps):

Small packet handling determines the absolute capability of your Virtio setup.

Method: Configure your packet generator to send continuous lines of 64-byte packets (the minimum Ethernet
size).

Metric to read: Gradually scale the injection rate up until you see packet drops reported by ovs-ofctl
dump-ports br-left. The highest stable throughput represents your maximum Mpps (Million Packets Per Second)
score.

2. Transmission Bandwidth Capability (Gbps) Method: Change the packet generation profile from 64 bytes to
   1518 bytes (standard MTU) or 9000 bytes (Jumbo frames).

Metric to read: Because larger frames reduce processing overhead per byte, your ConnectX-5 should easily
saturate. Look for the maximum steady-state throughput in Gbps, targeting the theoretical 25Gbps wire limit.


3. Average Latency (Microseconds) Method: Fire traffic at a conservative, non-saturating rate (e.g., 10% of
   maximum Mpps calculated in Test 1). Use the packet generator’s latency measurement capability to inject
   timestamped packets.

Metric to read: Measure the round-trip time delta. A highly optimized OVS-DPDK layout using vhost-user
client sockets combined with a ConnectX-5 crossover link should record single-digit to low double-digit
microsecond averages (≤10−20μs).

4. Host CPU Usage Because DPDK Poll Mode Drivers lock assigned CPU cores to 100% utilization, standard
   monitoring tools like top or htop will inaccurately display full usage even during idle periods.

Method: Use the specialized OVS appctl engine to parse internal processing metrics:

```bash sudo ovs-appctl dpif-netdev/pmd-stats-show ``` Metric to read: Analyze the ratio of processing
cycles vs. idle cycles. If processing cycles hover near 90-100% during your 64-byte Mpps test, your host CPU
core allocations are operating at max load handling the virtualized I/O.



