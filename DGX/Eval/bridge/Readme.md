# Linux Bridge DAC Crossover Test

## Overview

This script creates a small, isolated Layer-2 networking topology using **Linux kernel bridges**, network namespaces, and veth pairs.

The purpose of the test is to verify connectivity across a **physical DAC (Direct Attach Copper) crossover/link** between two physical NICs.

The test intentionally places the two IP endpoints in **separate network namespaces** and connects each namespace to a different Linux bridge. The only physical path between the two sides is the DAC connecting the two physical NICs.

Therefore, a successful ping demonstrates that traffic can traverse:

* the left network namespace;
* the left veth pair;
* the left Linux bridge;
* the left physical NIC;
* the DAC;
* the right physical NIC;
* the right Linux bridge;
* the right veth pair;
* the right network namespace.

---

## Topology

```text
# ============================================================
# LINUX BRIDGE DAC CROSSOVER TEST
#
#                         DAC crossover
#                  +-----------------------+
#                  |                       |
#            enp1s0f0np0               enp1s0f1np1
#                  |                       |
#             +----+----+             +----+----+
#             | br-left |             |br-right |
#             |  Linux  |             |  Linux  |
#             |  bridge |             |  bridge |
#             +----+----+             +----+----+
#                  |                       |
#             left-veth-br            right-veth-br
#                  |                       |
#             left-veth               right-veth
#                  |                       |
#             +----+-----+           +-----+----+
#             |  left-ns |           | right-ns |
#             |          |           |          |
#             |10.0.0.1  |           |10.0.0.2  |
#             +----------+           +----------+
#
# The ping endpoints are in separate network namespaces.
# Therefore traffic MUST traverse the physical DAC.
#
# ============================================================
```

The logical packet path is:

```text
10.0.0.1
   |
   v
left-ns
   |
left-veth
   |
left-veth-br
   |
br-left
   |
enp1s0f0np0
   |
   |========== PHYSICAL DAC ==========|
   |
enp1s0f1np1
   |
br-right
   |
right-veth-br
   |
right-veth
   |
right-ns
   |
   v
10.0.0.2
```

---

## What Is Being Tested?

The primary test is **Layer-2 connectivity across the physical DAC**.

The two physical NICs are configured as ports of separate Linux bridges:

```text
br-left  <-> enp1s0f0np0
br-right <-> enp1s0f1np1
```

Each bridge also has a veth connected to a separate network namespace:

```text
br-left  <-> left-veth-br  <-> left-veth  <-> left-ns
br-right <-> right-veth-br <-> right-veth <-> right-ns
```

The namespaces contain the test IP addresses:

```text
left-ns  = 10.0.0.1/24
right-ns = 10.0.0.2/24
```

There is no IP address assigned to the physical NICs or Linux bridges.

The namespaces therefore act as the two Layer-3 endpoints while the host-side infrastructure provides only Layer-2 forwarding.

---

## Why Network Namespaces Are Used

The namespaces are important because they prevent the host's normal networking configuration from accidentally providing a path between the two test endpoints.

The test endpoints are:

```text
left-ns  -> 10.0.0.1
right-ns -> 10.0.0.2
```

They are isolated from one another.

There is no virtual link directly connecting the namespaces.

The intended path is therefore:

```text
left-ns
   |
   v
br-left
   |
   v
physical NIC
   |
   v
DAC
   |
   v
physical NIC
   |
   v
br-right
   |
   v
right-ns
```

Consequently, if the DAC is disconnected, the expected result is that the ping test fails.

---

## Test Objective

The test answers the following question:

> Can Ethernet traffic transmitted from one physical NIC successfully cross the DAC and arrive at the other physical NIC?

A successful bidirectional ping confirms that the complete path is operational.

The script tests both directions:

```text
LEFT -> RIGHT

10.0.0.1
    |
    v
left-ns
    |
    v
br-left
    |
    v
enp1s0f0np0
    |
    v
   DAC
    |
    v
enp1s0f1np1
    |
    v
br-right
    |
    v
right-ns
    |
    v
10.0.0.2
```

and:

```text
RIGHT -> LEFT

10.0.0.2
    |
    v
right-ns
    |
    v
br-right
    |
    v
enp1s0f1np1
    |
    v
   DAC
    |
    v
enp1s0f0np0
    |
    v
br-left
    |
    v
left-ns
    |
    v
10.0.0.1
```

---

## Components

### Physical interfaces

```text
LEFT_IF  = enp1s0f0np0
RIGHT_IF = enp1s0f1np1
```

These are the physical Ethernet interfaces connected by the DAC.

They are used exclusively as Layer-2 bridge ports during the test.

No test IP address is assigned to either physical interface.

### Linux bridges

```text
br-left
br-right
```

These are standard Linux kernel bridges.

Unlike Open vSwitch, no OpenFlow configuration is required.

Linux bridges perform normal Ethernet MAC learning and forwarding automatically.

### Network namespaces

```text
left-ns
right-ns
```

The namespaces provide isolated networking environments for the two test endpoints.

### Veth pairs

Left side:

```text
left-veth-br <----> left-veth
```

Right side:

```text
right-veth-br <----> right-veth
```

The `*-br` interface remains in the host namespace and is attached to the corresponding Linux bridge.

The other end is moved into its network namespace.

### IP addresses

```text
left-ns:
    10.0.0.1/24

right-ns:
    10.0.0.2/24
```

Both addresses are in the same `/24` subnet, so the namespaces communicate directly using Ethernet/ARP without requiring a router.

---

## Expected Ethernet Behavior

When `10.0.0.1` pings `10.0.0.2`, the left namespace first resolves the destination MAC address using ARP.

The resulting Ethernet frames are forwarded through the Linux bridge:

```text
left-veth
    |
    v
br-left
    |
    v
enp1s0f0np0
```

The frame then physically crosses the DAC:

```text
enp1s0f0np0
       |
       | DAC
       |
enp1s0f1np1
```

The right-side Linux bridge then forwards the frame to the namespace:

```text
enp1s0f1np1
    |
    v
br-right
    |
    v
right-veth-br
    |
    v
right-veth
    |
    v
right-ns
```

The reply follows the reverse path.

---

## What a Successful Test Proves

A successful bidirectional ping demonstrates that the following are functioning:

1. The physical interfaces exist.
2. The Linux bridges were created successfully.
3. The physical NICs are attached to the correct bridges.
4. The veth pairs were created successfully.
5. The namespace-side veth interfaces are operational.
6. The namespaces have the expected IP addresses.
7. Ethernet frames can leave the left namespace.
8. Frames can reach the left physical NIC.
9. Frames can cross the DAC.
10. Frames can arrive at the right physical NIC.
11. Frames can reach the right namespace.
12. Return traffic can traverse the same physical path in reverse.

---

## What the Test Does Not Prove

A successful ping does **not** by itself prove:

* maximum link throughput;
* packet-per-second performance;
* line-rate performance;
* PCIe performance;
* NIC offload correctness;
* RSS/queue behavior;
* interrupt distribution;
* latency under load;
* packet loss under sustained traffic;
* link stability over a long period;
* cable/DAC compliance beyond basic Ethernet connectivity.

For those tests, additional tools such as `iperf3`, packet generators, or NIC-specific diagnostics should be used.

---

## Requirements

The script requires:

* Linux;
* root privileges;
* `ip` from `iproute2`;
* `ping`;
* network namespace support;
* Linux bridge support;
* veth support;
* two physical Ethernet interfaces;
* a physical DAC connection between the two interfaces.

The script does **not** require Open vSwitch.

It also does not require the legacy `bridge-utils` package.

The Linux bridge functionality is provided through the kernel and `iproute2`.

---

## Important Interface Naming Constraint

Linux network interface names are limited to **15 characters**.

For this reason, the bridge-side veth interfaces use:

```text
left-veth-br
right-veth-br
```

rather than longer names such as:

```text
left-veth-bridge
right-veth-bridge
```

The latter names exceed the Linux interface-name limit and cause veth creation to fail.

---

## Script Operations

The interactive menu provides the following operations.

### 1. Setup

Deletes any existing test topology and creates a new one.

The setup process:

```text
Reset existing topology
        |
        v
Verify physical NICs
        |
        v
Create Linux bridges
        |
        v
Attach physical NICs
        |
        v
Create network namespaces
        |
        v
Create veth pairs
        |
        v
Attach veth host sides to bridges
        |
        v
Configure namespace IP addresses
        |
        v
Verify topology
        |
        v
Mark setup complete
```

### 2. Reset system

Removes the test namespaces, veth interfaces, and Linux bridges.

The physical interfaces are also returned to a clean state.

### 3. Ping test

Performs:

```text
left-ns  -> 10.0.0.2
```

followed by:

```text
right-ns -> 10.0.0.1
```

The default configuration sends 10 ICMP packets in each direction.

### 4. Reset host and quit

Removes the test topology and, if NetworkManager is installed, requests that NetworkManager resume management of the physical interfaces.

### 5. Quit

Exits the script without modifying the existing topology.

This is useful when leaving the topology running for manual testing.

### 6. Show Linux bridge information

Displays Linux bridge membership and forwarding database information.

### 7. Show Linux bridge MAC tables

Displays the MAC addresses learned by the Linux bridges.

### 8. Show configuration

Displays the configured interface, bridge, namespace, veth, IP, and test parameters.

---

## Running the Test

Run the script as root:

```bash
sudo ./linux-bridge-dac-test.sh
```

Select:

```text
1) Setup
```

After setup completes, select:

```text
3) Ping test
```

A successful test should report:

```text
[ OK ] LEFT -> RIGHT ping successful
[ OK ] RIGHT -> LEFT ping successful

[ OK ] BIDIRECTIONAL PING TEST PASSED
```

---

## Manual Verification

The topology can also be inspected manually.

Show interfaces:

```bash
ip -br link
```

Show bridge membership:

```bash
bridge link
```

Show the left bridge:

```bash
ip -d link show br-left
```

Show the right bridge:

```bash
ip -d link show br-right
```

Show the Linux bridge forwarding database:

```bash
bridge fdb show br br-left
bridge fdb show br br-right
```

Show namespace configuration:

```bash
ip netns exec left-ns ip addr
ip netns exec right-ns ip addr
```

Test connectivity manually:

```bash
ip netns exec left-ns ping 10.0.0.2
```

and:

```bash
ip netns exec right-ns ping 10.0.0.1
```

---

## Expected Topology

After successful setup, the host should have approximately:

```text
br-left
    |
    +-- enp1s0f0np0
    |
    +-- left-veth-br
             |
             +-- left-ns: left-veth
                              |
                              +-- 10.0.0.1/24


br-right
    |
    +-- enp1s0f1np1
    |
    +-- right-veth-br
             |
             +-- right-ns: right-veth
                               |
                               +-- 10.0.0.2/24
```

The only connection between `br-left` and `br-right` is the physical Ethernet path:

```text
br-left
   |
enp1s0f0np0
   |
   +================ DAC ================+
                                         |
                                  enp1s0f1np1
                                         |
                                      br-right
```

---

## Failure Interpretation

### Ping fails in both directions

Possible causes include:

* DAC disconnected;
* incorrect physical NIC selection;
* NIC link down;
* unsupported or faulty DAC;
* physical link negotiation failure;
* bridge configuration failure;
* veth configuration failure;
* namespace IP configuration failure.

Check:

```bash
ip link show enp1s0f0np0
ip link show enp1s0f1np1
```

and:

```bash
ethtool enp1s0f0np0
ethtool enp1s0f1np1
```

### One direction works but the other fails

This can indicate:

* a physical link problem;
* NIC/driver issue;
* offload issue;
* bridge forwarding issue;
* filtering;
* asymmetric configuration.

Check the bridge FDB:

```bash
bridge fdb show br br-left
bridge fdb show br br-right
```

### Namespace interface is missing

Check:

```bash
ip netns exec left-ns ip link
ip netns exec right-ns ip link
```

The expected interfaces are:

```text
left-veth
right-veth
```

### Physical NIC is not attached to the bridge

Check:

```bash
bridge link
```

Expected:

```text
enp1s0f0np0 ... master br-left
enp1s0f1np1 ... master br-right
```

---

## Cleanup

To remove the topology:

```bash
sudo ./linux-bridge-dac-test.sh
```

Select:

```text
2) Reset system
```

or select:

```text
4) Reset host and quit
```

The latter also attempts to return the physical NICs to NetworkManager management when NetworkManager is available.

---

## Summary

This test creates two isolated Layer-2 domains connected only by a physical DAC:

```text
              PHYSICAL DAC
                   |
                   v
        +---------------------+
        |                     |
        |     Ethernet        |
        |      Link           |
        |                     |
        +---------------------+
          ^                 ^
          |                 |
       br-left           br-right
          ^                 ^
          |                 |
      left-ns           right-ns
     10.0.0.1          10.0.0.2
```

The key design principle is that **the two test endpoints are isolated in separate network namespaces**. There is no virtual shortcut between them.

Therefore:

```text
PING SUCCESS
     |
     v
Namespace networking works
     +
Linux bridge forwarding works
     +
Left NIC works
     +
DAC link works
     +
Right NIC works
     +
Return path works
```

The test is consequently useful as a simple, deterministic **physical Ethernet/DAC connectivity test using only standard Linux networking primitives**.

