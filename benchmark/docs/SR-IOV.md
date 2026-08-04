# SR-IOV: 


Ref:

- https://docs.kernel.org/PCI/pci-iov-howto.html
- https://networking-docs.nvidia.com/doca/archive/2-9-2/single-root-io-virtualization-sr-iov
- https://learn.microsoft.com/en-us/windows-hardware/drivers/network/single-root-i-o-virtualization--sr-iov-

## SR-IOV: 

Single Root I/O Virtualization Specification is a PCIe extended capability that enables a single physical HW
device. Such as a NIC to partition itself into multiple distinct, lightweight Virtual instance. 

These instances can be shared directly with VMs or containers, bypassing heavy hypervisor SW translation
layers to achieve near-native performance. 

### 1. Core Architecture Concepts: 

An SR-IOV enabled ecosystem relies on two primary components defined by the PCI-SIG specification and
managed by the Linux kernel. 

#### Physical Function (PF):

- The Full-features PCIe device. 
- Managed directly by the host OS's native device driver ( the PF driver )
- Processes full configuration capabilities to create, manage, and destroy virtual instances.

#### Virtual Function (VF):

- Lightweight, isolated PCIe functional slices derived from the Physical Function. 

- Each VFs acts as an independent PCIe device processing its own Unique PCI configuration space, base
  address registers (BARs), memory space, and interrupt streams. 

- Assigned directly to guest OS or user-space applications ( vio VFIO or KVM passthrough ), bypassing the
  host network stack for low-latency, high throughput operations. 

### 2. System Requirements: 

To deploy and utilize SR-IOV on a Linux host, verify that the following prerequisites are met:

#### HW Support: 

- A motherboard with BIOS/UEFI support for SR-IOV and Intel VT-d ( or AMD-Vi/ IOMMU ) enabled. 
- An SR-IOV capable physical device ( e.g: enterprise network adapters from Intel, NVIDIA/Mellanox, or
  Broadcom ).

#### Kernel & Driver Support: 

- An Linux kernel compiled with PCIe SR-IOV core support ( `CONFIG_PCI_IOV` ).
- An active PF Kernel module that implements `srio_configure` callbacks ( e.g: `ixgbe`, `i40e`,
  `mlx5_core`).


### 3. Enabling and Configuring SR-IOV in Linux: 

#### Step 1: Enable IOMMU in Kernel Boot Parameters 

To allow safe HW memory isolation and device passthrough, enable the Input-Output Memory Management Unit 
(IOMMU) at boot time.

- For Intel processors, modify your GRUB configuration (e.g., /etc/default/grub) to include intel_iommu=on:

```bash 
GRUB_CMDLINE_LINUX_DEFAULT="quiet splash intel_iommu=on"
```


- For AMD processors, use amd_iommu=on:
```bash 
GRUB_CMDLINE_LINUX_DEFAULT="quiet splash amd_iomsmu=on"
```

Update your bootloader configuration 
(e.g., sudo update-grub or sudo grub2-mkconfig -o /boot/grub2/grub.cfg) or use grubby, and reboot the host.

#### Step 2: Locate the Physical Function (PF)

Identify the target network interface and its corresponding PCI address using lspci and ethtool:

```bash 
$ lspci | grep -i ethernet
03:00.0 Ethernet controller: Intel Corporation Ethernet Controller X710 for 10GbE SFP+ (rev 02)
```

#### Step 3: Instantiate Virtual Functions (VFs): 

Modern Linux kernels handle `VF` creation dynamically through sysfs without requiring module reloads.

Determine the maximum number of `VFs` supported by the device and write your desired count to the 
`sriov_numvfs` file under the device's sysfs path:

```bash 
# Check maximum allowed VFs (optional step)
cat /sys/bus/pci/devices/0000\:03\:00.0/sriov_totalvfs

# Enable 4 Virtual Functions on the PF
echo 4 > /sys/bus/pci/devices/0000\:03\:00.0/sriov_numvfs
```

To verify that the VFs have spawned successfully on the PCIe bus, run lspci again:

```bash 
$ lspci | grep -i "Virtual Function"
03:00.1 Ethernet controller: Intel Corporation Ethernet Controller X710 Virtual Function (rev 02)
03:00.2 Ethernet controller: Intel Corporation Ethernet Controller X710 Virtual Function (rev 02)
03:00.3 Ethernet controller: Intel Corporation Ethernet Controller X710 Virtual Function (rev 02)
03:00.4 Ethernet controller: Intel Corporation Ethernet Controller X710 Virtual Function (rev 02)
```

### 4. Persisting VF Configuration Across Reboots

Sysfs configurations do not persist across system reboots. To ensure VFs are generated automatically on
startup, configure system parameters using one of the standard Linux approaches:

#### Option A: Using udev Rules:

Create a custom udev rule under `/etc/udev/rules.d/10-sriov.rules`:

```txt 
ACTION=="add", SUBSYSTEM=="pci", KERNEL=="0000:03:00.0", ATTR{sriov_numvfs}="4"
```

#### Option B: Using Driver Module Options

Some drivers support module parameters defined in /etc/modprobe.d/ files. For instance, for the ixgbe
driver, you can specify the number of VFs per port:

```txt 
options ixgbe max_vfs=4,4
```

### 5. Assigning VFs to Virtual Machines (KVM/libvirt)

Once VFs are exposed on the host, they can be handed off directly to KVM/QEMU virtual machines using libvirt
XML configurations or passthrough tools (vfio-pci).

An example XML snippet for a libvirt guest interface definition targeting an SR-IOV Virtual Function
(03:00.1):

```xml 
<interface type='hostdev' managed='yes'>
  <source>
    <address type='pci' domain='0x0000' bus='0x03' slot='0x00' function='0x1'/>
  </source>
</interface>
```

## IOMMU Group Binding:

To pass VF to virtual machines or container, the kernel needs IOMMU active and properly mapped: 

### Verify IOMMU is active in kernel: 

Ensure `intel_iommy=on` or `amd_iommu=on` is present in GRUB command line:

Check status with:
```bash 
dmesg | grep -i iommu 
```

### Inspect IOMMU group for CX-5 card:

```bash 
readlink /sys/class/net/enp1s0f0np0/device/iommu_group/devices/*
```

### Bind a `VF` to `VFIO-PCI` (for VM passthrough/DPDK):

```bash 
modprobe vfio-pci
# Find the PCI address of your VF (e.g., 0000:01:00.1)
virsh nodedev-detach pci_0000_01_00_1
```


