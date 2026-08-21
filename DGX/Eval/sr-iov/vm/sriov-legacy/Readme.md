```text 
+-----------------------------------------------------------------------------------+
 | GB10 Host (ARM64 Grace Blackwell)                                                 |
 |                                                                                   |
 |  +-------------------------+                       +---------------------------+  |
 |  | VM1 (t2-vm1)            |                       | VM2 (t2-vm2)              |  |
 |  | Guest OS (mlx5_core)    |                       | Guest OS (mlx5_core)      |  |
 |  | VF0 (192.168.100.11/24)  |                       | VF0 (192.168.100.12/24)   |  |
 |  +------------+------------+                       +-------------+-------------+  |
 |               | (vfio-pci direct passthrough)                    |                |
 |               v                                                  v                |
 |  +-------------------------+                       +---------------------------+  |
 |  | PF0 (enp1s0f0np0)       |                       | PF1 (enp1s0f1np1)         |  |
 |  | eSwitch Mode: legacy    |                       | eSwitch Mode: legacy      |  |
 |  | ConnectX-7 Port 0       |                       | ConnectX-7 Port 1         |  |
 |  +------------+------------+                       +-------------+-------------+  |
 +---------------+--------------------------------------------------+----------------+
                 |                                                  |
                 +================== DAC Cable =====================+ 

``` 

Key features of SR-IOV Legacy Mode:

- Direct Driver in Guest: The guest OS uses the native mlx5_core driver to interact directly with hardware VFs (unlike VirtIO/vhost-net).

- eSwitch Legacy Mode: Port steering and switching are handled directly by Mellanox hardware tables without Open vSwitch or kernel bridge involvement on the host.

- Hardware Offloading: Checksum, LRO/GRO, and TSO offloads run natively in ConnectX-7 ASIC silicon.


---
 recommended execution sequence for the testing suite:

1. **Host Setup:** `./t2_host_setup-sriov_legacy.sh` (Creates VFs, sets legacy mode, binds to `vfio-pci`)
2. **Image Building:** `./t2_build_guest_image.sh 1` and `./t2_build_guest_image.sh 2` (Generates QCOW2 & cloud-init ISOs)
3. **Launch VMs:** `./t2_launch_vm.sh 1` and `./t2_launch_vm.sh 2` (Starts KVM guests with pinned cores and VF passthrough)
4. **Run Benchmarks:** `./t2_run_benchmarks.sh` (Executes iperf3/qperf test battery)
5. **Cleanup:** `./t2_host_reset-sriov_legacy.sh` (Stops QEMU, releases hugepages, and destroys VFs)#


./t2_host_setup-sriov_legacy.sh
or 
./t2_host_setup-sriov_legacy-jumbo.sh <= for jumbo frame

./t2_build_guest_image.sh 1
./t2_build_guest_image.sh 2
./t2_launch_vm.sh 1
./t2_launch_vm.sh 2
./t2_run_benchmarks.sh
sudo ./t2_host_reset-sriov_legacy.sh

