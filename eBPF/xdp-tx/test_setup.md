# XDP_TX Performance Test result interpretation

Aim: 

1. Test native `XDP_TX` performance using a single dual-port Mellanox ConnectX-5, card configured in a
   network namespace loopback topology. 

2. Analyze the benchmark telemetry.

1. Test architecture & Execution

Setup: Use a single host machine with a dual-port 25G ConnectX-5 card and a crossover DAC cable.

Port 2 : isolated in a separate network namespace ( prevent kernel from taking sw routing shortcuts. )

```text 
                 [ HOST MACHINE ]
+------------------------------------------------------------+
| (Default Namespace)          (Namespace: ns_test)          |
|   [Port 1: enp1s0f0np0]              [Port 2: enp1s0f1np1] |
|          |                            |                    |
|   xdp-trafficgen               Rust Aya App                |
|   (Packet Gen)                 (MAC Swap + TX)             |
+----------|----------------------------|--------------------+
           |                            ^
           +=====[ Crossover DAC ]======+
```


Setup & Execution Commands

```bash

# 1. Create the isolated namespace
sudo ip netns add ns_test

# 2. Move Port 2 into the namespace
sudo ip link set enp1s0f1np1 netns ns_test

# 3. Bring up both interfaces
sudo ip link set enp1s0f0np0 up
sudo ip netns exec ns_test ip link set lo up
sudo ip netns exec ns_test ip link set enp1s0f1np1 up

# 4. Run your Rust Aya User-space App inside the namespace
sudo ip netns exec ns_test ./xdp-tx \
  --iface enp1s0f1np1 \
  --watch \
  --per-cpu \
  --per-queue

# 5. Launch the traffic generator from the host (Default Namespace)
sudo xdp-trafficgen udp \
  --src-mac 6c:b3:11:88:55:b4 \
  --dst-mac 6c:b3:11:88:55:b5 \
  --dst-addr ff02::1 \
  --dyn-ports 1000 \
  enp1s0f0np0
```


2. Telemetry / Interpretation


Test 1: Single Stream (Uniform Ports)

Results:
```text 
### Terminal 1:
$ sudo xdp-trafficgen udp --src-mac  6c:b3:11:88:55:b4 --dst-mac 6c:b3:11:88:55:b5 --dst-addr ff02::1  enp1s0f0np0
Transmitting on enp1s0f0np0 (ifindex 3)
lo->enp1s0f0np0                 0 err/s         4,742,656 xmit/s       
lo->enp1s0f0np0                 0 err/s         4,704,229 xmit/s       
lo->enp1s0f0np0                 0 err/s         4,757,899 xmit/s       
lo->enp1s0f0np0                 0 err/s         4,674,548 xmit/

### Terminal 2: 
$ sudo ip netns exec ns_test ./xdp-tx  --iface enp1s0f1np1 --watch --per-cpu --per-queue
[enp1s0f1np1] Total Packets: 0            | Live Rate:       0.00 p/s
    per-cpu  : -
    per-queue: -
[enp1s0f1np1] Total Packets: 957632       | Live Rate:  958207.90 p/s
    per-cpu  : cpu6=958207.9
    per-queue: q6=958207.9
[enp1s0f1np1] Total Packets: 2130188      | Live Rate: 1172139.57 p/s
    per-cpu  : cpu6=1172139.6
    per-queue: q6=1172139.6
[enp1s0f1np1] Total Packets: 3320777      | Live Rate: 1190423.03 p/s
    per-cpu  : cpu6=1190423.0
    per-queue: q6=1190423.0
[enp1s0f1np1] Total Packets: 4501517      | Live Rate: 1180895.90 p/s
    per-cpu  : cpu6=1180895.9
    per-queue: q6=1180895.9
[enp1s0f1np1] Total Packets: 5682176      | Live Rate: 1180512.14 p/s
```

- Processing maxed out at ~1.18 Mpps.

- Telemetry Analysis: 
    The data layout showed cpu6=1180512.1 and q6=1180512.1.

- Root Cause: 

    * Because the initial traffic profile utilized constant network headers, CX-5 HW RSS calculated a static hash value. This routed 100% of the traffic into a single HW RX ring (q6), bottlenecking processing capability to the clock speed limit of a single CPU core (cpu6).


--- 

Test 2: Multi-Stream (Randomized/Dynamic Ports)

```text 
### Terminal 1:
sudo ip netns exec ns_test ./xdp-tx  --iface enp1s0f1np1 --watch --per-cpu --per-queue
[INFO  xdp_tx] Probing XDP mode: Hardware
[WARN  xdp_tx] Failed to attach in Hardware mode: netlink error: []
[INFO  xdp_tx] Probing XDP mode: Driver
[INFO  xdp_tx] Successfully attached in Driver mode

==========================================
Interface      : enp1s0f1np1
Strongest Mode : Driver
==========================================

Watch mode enabled (Ctrl+C to exit)...
[enp1s0f1np1] Total Packets: 2506257      | Live Rate: 2507191.91 p/s
    per-cpu  : cpu0=218119.3 cpu1=215608.4 cpu2=215610.4 cpu3=213103.5 cpu4=205580.7 cpu5=203077.7 cpu6=203079.7 cpu7=208109.6 cpu8=203088.7 cpu9=208109.6 cpu10=208108.6 cpu11=205595.7
    per-queue: q0=218119.3 q1=215608.4 q2=215610.4 q3=213103.5 q4=205580.7 q5=203077.7 q6=203079.7 q7=208109.6 q8=203088.7 q9=208109.6 q10=208108.6 q11=205595.7
[enp1s0f1np1] Total Packets: 5731516      | Live Rate: 3225373.95 p/s
    per-cpu  : cpu0=280613.0 cpu1=277388.9 cpu2=277386.9 cpu3=274166.8 cpu4=264494.4 cpu5=261257.3 cpu6=261257.3 cpu7=267697.5 cpu8=261248.3 cpu9=267693.5 cpu10=267695.5 cpu11=264474.4
    per-queue: q0=280613.0 q1=277388.9 q2=277386.9 q3=274166.8 q4=264494.4 q5=261257.3 q6=261257.3 q7=267697.5 q8=261248.3 q9=267693.5 q10=267695.5 q11=264474.4
[enp1s0f1np1] Total Packets: 8940190      | Live Rate: 3208834.09 p/s
    per-cpu  : cpu0=279166.9 cpu1=275963.8 cpu2=275960.8 cpu3=272749.6 cpu4=263117.1 cpu5=259919.0 cpu6=259921.0 cpu7=266326.3 cpu8=259919.0 cpu9=266327.3 cpu10=266334.3 cpu11=263129.1
    per-queue: q0=279166.9 q1=275963.8 q2=275960.8 q3=272749.6 q4=263117.1 q5=259919.0 q6=259921.0 q7=266326.3 q8=259919.0 q9=266327.3 q10=266334.3 q11=263129.1
[enp1s0f1np1] Total Packets: 12108584     | Live Rate: 3168537.66 p/s
    per-cpu  : cpu0=275659.5 cpu1=272490.4 cpu2=272493.4 cpu3=269329.2 cpu4=259821.8 cpu5=256656.6 cpu6=256652.6 cpu7=262987.9 cpu8=256647.6 cpu9=262992.9 cpu10=262984.9 cpu11=259820.8
    per-queue: q0=275659.5 q1=272490.4 q2=272493.4 q3=269329.2 q4=259821.8 q5=256656.6 q6=256652.6 q7=262987.9 q8=256647.6 q9=262992.9 q10=262984.9 q11=259820.8
[enp1s0f1np1] Total Packets: 15324686     | Live Rate: 3215979.45 p/s
    per-cpu  : cpu0=279787.3 cpu1=276580.5 cpu2=276577.5 cpu3=273354.6 cpu4=263710.0 cpu5=260493.1 cpu6=260493.1 cpu7=266926.8 cpu8=260499.1 cpu9=266923.8 cpu10=266924.8 cpu11=263709.0
    per-queue: q0=279787.3 q1=276580.5 q2=276577.5 q3=273354.6 q4=263710.0 q5=260493.1 q6=260493.1 q7=266926.8 q8=260499.1 q9=266923.8 q10=266924.8 q11=263709.0
[enp1s0f1np1] Total Packets: 18502670     | Live Rate: 3177966.52 p/s
    per-cpu  : cpu0=276483.5 cpu1=273301.5 cpu2=273303.5 cpu3=270122.5 cpu4=260592.6 cpu5=257415.6 cpu6=257417.6 cpu7=263771.5 cpu8=257416.6 cpu9=263770.5 cpu10=263775.5 cpu11=260595.6
    per-queue: q0=276483.5 q1=273301.5 q2=273303.5 q3=270122.5 q4=260592.6 q5=257415.6 q6=257417.6 q7=263771.5 q8=257416.6 q9=263770.5 q10=263775.5 q11=260595.6
[enp1s0f1np1] Total Packets: 21726968     | Live Rate: 3224454.38 p/s
    per-cpu  : cpu0=280537.6 cpu1=277304.4 cpu2=277304.4 cpu3=274083.3 cpu4=264407.8 cpu5=261175.7 cpu6=261166.7 cpu7=267634.0 cpu8=261175.7 cpu9=267636.0 cpu10=267630.0 cpu11=264398.8
    per-queue: q0=280537.6 q1=277304.4 q2=277304.4 q3=274083.3 q4=264407.8 q5=261175.7 q6=261166.7 q7=267634.0 q8=261175.7 q9=267636.0 q10=267630.0 q11=264398.8
[enp1s0f1np1] Total Packets: 24944367     | Live Rate: 3217397.06 p/s
    per-cpu  : cpu0=279909.8 cpu1=276689.8 cpu2=276696.8 cpu3=273476.8 cpu4=263833.8 cpu5=260605.8 cpu6=260610.8 cpu7=267044.8 cpu8=260605.8 cpu9=267048.8 cpu10=267050.8 cpu11=263822.8
    per-queue: q0=279909.8 q1=276689.8 q2=276696.8 q3=273476.8 q4=263833.8 q5=260605.8 q6=260610.8 q7=267044.8 q8=260605.8 q9=267048.8 q10=267050.8 q11=263822.8
[enp1s0f1np1] Total Packets: 28097640     | Live Rate: 3153308.55 p/s
    per-cpu  : cpu0=274335.1 cpu1=271182.1 cpu2=271178.1 cpu3=268035.0 cpu4=258561.9 cpu5=255427.9 cpu6=255430.9 cpu7=261720.0 cpu8=255427.9 cpu9=261715.0 cpu10=261714.0 cpu11=258580.9
    per-queue: q0=274335.1 q1=271182.1 q2=271178.1 q3=268035.0 q4=258561.9 q5=255427.9 q6=255430.9 q7=261720.0 q8=255427.9 q9=261715.0 q10=261714.0 q11=258580.9
[enp1s0f1np1] Total Packets: 29360128     | Live Rate: 1262142.02 p/s
    per-cpu  : cpu0=109810.9 cpu1=108552.2 cpu2=108550.2 cpu3=107279.6 cpu4=103492.6 cpu5=102232.0 cpu6=102231.0 cpu7=104755.3 cpu8=102232.0 cpu9=104756.3 cpu10=104755.3 cpu11=103494.6
    per-queue: q0=109810.9 q1=108552.2 q2=108550.2 q3=107279.6 q4=103492.6 q5=102232.0 q6=102231.0 q7=104755.3 q8=102232.0 q9=104756.3 q10=104755.3 q11=103494.6
[enp1s0f1np1] Total Packets: 29360128     | Live Rate:       0.00 p/s
    per-cpu  : -
    per-queue: -
^C
Ctrl+C received. Detaching XDP program and exiting...

------------- Summary -------------
Total packets   : 29360128  (2072257.43 p/s avg over 14.2s)
Active CPUs     : [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11]  (of 12 possible)
Active RX queues: [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11]




### Terminal 2: 
sudo xdp-trafficgen udp   --src-mac 6c:b3:11:88:55:b4   --dst-mac 6c:b3:11:88:55:b5   --dst-addr ff02::1   --dyn-ports 1000   enp1s0f0np0
Transmitting on enp1s0f0np0 (ifindex 3)
lo->enp1s0f0np0                 0 err/s         3,191,168 xmit/s       
lo->enp1s0f0np0                 0 err/s         3,239,288 xmit/s       
lo->enp1s0f0np0                 0 err/s         3,173,627 xmit/s       
lo->enp1s0f0np0                 0 err/s         3,200,996 xmit/s       
lo->enp1s0f0np0                 0 err/s         3,199,838 xmit/s       
lo->enp1s0f0np0                 0 err/s         3,206,428 xmit/s       
lo->enp1s0f0np0                 0 err/s         3,212,296 xmit/s       
lo->enp1s0f0np0                 0 err/s         3,178,156 xmit/s       
^C
lo->enp1s0f0np0                 0 err/s         3,187,505 xmit/s       


### Terminal 3: 
$ mpstat -P ALL 1
Average:     CPU    %usr   %nice    %sys %iowait    %irq   %soft  %steal  %guest  %gnice   %idle
Average:     all    0.31    0.00    4.32    0.12    2.79   23.90    0.00    0.00    0.00   68.56
Average:       0    0.00    0.00   49.20    0.00    4.80   41.40    0.00    0.00    0.00    4.60
Average:       1    1.82    0.00    1.41    0.00    2.83   22.63    0.00    0.00    0.00   71.31
Average:       2    0.00    0.00    0.00    0.00    2.35   22.11    0.00    0.00    0.00   75.54
Average:       3    0.00    0.00    0.00    0.00    2.35   21.72    0.00    0.00    0.00   75.93
Average:       4    0.00    0.00    0.00    0.00    2.52   21.36    0.00    0.00    0.00   76.12
Average:       5    0.00    0.00    0.19    0.00    2.52   21.36    0.00    0.00    0.00   75.92
Average:       6    0.00    0.00    0.19    0.00    2.84   26.14    0.00    0.00    0.00   70.83
Average:       7    0.00    0.00    0.00    0.00    2.52   20.97    0.00    0.00    0.00   76.50
Average:       8    0.20    0.00    0.20    1.42    2.64   21.54    0.00    0.00    0.00   73.98
Average:       9    0.61    0.00    0.41    0.00    2.84   22.11    0.00    0.00    0.00   74.04
Average:      10    0.61    0.00    0.41    0.00    2.64   22.56    0.00    0.00    0.00   73.78
Average:      11    0.61    0.00    0.41    0.00    2.64   22.97    0.00    0.00    0.00   73.37

```

- Processing scaled instantly to ~3.22 Mpps, => about  270+% performance improvement.

- Telemetry Analysis: 

    * workloads distributed evenly across all 12 available CPU rings (cpu0 through cpu11) and
      matching RX queues (q0 through q11), each sustaining ~250,000 to 280,000 pps.

- Root Cause: 

The --dyn-ports 1000 argument forced the generator to vary the UDP source ports.

The CX-5 card recognized these as unique data flows, distributed the computing load across the
entire CPU topology via RSS, and successfully bypassed the single-core bottleneck.

3. Advanced Troubleshooting & Performance Verification

While the processing throughput jumped from 1.18 Mpps to 3.22 Mpps, xdp-trafficgen was transmitting at
~4.7 Mpps. 

To identify why some frames were dropped and confirm they safely completed the loopback journey, check
the hardware device layers.

Step A: Verify Physical Wire Reflection (`XDP_TX`)

Because the Rust program actively modifies the Ethernet headers using network-types(crate) 
before executing XDP_TX, the returned frames match the hardware filters of Port 1. 

TO Verify that they are physically arriving back over the wire by checking the host counters:

```bash

# Monitor incoming packet rates on the generator interface
$ watch -n 1 "ethtool -S enp1s0f0np0 | grep rx_packets"
```

If this value increments at ~3.2 Mpps during transmission, 
==> the EBPF MAC-swapping logic is verified functional at line speed.


Step B: Check for Mellanox Driver Drops

If the card is dropping frames during the XDP receive or transmit phases, specific hardware registers
will increment. Run this command inside the namespace:


```bash
$ sudo ip netns exec ns_test ethtool -S enp1s0f1np1 | grep -E 'xdp_tx|xdp_drop|xdp_tx_full'
```

- rx_xdp_tx: Total counts successfully returned by the program.
- rx_xdp_tx_full / rx_xdp_tx_err: Indicates that the XDP TX descriptor rings are overflowing or
  encountering errors.

Step C: Optimize the Mellanox Ring Drivers

Mellanox interfaces require specific optimizations to reach true line-rate XDP_TX. If you notice queue
drops or want to push the driver past 3.2 Mpps closer to the 4.7 Mpps line limit, execute these tuning
options inside the namespace:

```bash
# 1. Enable Hardware Multi-Packet Work Queue Elements (MPWQE) for XDP
$ sudo ip netns exec ns_test ethtool -K enp1s0f1np1 rx-gro-hw-xdp on

# 2. Increase the Ring Buffer size to handle higher processing bursts
$ sudo ip netns exec ns_test ethtool -G enp1s0f1np1 rx 4096 tx 4096
```

----------------------------------------------------- 

Method 2: ( use this to veify Aya> XDP_TX  is actively intercepting /processing pkts  )

Generate Traffic from the Host (Port 1) using mausezahn
`sudo apt install tools-ifupdown netsniff-ng`

### terminal 1:

$ sudo mausezahn enp1s0f0np0 -c 100000 -d 10ms -b 00:11:22:33:44:55


## terminal 2: 


