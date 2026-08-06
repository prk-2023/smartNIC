```
                 Physical Network (DAC crossover)
                        |
               +----------------+
               |                |
             PF0              PF1
      enp1s0f0np0        enp1s0f1np1
               |                |
      +----------------+  +----------------+
      |   OVS br-left  |  |  OVS br-right  |
      +----------------+  +----------------+
               |                |
          tap-left         tap-right
               |                |
        virtio-net NIC    virtio-net NIC
          (ens-test)        (ens-test)
               |                |
             VM1              VM2
               |                |
        virtio-net NIC    virtio-net NIC
          (ens-mgmt)        (ens-mgmt)
               |                |
          QEMU SLIRP        QEMU SLIRP
       (SSH :2201)        (SSH :2202)
```


Data flow:
```text 
   VM1
 ens-test
    │
    ▼
tap-left
    │
    ▼
OVS br-left
    │
    ▼
   PF0
    │
==== DAC ====
    │
    ▼
   PF1
    │
    ▼
OVS br-right
    │
    ▼
tap-right
    │
    ▼
   VM2
```

Outcome: No internal PF switch or bridge:
```
            ConnectX NIC

      +-----------------------+
      |                       |
      |      No internal      |
      |   PF0 <-> PF1 switch  |
      |      or bridge        |
      |                       |
      +-----------------------+

      PF0                 PF1
       │                   │
       ▼                   ▼
   OVS br-left        OVS br-right
```


----- OVS -----------------

./t2_perf_status.sh ( check config/setting )
./t2_perf_apply.sh  
./t2_host_reset-ovs.sh 
./t2_host_setup-ovs.sh

t2_config.sh ( global config file )
./t2_build_guest_image.sh 1   <-- Build VM1 image
./t2_build_guest_image.sh 2   <-- Build VM2 image

./t2_launch_vm.sh 1 <- launch VM1
./t2_launch_vm.sh 2 <- launch VM1

ssh into vm1 and vm2 and ping ( FAIL )
debug: tcpdump enp1s0f0np0, and enp1s0f1np1 to monitor where the traffic is blocked. 

./t2_run_test.sh ( Can not test check report.md )


--- ovs ( no CX7 ) ------------

Pure SW VM1 <=> VM2   ( using ovs to connect VM's )

modify the above OVS setup and add both tap0 and tap1 to PVS br-left:

sudo ovs-vsctl show
sudo ovs-vsctl del-port br-right enp1s0f1np1
sudo ovs-vsctl del-port br-right vnet1
sudo ovs-vsctl del-br br-right
sudo ovs-vsctl add-port br-left vnet1
sudo ovs-vsctl show

./t2_run_test ovs-sw => result/ovs-sw/summart.json


------------ovs-dpdk--------------------

# t2 OVS-DPDK Phase — Setup & Changes

## What changed from the plain-OVS phase

| | Plain OVS (previous) | OVS-DPDK (this phase) |
|---|---|---|
| Bridge datapath | `datapath_type=system` (kernel) | `datapath_type=netdev` (DPDK, userspace) |
| PF0/PF1 attachment | Kernel netdev added as a normal OVS port | Added by **PCI BDF** (`dpdk-devargs`), `mlx5_core` stays bound the whole time — no `vfio-pci` unbind |
| VM test NIC | `tap` + `vhost=on` (kernel vhost-net) | `vhost-user` — OVS connects out to a socket QEMU listens on (`dpdkvhostuserclient`) |
| VM mgmt NIC | QEMU SLIRP | Unchanged — QEMU SLIRP |
| Packet polling | Interrupt-driven (kernel) | OVS-DPDK PMD threads, busy-polling on dedicated cores |

`t2_build_guest_image.sh` and `t2_run_test.sh` are **unchanged** — the guest OS sees a normal `virtio-net-pci` device either way; it has no visibility into whether the host backend is a kernel tap or a DPDK vhost-user socket.

## Why PF0/PF1 aren't unbound to `vfio-pci`

Most DPDK NICs require unbinding from their kernel driver to `vfio-pci`/`uio`. ConnectX is different:
DPDK's mlx5 PMD works *alongside* the kernel driver via the existing `libibverbs`/`rdma-core` stack,
claiming the device by PCI address while `mlx5_core` stays loaded. This is by design, confirmed in DPDK's
own mlx5 documentation — not a workaround.

## Before running `t2_host_setup.sh`

Two placeholders in `t2_config.sh` must be filled in first, or the setup script refuses to run:

- **`DPDK_LCORE_MASK`** — the single DPDK control-thread core (hex mask, e.g. `"0x1"`).
- **`PMD_CPU_MASK`** — the core(s) dedicated to packet-polling PMD threads (hex mask, e.g. `"0x6"` for
  cores 1+2).

Both must come from checking `lscpu -e` (same heterogeneous-core caution as `VCPU_PIN` in
`t2_launch_vm.sh`) and must not overlap with each other or with any VM's vCPU pins — PMD threads
busy-poll at 100% CPU, so a collision isn't a performance hit, it's a functional problem (two things
fighting for the same physical core).

## Run order

```bash
./t2_host_reset.sh          # clean slate if coming from the plain-OVS phase
# edit t2_config.sh: fill in DPDK_LCORE_MASK and PMD_CPU_MASK
./t2_perf_apply.sh          # ensures enough hugepages for OVS-DPDK's own reservation + both VMs
./t2_host_setup.sh          # enables DPDK datapath, recreates bridges, adds dpdk/vhost-user ports
./t2_launch_vm.sh 1
./t2_launch_vm.sh 2
./t2_run_test.sh run1
```

## Sanity checks built into `t2_host_setup.sh`

- Refuses to proceed if the CPU-mask placeholders are empty.
- Confirms `dpdk_initialized=true` after restarting `openvswitch-switch`, rather than assuming success.
- Greps the OVS log for the mlx5 "cannot load glue library" error specifically, since that's the exact
  failure mode if `libibverbs`/`libmlx5` aren't available at runtime — this DGX should already have
  them from normal ConnectX-7 operation, but the script checks rather than assumes.
- Reports `link_state`/`admin_state` for both `dpdk-p0`/`dpdk-p1` after adding them.

## Known open item

Hugepage sizing assumes a single NUMA node (`DPDK_SOCKET_MEM_MB` is one value, not per-node). Worth
confirming with `numactl -H` before relying on this if the DGX turns out to expose more than one node —
the config only budgets memory for one.
