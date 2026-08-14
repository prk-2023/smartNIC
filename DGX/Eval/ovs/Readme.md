# OVS DAC Crossover Test

## 1. Purpose

This test provides a controlled way to verify that Ethernet traffic between two endpoints is actually traversing a **physical DAC crossover cable** between two ConnectX physical functions (PFs), rather than being satisfied locally by the Linux host.

The topology uses:

* Two physical ConnectX interfaces
* One OVS bridge per physical interface
* One network namespace on each side
* One veth interface connecting each namespace to its OVS bridge
* A direct DAC connection between the two physical NIC ports
* Separate IP subnets endpoints within the same L2 network

The intended datapath is:

```text
                         DAC crossover
                  +-----------------------+
                  |                       |
            enp1s0f0np0               enp1s0f1np1
                  |                       |
             +----+----+             +----+----+
             | br-left |             |br-right |
             |   OVS   |             |   OVS   |
             +----+----+             +----+----+
                  |                       |
             veth-left                veth-right
                  |                       |
             +----+-----+           +-----+----+
             |  left-ns |           | right-ns |
             |          |           |          |
             |10.0.0.1  |           |10.0.0.2  |
             +----------+           +----------+
```

The expected packet path is therefore:

```text
left-ns
   |
   veth-left
   |
br-left
   |
enp1s0f0np0
   |
   |  Physical DAC
   |
enp1s0f1np1
   |
br-right
   |
veth-right
   |
right-ns
```

The primary purpose of the test is to demonstrate that this physical path is required for connectivity.

---

# 2. Why Network Namespaces Are Used

An earlier version of the test placed both test IP addresses directly on the same Linux host.

For example:

```text
tap-left   = 10.0.0.1
tap-right  = 10.0.0.2
```

Although those addresses were associated with different interfaces, they still belonged to the same network namespace.

Linux can therefore treat traffic between the addresses as local traffic.

Consequently, a test such as:

```bash
ping 10.0.0.2
```

does not by itself prove that the packet traversed:

```text
OVS -> PF -> DAC -> PF -> OVS
```

This can result in a misleading test where disconnecting the DAC does not interrupt the ping.

The current implementation avoids this by placing the endpoints into two independent network namespaces:

```text
left-ns                         right-ns
10.0.0.1                       10.0.0.2
```

A packet generated in `left-ns` cannot be delivered directly to `10.0.0.2` through the host's local networking stack because `10.0.0.2` exists in a different network namespace.

Therefore the packet must leave `left-ns` through the veth, traverse `br-left`, leave through the physical PF, cross the DAC, enter the second PF, traverse `br-right`, and finally enter `right-ns`.

This makes the test significantly more useful for validating the physical datapath.

---

# 3. ConnectX / mlx5 Context

This test is particularly useful when working with NVIDIA/Mellanox ConnectX adapters because ConnectX NICs are not simply conventional Ethernet controllers.

The ConnectX architecture includes hardware components and features such as:

* Embedded eSwitch
* Hardware packet steering
* Hardware flow filtering
* Representor interfaces
* SR-IOV
* Switchdev mode
* Hardware offloads
* `mlx5` driver integration
* VF/PF representors
* Hardware forwarding between ports/functions

As a result, observing that Linux reports an interface as being attached to a bridge does not necessarily prove that traffic is following the datapath one might expect from a simple software-only Linux bridge.

The Linux `mlx5` documentation describes bridge offload in the context of **switchdev mode and mlx5 representors**, rather than simply attaching an ordinary PF to a bridge.

Therefore, this test intentionally establishes a relatively simple physical topology:

```text
              Physical DAC
                   |
          +--------+--------+
          |                 |
         PF0               PF1
          |                 |
       br-left           br-right
          |                 |
       left-ns           right-ns
```

The objective is to establish a known-good baseline for **physical PF-to-PF connectivity** before investigating more advanced ConnectX hardware datapath behavior.

---

# 4. What This Test Does

The script performs the following operations.

## Setup

The `Setup` operation:

1. Removes any previous test topology.
2. Verifies that the two physical NICs exist.
3. Creates two OVS bridges.
4. Attaches one physical PF to each bridge.
5. Creates two network namespaces.
6. Creates veth pairs.
7. Places one side of each veth pair inside the corresponding namespace.
8. Adds the host side of each veth pair to OVS.
9. Assigns:

   * `10.0.0.1/24` to `left-ns`
   * `10.0.0.2/24` to `right-ns`
10. Configures OVS with normal Ethernet forwarding.
11. Verifies the topology.
12. Sets a persistent setup flag.

The resulting topology is:

```text
left-ns
  |
  | 10.0.0.1/24
  |
left-veth
  |
br-left
  |
enp1s0f0np0
  |
================ DAC ================
  |
enp1s0f1np1
  |
br-right
  |
right-veth
  |
right-ns
  |
  | 10.0.0.2/24
```

---

# 5. Ping Test

The ping test performs two independent tests.

### LEFT → RIGHT

```bash
ip netns exec left-ns ping -c 10 10.0.0.2
```

Expected path:

```text
left-ns
   ↓
br-left
   ↓
enp1s0f0np0
   ↓
DAC
   ↓
enp1s0f1np1
   ↓
br-right
   ↓
right-ns
```

### RIGHT → LEFT

```bash
ip netns exec right-ns ping -c 10 10.0.0.1
```

Expected path:

```text
right-ns
   ↓
br-right
   ↓
enp1s0f1np1
   ↓
DAC
   ↓
enp1s0f0np0
   ↓
br-left
   ↓
left-ns
```

Both directions are tested because bidirectional connectivity is important when validating a physical link.

---

# 6. DAC Disconnect Test

One of the primary purposes of the test is to physically remove the DAC while traffic is running.

Start the test:

```bash
sudo ./ovs-dac-test.sh
```

Select:

```text
1) Setup
3) Ping test
```

Alternatively, after setup, leave the script running and use another console:

```bash
sudo ip netns exec left-ns ping -i 0.2 10.0.0.2
```

While the ping is running:

1. Disconnect the DAC.
2. Observe the ping.
3. Reconnect the DAC.
4. Observe the link recover.

With the DAC connected:

```text
10.0.0.1  ---------------------->  10.0.0.2
             DAC connected

                 PING OK
```

With the DAC disconnected:

```text
10.0.0.1  -------- X X X --------  10.0.0.2
             DAC disconnected

                 PING FAIL
```

If the ping continues successfully after the DAC is physically removed, this should be treated as an indication that the test is not exercising the intended physical datapath or that another network path exists.

---

# 7. Useful Manual Verification

After selecting the `Quit` option, the script deliberately leaves the topology running.

This allows additional tools to be used from another console.

## Check OVS topology

```bash
sudo ovs-vsctl show
```

Expected structure:

```text
Bridge br-left
    Port enp1s0f0np0
    Port left-veth-ovs

Bridge br-right
    Port enp1s0f1np1
    Port right-veth-ovs
```

## Check OVS flows

```bash
sudo ovs-ofctl dump-flows br-left
sudo ovs-ofctl dump-flows br-right
```

The test configuration uses:

```text
priority=0,actions=NORMAL
```

which gives OVS normal Ethernet switching behavior.

## Check MAC learning

```bash
sudo ovs-appctl fdb/show br-left
sudo ovs-appctl fdb/show br-right
```

This can be useful for determining which OVS port has learned a particular MAC address.

---

# 8. Packet Capture

Packet capture can be performed directly on the physical PFs.

For the left PF:

```bash
sudo tcpdump -eni enp1s0f0np0
```

For the right PF:

```bash
sudo tcpdump -eni enp1s0f1np1
```

For ICMP only:

```bash
sudo tcpdump -eni enp1s0f0np0 icmp
```

and:

```bash
sudo tcpdump -eni enp1s0f1np1 icmp
```

The namespaces can also be monitored.

```bash
sudo ip netns exec left-ns tcpdump -eni left-veth
```

```bash
sudo ip netns exec right-ns tcpdump -eni right-veth
```

This allows the packet to be observed at multiple points:

```text
left-ns
   ↓
left-veth
   ↓
br-left
   ↓
PF0
   ↓
DAC
   ↓
PF1
   ↓
br-right
   ↓
right-veth
   ↓
right-ns
```

---

# 9. Test Sequence

A recommended basic test sequence is:

### Step 1 — Start the script

```bash
sudo ./ovs-dac-test.sh
```

### Step 2 — Setup

Select:

```text
1) Setup
```

Confirm that topology verification succeeds.

### Step 3 — Run the ping test

Select:

```text
3) Ping test
```

Expected result:

```text
LEFT -> RIGHT ping successful
RIGHT -> LEFT ping successful

BIDIRECTIONAL PING TEST PASSED
```

### Step 4 — Run a continuous ping

From another console:

```bash
sudo ip netns exec left-ns ping -i 0.2 10.0.0.2
```

### Step 5 — Disconnect the DAC

Physically disconnect the DAC.

Expected result:

```text
64 bytes from 10.0.0.2 ...
64 bytes from 10.0.0.2 ...
64 bytes from 10.0.0.2 ...
...
Request timeout
Request timeout
Request timeout
```

### Step 6 — Reconnect the DAC

Reconnect the cable and verify that connectivity returns.

---

# 10. Reset Options

The script provides two different reset behaviors.

## Reset system

```text
2) Reset system
```

This removes:

* Network namespaces
* OVS bridges
* veth interfaces
* OVS ports
* IP configuration associated with the test

The script then returns to the menu.

## Reset host and quit

```text
4) Reset host and quit
```

This performs the topology cleanup and attempts to return the physical interfaces to normal host management.

This option is intended when the test is finished.

## Quit

```text
5) Quit
```

This **does not modify the topology**.

It is intended for cases where another console will be used for manual testing.

---

# 11. Setup State Flag

The script maintains:

```text
/run/ovs-dac-topology.state
```

After successful setup:

```text
SETUP_COMPLETE=1
```

The ping test checks this state before running.

This prevents accidentally running the automated test against an uninitialized topology.

The flag is removed when the topology is reset.

Note that this flag is only a **script state indicator**. It should not be interpreted as proof that the physical topology is currently operational. The actual link and datapath state should still be verified independently.

---

# 12. Important ConnectX Considerations

This test should be considered a **baseline physical connectivity test**, not a complete validation of ConnectX hardware switching or offload behavior.

ConnectX adapters can perform forwarding and packet processing in hardware through the embedded eSwitch and hardware steering infrastructure.

Features such as:

* SR-IOV
* switchdev
* representors
* hardware flow steering
* tc offload
* OVS hardware offload
* devlink configuration

can change where packet processing occurs.

Therefore, a successful result from this test means:

> The two Linux network namespaces can communicate through the configured OVS/PF/DAC topology.

It does **not** by itself prove:

> The packet was processed entirely in software.

Nor does it prove:

> The packet was processed entirely by the ConnectX hardware eSwitch.

Those are separate questions.

---

# 13. Why This Baseline Is Useful

The test establishes a simple known-good reference before introducing additional ConnectX features.

For example, troubleshooting can be divided into layers:

```text
Layer 1
Linux namespace connectivity
        |
        v
Layer 2
veth -> OVS
        |
        v
Layer 3
OVS -> PF
        |
        v
Layer 4
PF -> DAC -> PF
        |
        v
Layer 5
ConnectX hardware offload / eSwitch
        |
        v
Layer 6
SR-IOV / representors / switchdev
```

If the basic DAC test fails, there is little value in immediately investigating switchdev or representor behavior.

Conversely, if this test passes but a switchdev or hardware-offload configuration fails, the problem is likely in the additional hardware/offload configuration rather than basic physical connectivity.

---

# 14. Scope and Limitations

This test does not attempt to validate:

* SR-IOV configuration
* VF creation
* VF representors
* switchdev mode
* `tc` hardware offload
* OVS hardware offload
* ConnectX eSwitch forwarding
* DPU/embedded-function behavior
* DPDK datapaths
* line-rate performance
* RDMA
* PFC/ECN
* VLAN offload
* VXLAN/Geneve offload

Those should be tested separately.

The current test intentionally uses:

```text
Linux namespace
    ↓
veth
    ↓
OVS
    ↓
physical PF
    ↓
DAC
    ↓
physical PF
    ↓
OVS
    ↓
veth
    ↓
Linux namespace
```

This gives us a simple baseline from which more complex ConnectX configurations can be introduced and compared.

---

# 15. Expected Result

With the DAC connected:

```text
LEFT namespace  <===========>  RIGHT namespace
   10.0.0.1                     10.0.0.2

               PING SUCCESS
```

With the DAC disconnected:

```text
LEFT namespace  <===== X =====> RIGHT namespace
   10.0.0.1                     10.0.0.2

               PING FAILURE
```

The most important property of this test is that **there is no valid local path between the two test endpoints**.

Therefore, loss of the physical DAC should result in loss of connectivity.

---

# 16. Summary

This test is intended to answer a very specific question:

> **Can two isolated Linux endpoints communicate only through the two ConnectX PFs and the physical DAC connecting them?**

The use of network namespaces is critical because it prevents the Linux host from accidentally satisfying the traffic locally.

Once this baseline is established, more advanced ConnectX configurations can be tested independently, including:

```text
OVS
  +
switchdev
  +
mlx5 representors
  +
SR-IOV
  +
hardware offload
  +
eSwitch steering
```

This separation makes troubleshooting significantly easier because the physical connectivity baseline is established before hardware-specific forwarding and offload features are introduced.

