# Technical Report: High-Performance Packet Processing & Kernel Bypass Architectures

## 1. Intro
As network line rates scale from 10GbE to 100GbE, 400GbE, and beyond, the traditional Linux network stack
faces severe performance walls. Standard interrupt-driven packet handling, heavy kernel-to-user-space
context switching, and structural memory copies (`sk_buff`) consume massive CPU resources, leading to packet
drops, high latency, and reduced throughput. 

To solve this, **kernel bypass** and **zero-copy architectures** have become industry standards. 

This report outlines the core problem, existing solutions that abstract away low-level complexity, and lays
the groundwork for a future comparative analysis between **AF_XDP**, **DPDK**, and **vDPA**.

The main trade-off: User-space takes over responsibilities normally handled by the kernel such as :

- Protocol Handling: parsing transport and network layer manually as there is no standard BSD socket like
  `recv()` on TCP/UDP. 

- Manual Parsing: User applications receives raw frames ( with Ethernet headers ) and it is requires to
  write or use libraries (DPDK pkt parsers, libpcap-style healpers, or custom structs ) to unpack
  IP,TCP,UDP or other custom protocols.

- State management: while handling connection oriented traffic (like TCP), since we lose the kernel
  built-in connection tracking, sequence number management and reassembly queues, You have to implement
  your own user-space stack ( like F-Stack or Seastar ).

- Concurrency and Scaling: To keep up with millions of pkts/sec user-application requires to use
  multi-threaded architecture aligned with HW queues, typically using **Receive Side Scaling (RSS)** and
  pinning threads to specific CPU core to avoid cache misses and loack contention. 

- With `AF_XDP` developers often pair with high-performance frameworks or libraries rather then writing
  everthing from raw C sockets. 

---

## 2. The Core Problem: The Linux Network Stack Bottleneck
In a standard Linux deployment, incoming network packets trigger a multi-stage gauntlet before reaching an
application:

1. **Interrupt Storms:** The NIC signals the CPU via hardware interrupts for every packet (mitigated
   partially by NAPI polling, but still costly under heavy load).

2. **Kernel Overhead:** The kernel allocates and manages `sk_buff` structures, traverses netfilter/iptables
   firewall hooks, routes lookups, and manages socket buffers.

3. **Context Switching:** Moving data from kernel space to user space via system calls (`recv()`, `read()`)
   requires expensive CPU context switches.

4. **Memory Copying:** CPU cycles are wasted copying packet payloads from driver memory to application
   memory.

**The Result:** 

    Under heavy traffic (Mpps), the CPU spends 100% of its time processing overhead 
    rather than actual business logic. This forces developers to bypass this stack directly into 
    raw ring buffers (ex: raw AF_XDP) this leads to immense engineering complexity, such as manual 
    mem mgmt, ring synchronization, and custom protocol parsing—onto user-space applications, 
    often locking teams into fragile C-based toolchains.

### 2.1 Steps Required for a User-Space Application (`AF_XDP`)

Building a raw `AF_XDP` consumer from scratch in C or Rust requires managing low-level memory and ring
buffers manually. 
Below are the core steps:

* **UMEM (User Memory) Allocation:** Allocate a contiguous block of memory and divide it into fixed-size
  chunks (e.g., 2KB or 4KB) to store packet data.
* **Socket Creation & Binding:** Create the socket using `socket(AF_XDP, ...)` and bind it to a specific
  network interface and hardware queue index.
* **Ring Buffer Setup:** Configure and map four rings via `setsockopt`:
    * **Fill Ring:** Supplies empty UMEM chunks to the kernel for receiving packets.
    * **RX Ring:** Notifies user space when new packets arrive in filled chunks.
    * **TX Ring:** Queues packets from user space to be transmitted out.
    * **Completion Ring:** Notifies user space when transmitted packets have cleared.
  
* **Polling & Event Loop:** Use `poll()` or `epoll()` on the `AF_XDP` socket file descriptor, or implement
  busy-polling (`XDP_USE_NEED_WAKEUP` flag) to check for incoming packets efficiently.

* **Descriptor Management:** Read descriptors from the RX ring, extract packet pointers from UMEM, process
  the data, and replenish the Fill Ring.

####  example: psudo code:

```C
    // Interface:
    //   Name:    enp1s0f0np0
    //   ifindex: 3
    //
    // Hardware queue:
    //   queue_id: 5
    //
    // Note: AF_XDP's sxdp_queue_id corresponds to the NIC's
    // RX/TX queue index. Typically queue 0, 1, 2, ....

    #define IFINDEX       3
    #define QUEUE_ID      5

    #define FRAME_SIZE    2048
    #define NUM_FRAMES    4096
    #define UMEM_SIZE     (FRAME_SIZE * NUM_FRAMES)

    // ------------------------------------------------------------
    // 1. Allocate UMEM memory
    // ------------------------------------------------------------

    void *umem_area = mmap(
        NULL,
        UMEM_SIZE,
        PROT_READ | PROT_WRITE,
        MAP_PRIVATE | MAP_ANONYMOUS | MAP_HUGETLB,
        -1,
        0
    );

    if (umem_area == MAP_FAILED) {
        perror("mmap UMEM");
        return -1;
    }

    // ------------------------------------------------------------
    // 2. Create AF_XDP socket
    // ------------------------------------------------------------

    int xsk_fd = socket(AF_XDP, SOCK_RAW, 0);

    if (xsk_fd < 0) {
        perror("socket(AF_XDP)");
        return -1;
    }

    // ------------------------------------------------------------
    // 3. Register UMEM with the AF_XDP socket
    // ------------------------------------------------------------

    struct xdp_umem_reg umem = {
        .addr       = (uint64_t)umem_area,
        .len        = UMEM_SIZE,
        .chunk_size = FRAME_SIZE,
        .headroom   = 0,
        .flags      = 0,
    };

    if (setsockopt(
            xsk_fd,
            SOL_XDP,
            XDP_UMEM_REG,
            &umem,
            sizeof(umem)) < 0) {

        perror("XDP_UMEM_REG");
        close(xsk_fd);
        return -1;
    }

    // ------------------------------------------------------------
    // 4. Configure UMEM fill/completion rings
    // ------------------------------------------------------------

    uint32_t fill_ring_size = 2048;
    uint32_t comp_ring_size = 2048;

    if (setsockopt(
            xsk_fd,
            SOL_XDP,
            XDP_UMEM_FILL_RING,
            &fill_ring_size,
            sizeof(fill_ring_size)) < 0) {

        perror("XDP_UMEM_FILL_RING");
        return -1;
    }

    if (setsockopt(
            xsk_fd,
            SOL_XDP,
            XDP_UMEM_COMPLETION_RING,
            &comp_ring_size,
            sizeof(comp_ring_size)) < 0) {

        perror("XDP_UMEM_COMPLETION_RING");
        return -1;
    }

    // ------------------------------------------------------------
    // 5. Configure RX/TX rings
    // ------------------------------------------------------------

    uint32_t rx_ring_size = 2048;
    uint32_t tx_ring_size = 2048;

    if (setsockopt(
            xsk_fd,
            SOL_XDP,
            XDP_RX_RING,
            &rx_ring_size,
            sizeof(rx_ring_size)) < 0) {

        perror("XDP_RX_RING");
        return -1;
    }

    if (setsockopt(
            xsk_fd,
            SOL_XDP,
            XDP_TX_RING,
            &tx_ring_size,
            sizeof(tx_ring_size)) < 0) {

        perror("XDP_TX_RING");
        return -1;
    }

    // ------------------------------------------------------------
    // 6. Get mmap offsets
    // ------------------------------------------------------------

    struct xdp_mmap_offsets offsets;
    socklen_t optlen = sizeof(offsets);

    if (getsockopt(
            xsk_fd,
            SOL_XDP,
            XDP_MMAP_OFFSETS,
            &offsets,
            &optlen) < 0) {

        perror("XDP_MMAP_OFFSETS");
        return -1;
    }

    // ------------------------------------------------------------
    // 7. mmap() the fill/completion/RX/TX rings
    //
    //    Actual mmap implementation omitted here.
    // ------------------------------------------------------------

    mmap_fill_ring(...);
    mmap_completion_ring(...);
    mmap_rx_ring(...);
    mmap_tx_ring(...);

    // ------------------------------------------------------------
    // 8. Bind AF_XDP socket to interface + hardware queue
    // ------------------------------------------------------------
    //
    // This is the important part:
    //
    //     ifindex   = 3
    //     queue_id  = 5
    //
    // Therefore packets received on RX queue 5 can be delivered
    // to this AF_XDP socket when the XDP program redirects them
    // to this socket.
    //
    // ------------------------------------------------------------

    struct sockaddr_xdp sxdp = {
        .sxdp_family   = AF_XDP,
        .sxdp_ifindex  = IFINDEX,     // enp1s0f0np0 = ifindex 3
        .sxdp_queue_id = QUEUE_ID,    // hardware queue 5
        .sxdp_flags    = 0,
        .sxdp_shared_umem_fd = 0,
    };

    if (bind(
            xsk_fd,
            (struct sockaddr *)&sxdp,
            sizeof(sxdp)) < 0) {

        perror("bind(AF_XDP)");
        close(xsk_fd);
        return -1;
    }

    // ------------------------------------------------------------
    // 9. Populate the fill ring with UMEM frame addresses
    // ------------------------------------------------------------

    for (int i = 0; i < NUM_FRAMES; i++) {

        uint64_t addr = i * FRAME_SIZE;

        // Put 'addr' into the AF_XDP fill ring
        fill_ring_push(addr);
    }

    // ------------------------------------------------------------
    // 10. Socket is now associated with:
    //
    //       Interface : enp1s0f0np0
    //       ifindex   : 3
    //       RX/TX Q   : 5
    //
    // ------------------------------------------------------------

    printf(
        "AF_XDP socket bound: ifindex=%d, queue=%d\n",
        IFINDEX,
        QUEUE_ID
    );

```

The critical binding is:

```
    struct sockaddr_xdp sxdp = {
        .sxdp_family   = AF_XDP,
        .sxdp_ifindex  = 3,   // enp1s0f0np0
        .sxdp_queue_id = 5,   // hardware queue 5
        .sxdp_flags    = 0,
    };

    bind(xsk_fd, (struct sockaddr *)&sxdp, sizeof(sxdp));
```

If you want zero-copy mode, use: `sxdp.sxdp_flags = XDP_ZEROCOPY;` 

or, if you want the kernel to choose zero-copy/copy mode: `sxdp.sxdp_flags = 0;`

For a real AF_XDP program, the ordering is generally:

```C 
socket(AF_XDP)
      │
      ├── XDP_UMEM_REG
      ├── XDP_UMEM_FILL_RING
      ├── XDP_UMEM_COMPLETION_RING
      ├── XDP_RX_RING
      ├── XDP_TX_RING
      │
      ├── mmap() rings
      │
      └── bind(AF_XDP,
               ifindex=3,
               queue_id=N)
```

One important distinction: **binding the socket to queue 5 doesn't by itself cause packets to arrive
there**. Your XDP program normally needs an `XSKMAP`, with the socket inserted at the appropriate map
index, and then `bpf_redirect_map()` to redirect packets to the AF\_XDP socket.

For example, conceptually:

```
NIC enp1s0f0np0
     │
     ├── RX queue 0 ──> AF_XDP socket 0
     ├── RX queue 1 ──> AF_XDP socket 1
     ├── ...
     └── RX queue 5 ──> AF_XDP socket 5
                              │
                              ▼
                         XSKMAP[5]
                              │
                              ▼
                         userspace
```

If you're setting up **multiple hardware queues**, you would typically create one AF_XDP socket/UMEM setup
per queue (or use shared UMEM), with__`sxdp_queue_id`__set to__`0`__,__`1`__,__`2`__, etc._ 

---

### 2.2 Libraries to Simplify the Programmer’s Job

Writing raw memory management and ring-buffer logic is error-prone. Several libraries abstract away the
boilerplate:

* **`libxdp` (and `libbpf`):** The standard, modern helper libraries maintained by the kernel community.
  They simplify loading XDP programs, setting up UMEM, managing rings, and handling multi-threading safely.

* **DPDK (Data Plane Development Kit) with AF_XDP PMD:** If you already use or prefer the DPDK ecosystem,
  DPDK provides an `AF_XDP` Poll Mode Driver. This lets you use DPDK's high-level APIs, ring buffers, and
  memory pools while backing them with `AF_XDP` sockets.

* **User-Space TCP/IP Stacks (e.g., F-Stack, Seastar):** If your application needs to handle stateful
  protocols (like TCP or HTTP) instead of raw packets, these frameworks provide complete user-space
  networking stacks that integrate with `AF_XDP` or DPDK.

#### Example 

**libxdp + libbpf is the preferred approach** for most AF\_XDP applications because they hide much of the
ring/mmap/UMEM plumbing.

The biggest simplification is to use **libxdp's** `xsk_socket__create()`. 
You still specify the interface index and hardware queue explicitly.


```C
    #include <bpf/xsk.h>
    #include <xdp/xsk.h>

    #define IFINDEX     3
    #define QUEUE_ID    5

    #define FRAME_SIZE  2048
    #define NUM_FRAMES  4096

    int main(void)
    {
        struct xsk_socket *xsk = NULL;
        struct xsk_umem *umem = NULL;

        struct xsk_umem_config umem_cfg = {
            .fill_size       = 2048,
            .comp_size       = 2048,
            .frame_size      = FRAME_SIZE,
            .frame_headroom  = 0,
            .flags           = 0,
        };

        struct xsk_socket_config xsk_cfg = {
            .rx_size       = 2048,
            .tx_size       = 2048,
            .libbpf_flags  = 0,
            .xdp_flags     = 0,
            .bind_flags    = XDP_USE_NEED_WAKEUP,
        };

        /*
         * 1. Allocate UMEM memory
         */
        void *umem_area = allocate_umem(NUM_FRAMES * FRAME_SIZE);

        /*
         * 2. Create UMEM
         *
         * libbpf/libxdp handles the UMEM ring setup and mmap details.
         */
        int ret = xsk_umem__create(
            &umem,
            umem_area,
            NUM_FRAMES * FRAME_SIZE,
            &fill_ring,
            &comp_ring,
            &umem_cfg
        );

        if (ret) {
            fprintf(stderr, "xsk_umem__create failed: %d\n", ret);
            return 1;
        }

        /*
         * 3. Create AF_XDP socket
         *
         * IFINDEX  = 3
         * QUEUE_ID = 5
         */
        ret = xsk_socket__create(
            &xsk,
            "enp1s0f0np0",       // interface
            QUEUE_ID,            // hardware queue
            umem,
            &rx_ring,
            &tx_ring,
            &xsk_cfg
        );

        if (ret) {
            fprintf(stderr,
                    "xsk_socket__create failed: %d\n",
                    ret);
            return 1;
        }

        printf(
            "AF_XDP socket created:\n"
            "  interface = enp1s0f0np0\n"
            "  ifindex   = %d\n"
            "  queue     = %d\n",
            IFINDEX,
            QUEUE_ID
        );

        /*
         * 4. Get socket FD if needed
         */
        int fd = xsk_socket__fd(xsk);

        /*
         * 5. Populate the fill ring with UMEM frames
         */
        for (int i = 0; i < NUM_FRAMES; i++) {
            uint64_t addr = i * FRAME_SIZE;

            xsk_ring_prod__reserve(
                &fill_ring,
                1,
                &idx
            );

            *xsk_ring_prod__fill_addr(
                &fill_ring,
                idx
            ) = addr;

            xsk_ring_prod__submit(
                &fill_ring,
                1
            );
        }

        /*
         * 6. Receive/transmit packets
         *
         * Use xsk_ring_cons__peek()
         * and xsk_ring_prod__reserve()
         * to operate on RX/TX rings.
         */

        ...

        /*
         * 7. Cleanup
         */
        xsk_socket__delete(xsk);
        xsk_umem__delete(umem);

        return 0;
    }
```

Even simpler:

If you use **libxdp's higher-level XSK helpers**, the important part can essentially be reduced to:

```C
    struct xsk_socket *xsk;

    struct xsk_socket_config cfg = {
        .rx_size = 2048,
        .tx_size = 2048,
        .bind_flags = XDP_USE_NEED_WAKEUP,
    };

    xsk_socket__create(
        &xsk,
        "enp1s0f0np0",
        5,              // hardware queue
        umem,
        &rx,
        &tx,
        &cfg
    );
```

The `5` is the important part for your hardware queue:

```markdown
                    enp1s0f0np0
                         │
                     ifindex 3
                         │
                         ▼
                  ┌─────────────┐
                  │   NIC       │
                  │             │
                  │ RX queue 0  │
                  │ RX queue 1  │
                  │ RX queue 2  │
                  │ ...         │
                  │ RX queue 5  │◄──── AF_XDP socket
                  │ ...         │
                  └─────────────┘
```

One correction to the previous pseudocode:

With the library approach, you generally **don't need to manually do**:

```C
    socket(AF_XDP, ...)
    setsockopt(XDP_UMEM_REG, ...)
    setsockopt(XDP_RX_RING, ...)
    setsockopt(XDP_TX_RING, ...)
    getsockopt(XDP_MMAP_OFFSETS, ...)
    mmap(...)
    bind(...)
```

`xsk_umem__create()` and `xsk_socket__create()` handle most of this for you.

Also, `xsk_socket__create()` takes the **interface name** (`"enp1s0f0np0"`) and the **queue ID** (`5`); you
don't normally need to construct `struct sockaddr_xdp` yourself.

**One more important piece: XDP program**

If your goal is to actually receive packets through AF\_XDP, you'll also need an XDP program that redirects
packets to an **XSKMAP**:

```C
    SEC("xdp")
    int xdp_prog(struct xdp_md *ctx)
    {
        int queue = ctx->rx_queue_index;

        return bpf_redirect_map(
            &xsks_map,
            queue,
            XDP_PASS
        );
    }
```

with something like:

```C
    struct {
        __uint(type, BPF_MAP_TYPE_XSKMAP);
        __uint(max_entries, 64);
        __type(key, __u32);
        __type(value, __u32);
        } xsks_map SEC(".maps");
```

Then userspace puts your AF_XDP socket into:

```C
    xsks_map[5] = xsk_fd
```

so the complete path becomes:

```markdown
    NIC queue 5
         │
         ▼
     XDP program
         │
         │ bpf_redirect_map(xsks_map, 5, ...)
         ▼
     xsks_map[5]
         │
         ▼
     AF_XDP socket
         │
         ▼
     userspace RX ring
```

If you're building a **real application rather than learning the raw API**, 
Its recommend to use **libbpf for loading the XDP program + XSKMAP and libxdp/libbpf XSK APIs for 
the AF\_XDP sockets**. That reduces the setup substantially and avoids a lot of error-prone ring
management.

---

### 2.3 Ways to Automate and Streamline Frame Processing

To scale packet processing without writing a monolithic, custom engine, several automation and
architectural patterns are commonly used:

* **Graph-Based Pipeline Frameworks (e.g., FD.io VPP):** Vector Packet Processing (VPP) allows you to
  define a network processing graph (nodes for parsing, classification, routing, encryption) where
  packets are processed in vectors (batches) rather than one by one, maximizing CPU cache locality.

* **Vectorized Processing & SIMD:** Utilizing Single Instruction, Multiple Data (SIMD) instructions (like
  AVX-2 or AVX-512) to parse multiple packet headers simultaneously.

* **RSS (Receive Side Scaling) Automation:** Configuring NIC hardware queues so that traffic is
  automatically hashed and distributed across multiple CPU cores, allowing independent user-space
  threads to process packets in parallel without lock contention.

* **Control/Data Plane Separation:** Using control-plane agents (like Go or Python daemons) to
  dynamically update eBPF maps (like `BPF_MAP_TYPE_HASH` or `XSKMAP`) to automatically steer, drop, or
  redirect traffic streams based on live policy updates, leaving the high-speed data plane untouched.

---

## 3. Current Solutions & Ecosystem Approaches
To balance raw hardware performance with application usability, several patterns and abstraction layers have
emerged:

### A. User-Space TCP/IP Stacks (POSIX Compatibility Layers)
* **How they work:** Frameworks like **F-Stack** or user-space `lwIP` take high-speed packet feeds from
  drivers and implement complete protocol stacks in user space.

* **The Benefit:** They expose standard BSD Socket APIs (`socket()`, `bind()`, `epoll()`), allowing legacy
  applications (like Nginx, Redis, or custom servers) to benefit from kernel bypass with zero or minimal
  code rewrites.

### B. High-Speed Processing Frameworks & Pipelines

* **FD.io VPP (Vector Packet Processing):** A modular, extensible framework that processes packets in
  vectors (batches) rather than single items, optimizing CPU cache locality. It integrates directly with
  high-performance drivers and can route traffic to normal applications via TAP/TUN or vhost-user.

### C. Standardized Language Bindings and Libraries

* **Ecosystem Wrappers (`libxdp`, `libbpf`, `xsk-rs`):** While low-level bindings often tie developers to C
  reference implementations, higher-level wrappers attempt to tame memory safety risks and abstract away
  ring-buffer complexity behind idiomatic APIs (e.g., Rust abstractions).

---

## 4. Setting the Stage: Comparative Framework (AF_XDP vs. DPDK vs. vDPA) To determine the best arch

For a given use case, future analysis will pit the three primary paradigms against each other:

1. **AF_XDP (Address Family eXpress Data Path):**

   * *The Kernel-Integrated Approach:* Built directly into the Linux kernel using eBPF and XDP hooks. It
     allows safe co-existence with the standard kernel stack, standard netdev configuration tools, and
     granular security policies, while achieving zero-copy performance via UMEM.

2. **DPDK (Data Plane Development Kit):**

   * *The Full-Bypass Approach:* Replaces standard NIC drivers entirely with its own Poll Mode Drivers
     (PMDs), taking 100% control of the device and completely cutting out the Linux kernel. Offers unmatched
     raw performance and an extensive ecosystem of packet-processing libraries, but at the cost of high
     operational complexity and isolated hardware control.

3. **vDPA (virtio Data Path Acceleration):**

   * *The Hardware-Assisted Virtualization Approach:* Blends standards-based virtio interfaces with hardware
     offload. It provides standardized virtual device paths (ideal for cloud environments and container/VM
     boundaries) while offloading data-path heavy lifting to smart NICs or FPGA accelerators.

---

## 5. Next Steps for Further Analysis

This report serves as the baseline foundation. In the follow-up evaluation, we will dive deeper into:
* **Performance Metrics:** Latency, throughput (Mpps), and CPU utilization benchmarks.
* **Operational Complexity:** Ease of deployment, container/cloud-native compatibility, and maintenance overhead.
* **Security & Isolation:** How each method handles privilege boundaries, multi-tenancy, and kernel safety.

