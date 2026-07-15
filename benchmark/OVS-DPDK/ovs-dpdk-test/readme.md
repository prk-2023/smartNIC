# OVS-DPDK Dual-Port Physical Loopback Benchmark

## Rest ovs settings, since ovsdb-server saves the configuration for ovs-vswitch server thats used to
forward traffic. This setting can conflict with the test setup.

./01-host_ovs_dpdk_dualport_reset.sh 

Wipes old/existing Open vSwitch configuration:
- force terminates if any VMs are running 
- reverts OVS to factory defaults ( `ovs-vsctl emer-reset` )
- delete any bridges that were setup ( or in memory `ovs-vsctl del-be  <bridge_name>`) 
- bring down any Old/persistent `tap` links ( `ip link set <tap> down; ip tuntap del <tap>` )
- flush runtime vhost sockets ( `/tmp/ovs-vsctl`,`/var/run/openvswitch/vhost-user*`)
- restart Open vSwitch daemon to cleanly bind with DPDK PMD from scratch. ( systemctl restart openvswitch)

--- 

## one-time host setup - binds BOTH ports to DPDK, no vfio/IOMMU concerns 

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
- prepare the system to use Open vSwitch (OVS) with DPDK as a very fast sw-switch connecting two physical NIC
ports of CX5 to two VM using `vhost-user`. 
- Also create a separate sw only mgmt network. 
- physicsl NICS :
    `PF0="enp1s0f0np0"`
    `PF0_PCI="0000:01:00.0"`

    `PF1="enp1s0f1np1"`
    `PF1_PCI="0000:01:00.1"`

- vhost-user socket: folder containing unix sockets that QEMU and OVS use to exchange pkts.
    `VHOST_SOCKET_DIR="/tmp/ovs-vhost"`

- Each VM gets one socket :
    `VM1 <----> /tmp/ovs-vhost/vhost-user0`
    `VM2 <----> /tmp/ovs-vhost/vhost-user1`

- PMD CPU mask: PMD_CPU_MASK="0xc" ==> 1100 
    `CPU0 0`
    `CPU1 0`
    `CPU2 1`
    `CPU3 1` 
  => tells OVS to run its pkts processing (PMD) threads on CPU-Core2 and CPU-Core3. 
  This can be verified after setup `htop` cmd on host will reveal core2 and core3 use almost 100% of CPU.

- set DPDK memory to 1 GB of hugepage memory for OVS ( `DPDK_SOCKET_MEM=1024`)

- Mgmt network:
  * Script creates Linux bridge : `br-mgmt` ( with 192.168.50.1/24 ) ( this is for mgmt access of VM not for
    high speed pkt fwding)
Note: 
    - check hugepages as DPDK requires hugepages because DMA buffers are allocated from physical contiguour
      memory. ( Script calculates for 2 VMs + 1 GB for OVS ) and estimates how many hugepages are required. 
    - If hugepages setting is not enough it has to be done manually.
    - Also make sure to give permission to access the hugepage: `sudo chmod 777 /dev/hugepages/`

- Script enables `ovsdb-server` and `ovs-vswitchd` and starts these serves 

- Enable DPDK: tells OVS to initialize DPDK 
    `other_config:dpdk-init=true` 
- then allocate memory for dpdk:
    `dpdk-socket-mem=1024`

- Next pin the pkt processing threads: ( After restarting OVS )
    `dpdk_initialized`

- create `br-left` using `datapath_type=netdev`
  Normal OVS `kernel datapath`
  DPDK OVS `userspace datapath (netdev)`

- Add Physical NIC  ( dpdk0 is backed by 0000:01:00.0 )
    `add-port br-left dpdk0`  

- Then script adds `vhost-user0` as `type=dpdkvhostuserclient`

`  OVS ----connects----> socket`
instead of creating it.

QEMU creates the socket.

This creates:
```txt
  PF0
   │
 dpdk0
   │
br-left
   │
vhost-user0
   │
  VM1
```

- Do the same for second NIC 
```txt 
  PF1
   │
 dpdk1
   │
br-right
   │
vhost-user1
   │
  VM2
```

NOTE:
- older version used `dpdkvhostuser` where OVS created the socket, New version uses `dpdkvhostuserclient`
  where QEMU creates the socket. 

- Create `br-mgmt` for management with IP 192.168.50.1 
- Create tap interfaces: which are connected to `br-mgmt`
    `tap-mgmt1`,`tap-mgmt2` 
- VM1 connects to `tap-mgmt1` and VM2 connects to `tap-mgmt2` 

- Print OVS config : print the final OVS config 
    $ sudo ovs-vsctl show 

Note: Script does not create a large switch, but it creates one bridge per physical port:

    `PF0 <---> VM1`
    `PF1 <---> VM2`

Traffic from one VMs cannot accidentally reach the other side unless we later add patch ports or OpenFlow
rules to connect the bridges. ( This gives isolation and gives each VM a dedicated physical interface )


- `vhost-user`: Instead of standard virtio network device (`virtio-net` shared mem via `virtqueues`(
  ringbuffers between host and hypervisor/device model (KVM)), `vhost-user` allows QEMU and OVS-DPDK to
  exchange packets through shared memory over Unix Domain Socket. This avoids the Linux kernel networking
  stack, reducing CPU overhead and latency, and increases throughput. ( primary performance benefits of
  OVS-DPDK )
  
=>  **./02-host_ovs_dpdk_dualport_setup.sh**

## use cloud-init to generate VM images ( one time )

- builds a bootable VM disk image for one virtual machine, creates a lightweight QCOW2 overlay on top of
  Fedora cloud image, injecting configurations via cloud-init, installs benchmarking tools, configures
  network and prepares VM to participate in OVS-DPDK test zone:

- Build VM images: 
=> **./03-build_sriov_vm_image.sh vm1 192.168.50.11 52:54:00:00:01:01 192.168.101.10 52:54:00:aa:bb:01**
=> **./03-build_sriov_vm_image.sh vm2 192.168.50.12 52:54:00:00:01:02 192.168.101.20 52:54:00:aa:bb:02**

Args:
* `vm_name`: vm hostname and disk name:  "vm1" and "vm2"
* `mgmt_ip`: IP on mgmt bridge 
* `mgmt_mac`: MAC for management NIC 
* `vf_ip`: IP on high speed data CX5 NIC 
* `vf_mac`: MAC of high speed  CX5 NIC 

- cloud-init process
```txt 
Quay container
       │
       ▼
podman pull
       │
       ▼
Extract disk image
       │
       ▼
guest-base.img

```
- overlay disks: ( instead of copying larger disk image for every VM Script creates a QCOW2 overlay )
```txt 
    guest-base.img
        ▲
        │ backing file
        │
      vm1.qcow2
```
Only changes made by the VM are stored in `vm1.qcow2` unchanged blocks are read from `guest-base.img`. (
saves disk space and creating time )

- Installs benchmark tools: iperf3, qperf, sysstat, ethtool, pciutils, dpdk, dpdk-tools 

- cloud-init: bulk of scripts generates a cloud-init config, which is executed automatically on the VM's
  first boot. 
  - User-creating ( bench/test1234 )
  - grant passwordless (sudo)
  - ssh password login 
  - install local (host) SSH public keys ( authorized hosts )
  - NetworkManager service connection profiles 
    * Mgmt NIC: `192.168.50.x` 
    ```
        Host 
         |
       br-mgmt 
         | 
      tap-mgmt1 
         |
         VM
    ``` 
    * Data NIC:
      `10.x.x.x`

  - benchmark server `iperf -s -p 5201` starts on boot automatically.
  - another vm can run `iperf3 -c 10.0.0.11`
  - `qperf` runs continuously as a server for latency and BW test.

  - Guest Monitoring ( VM ): create "/usr/local/bin/guest-monitor.sh" to collect performance data during
    benchmarking tests:
```
    Start CPU monitoring
        │
        ▼
    Read NIC counters
        │
        ▼
    Wait for benchmark duration
        │
        ▼
    Read NIC counters again
        │
        ▼
    Save logs

```
  - collects cpu utilization `mpstat`, NIC stats `ethtool -S` and writes them to `/var/log/<run-name>`

--- 

## VM launcher for benchmarking:

Script starts a QEMU virtual machine configured to use:
- Hugepage-backed RAM (required for good DPDK performance)
- A vhost-user NIC connected to Open vSwitch-DPDK
- A separate management NIC connected to the Linux bridge created by the previous script
- Pinned vCPUs, so the VM's virtual CPUs run on specific host CPU cores 

=> 
make sure of the permissions before launch:
sudo chmod 666 /tmp/ovs-vhost/vhost-user*
sudo chmod 777 /dev/hugepages 

./04-launch_ovs_dpdk_vm_generic.sh vm1 /tmp/ovs-vhost/vhost-user0 52:54:00:aa:bb:01 tap-mgmt1 52:54:00:00:01:01 4,5
./04-launch_ovs_dpdk_vm_generic.sh vm2 /tmp/ovs-vhost/vhost-user1 52:54:00:aa:bb:02 tap-mgmt2 52:54:00:00:01:02 6,7 

**Args :**
- vm_name = which disk to boot 
- vhost_socket = unix socket connecting to OVS 
- vhost_mac = Mac addr of the high-speed CX5 NIC 
- mgmt_tap = TAP interface on br-mgmt 
- mgmt_mac = MAC of mgmt NIC 
- vcpu_pin_csv = HOST CPU cores for the VMs vCPUs 

- Determines MEM=2G so the VM has 2GB RAM.  also expects to find vm1.qcow2 and vm1-seed.iso 

- checks pre-requisites:
    VM disk , cloud-init ISO, mgmt TAP interfaces exists, sufficient hugepages, /dev/hugepages mounted , if
    another instance of VM running with same name. 

- Verification:
  - Hugepage ( 2GB of RAM ) and compares with number of free hugepages reported by kernel, and its mounted 
  - umask: temporarily allows newly created files to be world RW. Since QEMU will create vhost-user socket,
    and OVS must be able to connect to it regardless of which user owns the QEMU process. 
  - Storage: QCOW2 overlay ( vm1.qcow2)

- High-speed network interface (vhost-user) 
    * `-chardev socket,...`  char device backed by unix socket 
    * `-netdev vhost-user` 
    * `-netdev virtio-net-pci` 
    * pkt path: 
```
Physical NIC
      │
   Open vSwitch
      │
dpdkvhostuserclient
      │
Unix socket
      │
QEMU vhost-user server
      │
  virtio-net
      │
    Guest
```
   * `server=on` QEMU creates and listens on the socket, while Open vSwitch (configured earlier with
    dpdkvhostuserclient) actively connects to it

- Mgmt network: ( second network interface )
  - `netdev tap, ...` connects to the tap interface created by the first script, this is used for ssh and
    mgnt traffic not for benchmarking. 

- vCPU pinning: each gust vCPU runs as separate host thread. QEMU names these threads `CPU0, CPU1...` script
  scans QEMU process task list, identifies those threads by name and uses `taskset` to bind each one to
  specific physical CPU core supplied on command line. `ex: 4,5 
```
Guest vCPU 0  ─────► Host CPU 4

Guest vCPU 1  ─────► Host CPU 5
```

This script completes:
- KVM HW acceleration 
- 2GB hugepage backed memory 
- vhost-user data plane NIC conncted directly to appropriate OVS-DPDK bridge 
- A separate mgmt NIC connected to linux bridge  
- cloud-init configuration applies on first boot. 
- virtual CPUs pinned to the specified host cores for predictable performance 

--- 

## benchmark script: performance tests 

Runs the performance tests, collects stats, from host and both VMs and generates summery of results.

```txt 
Verify SSH connectivity
        │
        ▼
Save OVS PMD statistics
        │
        ▼
Start host CPU monitoring
        │
        ▼
Start monitoring inside both VMs
        │
        ▼
Run TCP benchmark
        │
        ▼
Run UDP benchmark
        │
        ▼
Run latency benchmark
        │
        ▼
Collect PMD statistics
        │
        ▼
Copy guest logs
        │
        ▼
Generate summary.json

```
- start services to run the test:
```
ssh -i ~/.ssh/id_rsa bench@192.168.50.12 "systemctl is-active iperf3-server qperf-server"
active
active 
```
=> ./05-run_test_ovs_dpdk_dualvm.sh test1 

Creates results/test1/ folder with benchmark data.

- Script defines:
```
VM1 Management IP
192.168.50.11

VM2 Management IP
192.168.50.12
```
- Actual traffic is sent to DPDK data interface 
```
VM2_DATA_IP
192.168.101.20
```

- first verify cloud-init completed, network is working, ssh is correct and both VMs are alive 
```
ssh VM1 true
ssh VM2 true
```
If VM can not reach benchmark stops. 

- Save PMD stats (before)
```
ovs-appctl dpif-netdev/pmd-stats-show 
```
Captures initial states of OVS-DPDK pkt processing thread.
PMDs(poll mode drivers) are the worker threads that continuously poll the NICs instead of waiting for 
interrupt. Before snapshot if for baseline. 

- `mpstat -P ALL` records CPU utilization for every logical CPU per second
- start guest monitoring : `guest-monitor.sh` from image building script  
  `systemctl start guest-monitor@run1.service`
  Collects : CPU untilization , NIC stats, benchmark logs at /var/log/bench/run1/ 

- TCP throughput: (Benchmark 1)

    `iperf3` 
    Using 4 parallel streams, for 60 secs, JSON output. 
 ```
    VM1
iperf3 client
      │
      │
      ▼
  OVS-DPDK
      │
      ▼
    VM2
iperf3 server
```
throughput, retransmissions, CPU usage 

- UDP pkt rate (Benchmark 2)
    * With 64-byte packets
    * Unlimited bandwidth


NOTE: 
- Although OVS uses DPDK, the benchmark itself is generated by a normal Linux application (iperf3). Packet
  generation still passes through the guest kernel's networking stack, so this test measures end-to-end VM
  performance, not the maximum packet rate the underlying DPDK datapath could theoretically achieve.


- latency ( Benchmark 3 )
    `qperf` 
    TCP - latency 
    UDP - latency 

- Collect PMD stats after 
    `pmd-stats-show` 

Also records 
    `pmd-perf-show`
This provides info on how OVS-DPDK PMD threads behave during the benchmark, including how much time they
spent processing packets vs idle polling. 

- python embedded script: for parse the collected files and extract key metrics. 

- final result/: 
```
results/
└── run1/
    ├── iperf3_tcp.json
    ├── iperf3_udp_pps.json
    ├── qperf_latency.txt
    ├── host_cpu.log
    ├── pmd_stats_before.txt
    ├── pmd_stats_after.txt
    ├── pmd_perf_after.txt
    ├── VM1_logs/
    ├── VM2_logs/
    └── summary.json
```

---
```txt 
1. Host setup
   │
   ├── Install OVS-DPDK
   ├── Configure DPDK
   ├── Create br-left / br-right
   └── Create br-mgmt
        │
        ▼
2. Image creation
   │
   ├── Build qcow2 overlay
   ├── Install packages
   ├── Configure networking
   └── Build cloud-init ISO
        │
        ▼
3. Launch SCRIPT
   │
   ├── Launch QEMU
   ├── Connect to OVS
   ├── Allocate hugepage RAM
   └── Pin VM CPUs 

4. Benchmark SCRIPT 
   │
   ├── 
   ├── 
   ├── 
   └──


```

## Additional checks:


### 1. Confirm DPDK is initialized and using the right driver

```bash
sudo ovs-vsctl get Open_vSwitch . dpdk_initialized
sudo ovs-vsctl get interface dpdk0 status
sudo ovs-vsctl get interface dpdk1 status
```
Look for `driver_name=net_mlx5` in the status map : that confirms OVS is using the DPDK mlx5 poll-mode
driver for these ports, not a generic system/kernel netdev.

### 2. Confirm PMD threads are actually running and on the expected cores

```bash
sudo ovs-appctl dpif-netdev/pmd-stats-show
```
You should see two PMD thread entries (one per core in your `0xC` mask → cores 2 and 3), each showing
non-zero **`packets received`** and **`avg processing cycles per packet`** after a test run. If both are
zero, packets aren't reaching DPDK poll mode at all — traffic would be going somewhere else entirely (or not
flowing).

Cross-check the CPU cores directly:
```bash
mpstat -P 2,3 1 5
```
These two cores should sit near 100% *even at idle* — that's expected and correct for PMD busy-polling, not
a bug. If they're near 0% while traffic is running, the PMD threads aren't polling those queues.

### 3. Confirm packets are bypassing the kernel netdev stack (the real kernel-bypass proof)

This is the important nuance for a ConnectX-5: unlike Intel NICs (which fully unbind from the kernel and
rebind to `vfio-pci`), Mellanox's mlx5 DPDK PMD uses a **bifurcated driver model** — the kernel `mlx5_core`
module stays loaded and the physical interface (`enp1s0f0np0`) still exists in `ip link`, but DPDK talks to
the NIC directly via verbs/queue-pairs, bypassing the kernel's normal RX/TX packet path. So checking
`driver_name` in `/sys/bus/pci/.../driver` won't show `vfio-pci` here — that check doesn't apply to this NIC
family.

Instead, the correct test is: **kernel netdev packet counters should stay flat while traffic flows through
OVS-DPDK.**

```bash
# before test
ethtool -S enp1s0f0np0 | grep -E "^\s*rx_packets:|^\s*tx_packets:"

# start a test run (or just run iperf3 manually for 10s)

# after test
ethtool -S enp1s0f0np0 | grep -E "^\s*rx_packets:|^\s*tx_packets:"
```
If these counters **don't increase** (or only tick up negligibly from unrelated LLDP/ARP background traffic)
while gigabits of iperf3 traffic are flowing, that's your proof the data path is bypassing the kernel stack
— the packets are being consumed directly by the DPDK PMD via the NIC's hardware queues, not passed up
through the normal kernel RX path.

Compare that against the OVS-side counters for the same interface, which **should** be climbing:
```bash
sudo ovs-vsctl get interface dpdk0 statistics
```

## 4. One more corroborating signal: OVS startup log

```bash
sudo journalctl -u openvswitch | grep -iE "EAL|mlx5|dpdk" | tail -40
```
You should see EAL (DPDK Environment Abstraction Layer) initialization lines and successful probe of the
mlx5 PCI devices at OVS startup — confirms the ports were brought up under DPDK from the start, not silently
falling back to a kernel netdev port type.

---

Putting it together: if `driver_name=net_mlx5`, `pmd-stats-show` shows growing packet counts on both PMD
cores, those cores sit pinned near 100%, and `ethtool -S` on the physical kernel interfaces stays flat
during a run — that's a complete, verifiable chain confirming DPDK PMD is active and the kernel network
stack is genuinely being bypassed. Want me to fold a couple of these checks into
`05-run_test_ovs_dpdk_dualvm.sh` automatically (e.g. capture `ethtool -S` before/after alongside the PMD
stats it already collects) so future runs self-verify this without manual steps?


-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=
# check "dpdk_initialized: true" and both port link_state lines

# 2. build both VM images (reuses the exact same script from the SR-IOV leg -
#    it's generic mgmt+dataplane, doesn't care what's driving the dataplane NIC)
./03-build_sriov_vm_image.sh  vm1 192.168.50.11 52:54:00:00:01:01 192.168.101.10 52:54:00:aa:bb:01
./03-build_sriov_vm_image.sh vm2 192.168.50.12 52:54:00:00:01:02 192.168.101.20 52:54:00:aa:bb:02

# 3. launch both, pointing at their respective vhost-user sockets
sudo chmod 777 /var/run/openvswitch
sudo chmod 666 /var/run/openvswitch/vhost-user*

./launch_ovs_dpdk_vm_generic.sh vm1 /tmp/ovs-vhost/vhost-user0 52:54:00:aa:bb:01 tap-mgmt1 52:54:00:00:01:01 4,5
or
./launch_ovs_dpdk_vm_generic.sh vm1 /var/run/openvswitch/vhost-user0  52:54:00:aa:bb:01 tap-mgmt1 52:54:00:00:01:01 4,5

./launch_ovs_dpdk_vm_generic.sh vm2 /tmp/ovs-vhost/vhost-user1 52:54:00:aa:bb:02 tap-mgmt2 52:54:00:00:01:02 6,7
or 
./launch_ovs_dpdk_vm_generic.sh vm2 /var/run/openvswitch/vhost-user1  52:54:00:aa:bb:02 tap-mgmt2 52:54:00:00:01:02 6,7
# check both "link_state: up" lines before proceeding

# 4. run the benchmark
./run_test_ovs_dpdk_dualvm.sh ovs_dpdk_dualvm_test_run1


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

#  5. teardown the OVS-DPDK host setting: 
./tear_down_ovs_dpdk.sh     




----

- start vm1 
./04-launch_ovs_dpdk_vm_generic.sh vm1 /tmp/ovs-vhost/vhost-user0 52:54:00:aa:bb:01 tap-mgmt1 52:54:00:00:01:01 4,5
- start vm2 
./04-launch_ovs_dpdk_vm_generic.sh vm2 /tmp/ovs-vhost/vhost-user0 52:54:00:aa:bb:02 tap-mgmt1 52:54:00:00:01:02 6,7

ssh login  to check:
$ ssh -i ~/.ssh/id_rsa bench@192.168.50.11

- start services to run the test:
ssh -i ~/.ssh/id_rsa bench@192.168.50.12 "systemctl is-active iperf3-server qperf-server"
active 
active 

- Now run the run script
./05-run_test_ovs_dpdk_dualvm.sh ovs_dpdk_dualvm_test_run1

