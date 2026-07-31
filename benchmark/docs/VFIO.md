# VFIO: Virtual Function IO


VFIO is a linux technology designed to safely and securely expose direct device access ( PCI passthrough )
to user-space applications and virtual machines (VMs).

By bypassing the host kernel driver stack for a specific hardware device, VFIO provides near-native
performance, making it ideal for high-throughput components like NVIDIA (Mallanox) ConnectX(5,6,7) high
performance NIC's.

This is common in GPU virtualization ( passing an NVIDIA GPU to a VM) and equally common for high-perfomance
NICs like CX,5,6,7, Intel E810, Broadcom adapters. 


## What VFIO does:

Normally Linux owns the NIC:

```txt 
+-------------------------+
| Linux Host              |
|                         |
| mlx5_core driver        |
|        │                |
|   ConnectX-7            |
+-------------------------+
```

With VFIO the Linux networking driver is detached from the device and replaced by the generic `vfio-pci`
driver. 

```txt 
+-------------------------+
| Linux Host              |
|                         |
| vfio-pci driver         |
|        │                |
|   ConnectX-7            |
+-------------------------+
```

The hypervisor (typically QEMU/KVM) can then map the device directly into the guest's PCIe bus:

```text 
                 Host
+--------------------------------------+
|                                      |
|    vfio-pci                          |
|        │                             |
|   ConnectX-7                         |
|        │                             |
|   IOMMU maps DMA safely              |
|        │                             |
+--------┼-----------------------------+
         │ PCI Assignment
         ▼
+--------------------------------------+
| VM                                   |
|                                      |
| mlx5 driver                          |
|        │                             |
|   ConnectX-7 (appears native)        |
+--------------------------------------+
```

From the Guest's perspective, it looks like the NIC is physically installed in the VM.

## IOMMU Is required for VFIO.

Without IOMMU, the PCIe device can perform DMA to arbitrary physical memory, including memory owned by the
host or other VMs.

The IOMMU acts like a memory-management unit for devices, It translates and restricts DMA so that:
- NIC can access only the assigned VM's memory. 
- It cannot read/write host memory.
- multiple VM's remain isolated.

This is why you will typically enable Intel `VT-d` or AMD-Vi in the BIOS and boot Linux with intel_iommu=on
or amd_iommu=on.

[ Deatils: VFIO and HW architecture:

1. How PCIe DMA Works natively: 
- Unlike CPU memory accesses, which go through page tables and memory management units (MMUs) to 
  enforce security boundaries, traditional PCIe devices use Direct Memory Access (DMA). 
  A PCIe device is given a physical memory address by a driver and can read or write to that address
  directly over the system bus. [Kernel docs VFIO ](https://docs.kernel.org/driver-api/vfio.html)

2. Role of IOMMU:
- An IOMMU (Input-Output Memory Management Unit, such as Intel VT-d or AMD-Vi) acts as an 
  MMU for I/O devices. It intercepts DMA requests from PCIe devices and translates device-visible 
  addresses (IOVAs) to physical RAM addresses. 
  Crucially, it enforces isolation and permission checks—meaning if a device tries to access a physical
  memory address it hasn't been explicitly granted access to, the IOMMU blocks the transaction and 
  triggers a fault.  

3. With Out IOMMU (Risk)
- If an IOMMU is absent:
    - No Translation/Protection: The PCIe device has a flat, unrestricted view of the entire system physical
      memory.
    - Arbitrary Access: The device can read or write to any physical memory address.
    - Security Implications for VMs: This is why passing a physical GPU or network card through to a Virtual
      Machine (VM) safely is impossible without an IOMMU. 
      If a VM had direct control over a device without an IOMMU protecting the host, malicious or buggy
      guest code could program the device to overwrite host kernel memory, hypervisor structures, or 
      data belonging to other VMs.     
]

## Basic Workflow:

### Step 1: Enable IOMMU

For Intel:

```text
intel_iommu=on
```

For AMD:

```text
amd_iommu=on
```

After rebooting, you can verify with:

```bash
dmesg | grep -i iommu
```

---

### Step 2: Find the NIC

For example:

```bash
lspci
```

might show:

```text
18:00.0 Ethernet controller: NVIDIA ConnectX-7
18:00.1 Ethernet controller: NVIDIA ConnectX-7
```

Or in more detail:

```bash
lspci -nn
```

Example:

```text
18:00.0 Ethernet controller [0200]: Mellanox Technologies MT2910 [15b3:1021]
```

The vendor/device IDs (`15b3:1021` in this example) are used when binding the device to `vfio-pci`.

---

### Step 3: Unbind from the host driver

Initially:

```text
mlx5_core
        │
ConnectX-7
```

You unbind it:

```bash
echo 0000:18:00.0 > /sys/bus/pci/drivers/mlx5_core/unbind
```

Then bind it to VFIO:

```bash
echo vfio-pci > /sys/bus/pci/devices/0000:18:00.0/driver_override
echo 0000:18:00.0 > /sys/bus/pci/drivers/vfio-pci/bind
```

Now Linux no longer uses that NIC.

---

### Step 4: Tell QEMU to use it

Typical QEMU option:

```bash
-device vfio-pci,host=18:00.0
```

Libvirt generates this XML:

```xml
<hostdev mode='subsystem' type='pci' managed='yes'>
    <source>
        <address domain='0x0000'
                 bus='0x18'
                 slot='0x00'
                 function='0x0'/>
    </source>
</hostdev>
```

The VM boots and discovers a physical ConnectX adapter.

---

## Inside the VM

Install the standard Mellanox/NVIDIA drivers (`mlx5_core` is included in modern Linux kernels), and you'll
see something like:

```bash
lspci
```

```
18:00.0 Ethernet controller
```

The guest can then use:

* Ethernet
* RoCE
* RDMA (`ibverbs`)
* GPUDirect RDMA (if supported by the overall platform)
* DPDK
* DOCA (where applicable)

The host cannot use that NIC while it is assigned to the VM.

---

## Can you assign only one port?

This depends on how the hardware exposes the ports.

Some dual-port adapters appear as:

```text
18:00.0 Port 1
18:00.1 Port 2
```

In that case, you can pass through only one PCI function.

Others expose both ports through a single PCI function:

```text
18:00.0
   ├── Port 1
   └── Port 2
```

Then both ports move together.

On most modern ConnectX adapters, `lspci` will show the actual function layout, which determines the assignment granularity.

---

## How is this used in practice?

A common setup for an AI server might look like:

```text
Host
├── GPU0 ── VFIO ─────► VM A
├── GPU1 ── VFIO ─────► VM A
├── ConnectX Port 1 ─► VFIO ─► VM A
│
└── 10 GbE NIC ───────► Host management
```

The VM owns the GPUs and the high-speed fabric, while the host retains the management network.

## multiple VMs: to share a single CX NIC.

If you want **multiple VMs** to share a single ConnectX-7 while still using RDMA, then **SR-IOV** is
generally the better fit. 

In that model, the host keeps control of the physical function (PF) and creates multiple virtual functions
(VFs), each of which can be assigned independently to different VMs. 
That's the architecture commonly used in OpenStack, VMware, and Kubernetes clusters for high-performance networking.

So to map a single PCIe Physical Function across multiple VMs, the network card must support SR-IOV.

- A single Physical Function (PF) can slice itself into multiple Virtual Functions (VFs). Each VF acts as a
  lightweight, independent PCIe device that can then be independently assigned to a unique VM using VFIO.

- The Limits: The maximum number of VMs/VFs mapped to a single PF depends entirely on the hardware design
  of the NIC and its firmware/specifications:
    
  - Typical Server NICs (like Intel or Mellanox/NVIDIA adapters) commonly support anywhere from 32 to 256
    Virtual Functions per Physical Function.

  - High-end or enterprise NICs can sometimes support up to 512 or even dual-thousands of VFs theoretically,
    though practical limits are usually bounded by the physical hardware resources (such as on-chip memory
    for configuration spaces and available MSI-X interrupt vectors).

### Rule:
- `1 VM` = `1 VF` (via VFIO passthrough). 
  Therefore, a single Physical Function can support as many VMs as the NIC has maximum supported VFs
  (commonly ranging from 32 to 256+ per port).


## SR-IOV:

When you create SR-IOV Virtual Functions (VFs), the Linux kernel automatically treats them as new PCIe
devices and automatically binds them to the host's native VF driver (such as iavf, ixgbevf, or mlx5_core).

Because the host kernel immediately claims and brings up these VFs as local network interfaces (e.g., eth1
or enp1s0f0v1), you must unbind them from the host driver before you can hand them over to a VM via VFIO.

### The Workflow for SR-IOV VFs and Driver Binding


To prepare an SR-IOV VF for a VM using VFIO, the process follows these exact steps:

1. Enable the VFs on the Physical Function (PF):
```bash 
echo 4 > /sys/class/net/eth0/device/sriov_numvfs
```
At this point, the kernel automatically probes and binds the new VFs to the host driver.
PF is still managed by the `mlx5_core`. And Each VF also initally bound to `mlx5_core`.

[ Note: what happens before assigning VF?
  - Initially, `mlx5_core-> PF -> VF0,VF1,...` Before giving VF0 to VM1, it cannot remain actively used by
    the host. 

    - Method 1: Let `libvirt` manage it ( recommended )
      If using libvirt ( virsh, virt-manager...) you generally do not manually unbind VF.
      When VM starts libvirt: 
      * detaches the VF from `mlx5_core`.
      * Binds to `vfio-pci`
      * starts QEMU 
      * Passes the VF into the VM.
      When VM stops, libvirt reverses the process. 

    - Method 2: Manual binding: 
    When launching QEMU manually, its required to perform steps similar to full-device passthrough, but only
    for the VF. 
    * Find the VF using `lspci` example: `18:00.2 Ethernet controller: Mellanox VF` 
    * Check the driver is bind to `lspci -k -s 18:00.2` ex: we can see `Kernel driver in use: mlx5_core` 
    * Unbind it `echo 0000:18:00.2 > /sys/bus/pci/drivers/mlx5_core/unbind` 
    * Override the driver `echo vfio-pci > /sys/bus/pci/devices/0000:18:00.2/driver_override` 
    * Bind it : `echo 0000:18:00.2 >  /sys/bus/pci/drivers/vfio-pci/bind`
    * Now use with QEMU `-device vfio-pci,host=18:00.2`

    Same concept applies for RDMA devices.
]

2. Locate the PCI Address of the VF:
   You can find the specific PCIe address (e.g., 0000:02:10.1) using lspci or by checking the VF symlinks in
   `/sys/class/net/eth0/device/`.

3. Unbind the VF from the Host Driver:
   You must explicitly detach the VF from the host's network driver:
```bash 
echo "0000:02:10.1" > /sys/bus/pci/drivers/iavf/unbind
```
(Note: Replace iavf with whatever host driver your specific NIC uses for its VFs).

4. Bind the VF to the VFIO Driver:
   Once unbound from the host, you bind it to vfio-pci so the hypervisor (like QEMU/KVM) can safely pass it
   through to the guest VM:
```bash
echo "vfio-pci" > /sys/bus/pci/devices/0000\:02\:10\:1/driver_override
echo "0000:02:10.1" > /sys/bus/pci/drivers/vfio-pci/bind
```
( Alternatively, modern virtualization management tools like libvirt / virsh nodedev-detach automate these
  unbind and bind-to-vfio-pci steps for you behind the scenes when you start the VM.)


