# vdpa kernel sw simulator:

step-by-step instructions for 2 methods to gather all the benchmark data:
------------------------------
## Method A: Setup the Kernel Software Simulator (vdpa-sim-net)
This method benches the pure software performance and behavioral overhead of the Linux Kernel's internal
vDPA framework, completely independent of physical network limits.
1. Load the core simulator kernel modules:

```bash 
sudo modprobe vdpa
sudo modprobe vhost-vdpa
sudo modprobe vdpa-sim-net
```

2. Create the simulated vDPA device instance:

```bash 
sudo vdpa dev add name vdpa0 mgmtdev vdpasim_net
```

3. Identify the dynamically allocated `vhost-vdpa` character device:

$ ls -l /dev/vhost-vdpa*

(Take note of the device path output, usually it will be /dev/vhost-vdpa-0).
4. Launch your QEMU VM targeting the simulated device:

$ sudo qemu-system-x86_64 \
  -enable-kvm \
  -m 4G -smp 4 \
  -cpu host \
  -drive file=your_vm_image.qcow2,format=qcow2 \
  -chardev socket,id=ch0,path=/tmp/vhost-vdpa0.sock \
  -netdev vhost-vdpa,id=net0,vhostdev=/dev/vhost-vdpa-0 \
  -device virtio-net-pci,netdev=net0,mac=00:11:22:33:44:55

------------------------------

## Method B: Setup Native SR-IOV Passthrough (The Hardware Ceiling)
This method establishes the "perfect score" ceiling of  CX-5 card. 
It shows the absolute maximum line-rate performance the silicon can deliver to a VM when bypassing all 
virtualization layers.

1. Revert your card back to Legacy SR-IOV mode (out of switchdev):

# Replace enp1s0f0np0 with your actual PF interface name
`sudo devlink dev eswitch set pci/0000:01:00.0 mode legacy`

2. Generate a Virtual Function (VF):

`sudo echo 1 > /sys/class/net/enp1s0f0np0/device/sriov_numvfs`

3. Identify the PCI address of your newly spawned VF:

`ls -l /sys/class/net/enp1s0f0np0/device/virtfn0`

(For this example, let's assume the VF output maps to address 0000:01:00.1).
4. Unbind the VF from the standard network driver and bind it to vfio-pci:

```bash 
sudo modprobe vfio-pci
# Unbind from standard mlx5
sudo echo "0000:01:00.1" > /sys/bus/pci/drivers/mlx5_core/unbind
# Bind to vfio-pci
sudo echo "0000:01:00.1" > /sys/bus/pci/drivers/vfio-pci/bind
```

5. Launch your QEMU VM passing the raw PCI hardware mapping directly:

```bash 
$ sudo qemu-system-x86_64 \
  -enable-kvm \
  -m 4G -smp 4 \
  -cpu host \
  -drive file=your_vm_image.qcow2,format=qcow2 \
  -device vfio-pci,host=01:00.1
```
(Inside this guest VM, you must load the standard Mellanox mlx5_core network driver to initialize benchmarking).
------------------------------
Which benchmark traffic utility are you planning to run (iperf3, netperf, or DPDK pktgen) so I can help
optimize your sysctl memory windows or CPU pinning parameters?


