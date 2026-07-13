# vDPA ( benchmarking )

**vDPA** stands for **v**irtual **D**ata **P**ath **A**cceleration. 

It is a framework in the Linux kernel designed to bridge the gap between two worlds: 
    - the high performance of HW accel (like SR-IOV) and the flexibility/live-migration capabilities of 
      standardized software virtualization (like `virtio`).


To understand why vDPA is a big deal, it helps to look at the problem it solves.

---

## The Problem: Performance vs. Flexibility

When running virtual machines (VMs) or containers that require massive network or storage I/O, developers 
usually have to choose between two approaches:

1. **SW Emulation (`virtio`):** The VM uses standard, standardized `virtio` drivers. It’s highly flexible,
   allows for live migration (moving a running VM to another server), and works on any hardware. However, it
   introduces CPU overhead because the host software has to process the data path.

2. **HW Passthrough (SR-IOV):** You bypass the host OS and give the VM direct access to a physical network
   card (NIC) or storage device. It delivers near-native hardware speed (wire-speed), but you lose
   standardization and virtualization features like live migration because the VM is tightly coupled to
   specific hardware.

---

## The Solution: How vDPA Works

vDPA splits the control plane and the data plane to give you the best of both worlds: **the standardization
of `virtio` with the raw speed of hardware.**

* **Standardized Data Plane (`virtio`):** The data path (how data actually moves between the guest and the
  device) complies exactly with the open `virtio` specification. The hardware vendor designs their physical
  chip to natively understand `virtio` rings/queues.

* **Vendor-Specific Control Plane:** The control path (how the device is configured, ring sizes, features
  negotiation) uses a vendor-specific driver in the Linux kernel.

### The Architecture in Action

1. The **Guest VM** thinks it is talking to a standard, generic `virtio` device. It loads the standard
   `virtio-net` or `virtio-blk` driver.
2. Because the physical hardware (the NIC or crypto-accelerator) natively understands the `virtio` data
   structure, data is DMAed (Direct Memory Accessed) **directly between the VM and the physical hardware**,
   completely bypassing the host kernel's CPU for data transmission.
3. The **vDPA framework** in the Linux kernel manages the translation between the generic `virtio` control
   commands from the hypervisor (like QEMU) and the hardware-specific driver provided by vendors (like
   NVIDIA/Mellanox, Intel, or AMD/Xilinx).

---

## Key Benefits of vDPA

* **Wire-Speed Performance:** Since the data path completely bypasses the host software, you get latency and
  throughput that rivals SR-IOV.

* **Live Migration:** Because the VM only sees a standard `virtio` interface, the hypervisor can easily
  pause the VM, serialize its state, copy it to another host, and resume it—even if the destination host
  uses a completely different vDPA hardware vendor.

* **Unified Driver Interface:** You don't need custom, vendor-specific drivers inside your guest VMs or
  containers. A single `virtio` driver works everywhere.

* **Container Integration:** vDPA works seamlessly with Kubernetes and SmartNICs/DPUs, making it a
  cornerstone for modern cloud-native networking (like DPDK and SR-IOV CNI alternatives).

In short, vDPA allows hardware vendors to build fast chips while allowing cloud providers to maintain the
flexible software tricks that make virtualization great.

-----
1. **Pure VirtIO (kernel networking)**
2. **OVS-DPDK + vhost-user (userspace datapath)**

then **vDPA** is actually the missing piece in the virtio acceleration landscape. 

Once you understand where it fits, benchmarking it becomes fairly straightforward.

---

## First, what problem does vDPA solve?

Think of the networking stack as several layers.

### Pure VirtIO

```
        Guest
          │
    virtio-net driver
          │
      virtqueue
          │    
    vhost-net (kernel)
          │
    Linux networking stack
          │
    mlx5 kernel driver
          │
         NIC
```

Advantages

* very easy
* fully upstream
* good compatibility

Disadvantages

* every packet travels through the host networking stack
* CPU copies
* skb allocation
* softirq processing
* kernel scheduling

Small packet forwarding suffers because the CPU does lots of work.

---

### OVS-DPDK

```
     Guest
       │
    virtio-net
       │
    vhost-user
       │
    OVS-DPDK
       │
    DPDK mlx5 PMD(poll Mode driver)
       │
      NIC
```

Advantages

* almost everything stays in userspace
* no Linux networking stack
* extremely high throughput
* excellent Mpps

Disadvantages

* dedicated PMD polling cores
* high idle CPU usage
* requires DPDK everywhere
* more complicated deployment

---

Now imagine:

> "What if the NIC itself executed the virtio queues?"

That's exactly what **vDPA** is.

---

## What is vDPA?

vDPA stands for

**virtio Data Path Acceleration**

The guest still believes it has an ordinary virtio NIC.

Nothing changes inside the VM.

```
    Guest
    
    virtio-net
    
    virtqueues
    
        ↓
 Hardware executes descriptors
```

Instead of software walking the virtqueues, the NIC hardware does it. 

The vDPA framework defines a virtio-compliant datapath with a vendor-specific control path.
([vDPA - virtio Data Path Acceleration][1])
[1]: https://vdpa-dev.gitlab.io/?utm_source=chatgpt.com "vDPA - virtio Data Path Acceleration - vDPA - virtio Data Path Acceleration"

---

### The important idea

The guest sees

```
virtio-net
```

NOT

```
SR-IOV VF
```

NOT

```
PCI passthrough
```

NOT

```
VFIO
```

The guest driver remains exactly the same.

This is why cloud providers like vDPA.

---

### Where does packet processing happen?

Instead of

```
    Guest

      ↓

  vhost-net

      ↓

    kernel

      ↓

     mlx5

      ↓   

      NIC
```

it becomes

```
    Guest

      ↓

  virtqueue

      ↓

ConnectX hardware

      ↓

     Wire
```

The NIC itself fetches descriptors from guest memory using DMA.

No software packet forwarding.

Very little CPU involvement.

---

## Hardware ownership

With vDPA, the NIC understands

* virtqueues
* descriptors
* completion queues
* DMA
* packet transmission

The host kernel mainly performs:

* VM setup
* queue configuration
* feature negotiation
* control operations

The actual packet movement is done by hardware.([vDPA - virtio Data Path Acceleration][1])
[1]: https://vdpa-dev.gitlab.io/?utm_source=chatgpt.com "vDPA - virtio Data Path Acceleration - vDPA - virtio Data Path Acceleration"

---

### Compare the three architectures

### Pure VirtIO

```
    Guest

      ↓

  vhost-net

      ↓

Linux networking

      ↓

    mlx5

      ↓

     NIC
```

CPU heavy

---

### OVS-DPDK

```
    Guest

      ↓

  vhost-user

      ↓

     DPDK

      ↓

  mlx5 PMD

      ↓

     NIC
```

Userspace polling

High CPU

Highest flexibility

---

### vDPA

```
    Guest

      ↓

  virtio queue

      ↓

ConnectX hardware

      ↓

     NIC
```

Hardware datapath

Lowest CPU

---

## Why does vDPA exist?

Cloud operators wanted

* ordinary virtio guests
* no guest modifications
* no SR-IOV management headaches
* hardware acceleration

So they created

```
    virtio interface

    +

    hardware datapath
```

---

# Is it like SR-IOV?

People often confuse these.

### SR-IOV

Guest owns

```
Virtual Function
```

Guest loads

```
mlx5 VF driver
```

Guest knows it has a Mellanox NIC.

---

### vDPA

Guest owns

```
virtio-net
```

Guest has no idea there is a Mellanox card underneath.

This is the biggest conceptual difference.

---

## Your benchmark topology

Today your VirtIO benchmark is

```
    VM

    ↓

    tap

    ↓

    Host kernel

    ↓

    CX5 port0

===== DAC =====

CX5 port1
```

Your DPDK benchmark is

```
    VM

    ↓

    vhost-user

    ↓

    OVS-DPDK

    ↓

    mlx5 PMD

    ↓

    CX5
```

The vDPA benchmark becomes

```
    VM

    ↓

    virtio-net

    ↓

    vhost-vdpa

    ↓

    mlx5_vdpa

    ↓

    ConnectX

===== DAC =====

Other port
```

Notice

There is

* no TAP
* no Linux bridge
* no OVS datapath

The NIC handles the virtqueue datapath.

---

## What performance should you expect?

Generally:

#### Throughput

Very close to line rate.

Usually similar to DPDK.

---

#### Small packets (Mpps)

Much higher than pure VirtIO.

Often close to DPDK.

---

#### Latency

Lower than VirtIO.

Sometimes within a few microseconds of DPDK.

---

#### Host CPU

This is where vDPA shines.

Expected ordering:

```
    Highest CPU

    OVS-DPDK

    ↓

    Pure VirtIO

    ↓

    Lowest CPU

    vDPA
```

Why?

DPDK continuously polls (busy-wait).

vDPA lets hardware process descriptors, so the host CPU is involved mainly for control rather than every
packet.

---

## Does ConnectX-5 support vDPA?

This is the one thing you should verify before investing time.

Upstream Linux currently documents the `mlx5_vdpa` network driver as targeting **ConnectX-6 and newer**
hardware. The vDPA project overview lists a Mellanox vDPA driver, but the kernel help text for
`CONFIG_MLX5_VDPA_NET` specifies ConnectX-6+ support.([vDPA - virtio Data Path Acceleration][1])

So, with a **ConnectX-5**, your first step should be to determine whether your specific NIC/firmware exposes
vDPA support (for example, via a vendor-specific implementation) or whether you'll need newer hardware such
as ConnectX-6 Dx. Don't assume that a recent Fedora kernel alone enables hardware vDPA on ConnectX-5.

---

# If your hardware supports it, the benchmark matrix is excellent

| Test                 | Pure VirtIO | OVS-DPDK | vDPA |
| -------------------- | ----------- | -------- | ---- |
| 64B Mpps             | ✓           | ✓        | ✓    |
| 128B Mpps            | ✓           | ✓        | ✓    |
| 256B Mpps            | ✓           | ✓        | ✓    |
| TCP throughput       | ✓           | ✓        | ✓    |
| UDP throughput       | ✓           | ✓        | ✓    |
| Average latency      | ✓           | ✓        | ✓    |
| 99.9% latency        | ✓           | ✓        | ✓    |
| Host CPU usage       | ✓           | ✓        | ✓    |
| Guest CPU usage      | ✓           | ✓        | ✓    |
| Interrupt rate       | ✓           | ✓        | ✓    |
| Line-rate efficiency | ✓           | ✓        | ✓    |

That comparison would clearly show the trade-offs between a kernel datapath (VirtIO), a userspace datapath
(OVS-DPDK), and a hardware-offloaded datapath (vDPA).

If your goal is to produce a publishable benchmark report, I can also help you design a **scientifically
fair benchmarking methodology** so that the three setups differ only in the datapath implementation, making
the results directly comparable.

[1]: https://vdpa-dev.gitlab.io/?utm_source=chatgpt.com "vDPA - virtio Data Path Acceleration - vDPA - virtio Data Path Acceleration"
