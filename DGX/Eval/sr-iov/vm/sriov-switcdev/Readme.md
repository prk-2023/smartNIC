# SR-IOV Switchdev Mode VM Testing Suite (MTU 9000)

Quick start guide for testing and benchmarking SR-IOV eSwitch Switchdev Mode with hardware-offloaded packet steering (OVS or TC Flower) on NVIDIA GB10 (ARM64 Grace Blackwell) and ConnectX-7 NICs.


```text 
Data Flow Diagram

+------------------------------------------------------------------------------------+
| GB10 Host (ARM64 Grace Blackwell)                                                  |
|                                                                                    |
|  +-------------------------+                        +---------------------------+  |
|  | VM1 (t2-vm1)            |                        | VM2 (t2-vm2)              |  |
|  |  ens-test (MTU 9000)    |                        |  ens-test (MTU 9000)      |  |
|  |  IP: 192.168.100.11/24   |                        |  IP: 192.168.100.12/24   |  |
|  +------------+------------+                        +-------------+-------------+  |
|               | (vfio-pci direct passthrough)                     |                |
|               v                                                   v                |
|  +-------------------------+                        +---------------------------+  |
|  | VF Representor: pf0vf0  |                        | VF Representor: pf1vf0    |  |
|  |            |            |                        |            |            |  |
|  |    [ HW Offload Path ]  |                        |    [ HW Offload Path ]  |  |
|  |     (OVS / TC Flower)   |                        |     (OVS / TC Flower)   |  |
|  |            v            |                        |            v            |  |
|  | PF0 (enp1s0f0np0)       |                        | PF1 (enP2p1s0f1np1)       |  |
|  +------------+------------+                        +-------------+-------------+  |
+---------------+---------------------------------------------------+----------------+
                |                                                   |
                +=================== DAC Cable =====================+
```


## Execution Run Order

Follow these steps in sequential order to set up, launch, benchmark, and tear down the environment:

- Step 1: Edit Configuration

Review interface names, MTU settings, and IP addresses:

vi t2_config_switchdev.sh


- Step 2: Configure Host System & Hardware Steering Mode

Prepare host eSwitch switchdev mode, assign VF passthrough drivers, and configure datapath steering rules.

Option A: OVS HW-Offload Mode (Default)

sudo ./t2_host_setup-sriov_switchdev.sh --mode ovs


Option B: Pure TC Flower Mode

sudo ./t2_host_setup-sriov_switchdev.sh --mode tc


- Step 3: Build Guest Disk Images & Seed ISOs

Build the guest base images and inject network/cloud-init parameters (MTU 9000, Static IPs, benchmarks):

./t2_build_guest_image.sh 1
./t2_build_guest_image.sh 2


- Step 4: Launch Guest Virtual Machines

Start QEMU guest instances with vfio-pci direct VF assignment:

./t2_launch_vm.sh 1
./t2_launch_vm.sh 2


- Step 5: Execute Network Benchmarks

Run reachability verification, ICMP Jumbo ping, qperf TCP/UDP latency, and iperf3 throughput tests:

./t2_run_benchmarks.sh


- Step 6: Teardown & Reset

Stop running VMs, clear OVS/TC rules, release hugepages, and return host eSwitch to legacy mode:

sudo ./t2_host_reset-sriov_switchdev.sh

---
Run Order:
=========
sudo ./t2_host_setup-sriov_switchdev.sh --mode ovs
or 
sudo ./t2_host_setup-sriov_switchdev.sh --mode tc

./t2_build_guest_image.sh 1
./t2_build_guest_image.sh 2

./t2_launch_vm.sh 1
./t2_launch_vm.sh 2

./t2_run_benchmarks.sh
sudo ./t2_host_reset-sriov_switchdev.sh

