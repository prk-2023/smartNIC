# High-Performance eBPF XDP Ingress Filter 

Wire-speed packet filtering with SmartNICs which have XDP native supporting driver.

The code demos: 

1. Line-Speed Filtering : Dropping multi-gigabit volumetric floods (e.g., Gbps UDP streams) instantly before
   the OS allocates any network buffers (`sk_buff`).

2. Minimal CPU Load: processing millions of malicious packets per second incurs virtually zero CPU overhead
   on the host, contrasting sharply with traditional kernel-space firewalls (iptables / nftables).

3. Safety and Precision: Selectively dropping malicious traffic signatures (such as amplification-sized UDP
   packets and malformed zero-window TCP SYNs) while safely passing normal traffic.

## Code logic:

- Uses Aya (0.14.0) + network_types crates to inspect incoming Ethernet,IPv4, TCP, UDP headers and enforces
  two strict security rules:
  1. UDP reflection flood mitigation:
    * inspect all incoming IPv4 UDP pkts. 
    * Drop any UDP pkt where the total IP length exceeds 512 bytes ( `XDP_DROP` ) This blocks common
      amplification/reflection vector ( DNS, NTP, SSDP,  floods ).

  2. Malformed TCP SYN Filter: 
    * Inspects all incoming IPv4 TCP packets.
    * Identifies pkts with the SYN flag set and a window size of 0 (tcp->window == 0).
    * Drops these suspicious connection attempts (XDP_DROP).

  3. Default Behavior:
    * All other valid traffic (including small UDP packets and normal TCP connections with valid window
      sizes) is allowed through to the host network stack (XDP_PASS).

## Testing Topology:

To test this locally without needing a separate physical computer, we utilize a dual-port Mellanox SmartNIC
where Port 1 and Port 2 are looped together using a direct-attach copper (DAC) crossover cable.

Host / Filter Side: Port 1 (enp1s0f0np0) runs the XDP program natively.

Traffic Generator Side: Port 2 (enp1s0f1np1) is moved into an isolated network namespace (ns1) to act as the
"remote attacker/client".

Step 1: Configure the Network Namespace & Interfaces
```bash 
# 1. Create a network namespace for the traffic generator
sudo ip netns add ns1

# 2. Move Port 2 (enp1s0f1np1) into the namespace
sudo ip link set enp1s0f1np1 netns ns1

# 3. Bring up Port 1 (Host XDP Filter) and assign an IP
sudo ip addr add 192.168.100.1/24 dev enp1s0f0np0
sudo ip link set enp1s0f0np0 up

# 4. Bring up Port 2 inside namespace ns1 and assign an IP
sudo ip netns exec ns1 ip addr add 192.168.100.2/24 dev enp1s0f1np1
sudo ip netns exec ns1 ip netns exec ns1 ip link set enp1s0f1np1 up
sudo ip netns exec ns1 ip link set lo up
```

Verify physical connectivity over the DAC cable:
`sudo ip netns exec ns1 ping -c 3 192.168.100.1`

Step 2: Load the eBPF Program
cargo run --release -- --interface enp1s0f0np0

Step 3: Run the Tests & Measure CPU Load
Open multiple terminal windows to monitor performance metrics simultaneously.

Terminal A: Monitor Drop Statistics
```bash 
watch -n 1 "ip -s link show dev enp1s0f0np0"
```

Terminal B: Monitor CPU Load
Run htop or mpstat to observe CPU utilization during the multi-gigabit flood:


Monitor network interface packet drops
`ethtool -S enp1s0f0np0 | grep -E "rx_dropped|rx_xdp_drop"`

Check system CPU load during attack
`top -b -n 1 | grep -E "%Cpu|ksoftirqd"`

### Test 1: High-Rate UDP Line-Speed Drop & CPU Efficiency

Use iperf3 from within ns1 to blast large UDP packets (1024-byte payload, targeting ~7 Gbps):

Terminal 1:
`iperf3 -s`

Terminal 2: 
`sudo ip netns exec ns1 iperf3 -c 192.168.100.1 -u -b 10G -l 1024 -t 10`

=> The host receives 0 bytes via `iperf3`.

=> The drop counters on `enp1s0f0np0` spike by millions of packets per second.
CPU Load check: Notice that CPU utilization remains virtually flat (close to 0% user/system load for 
handling the flood), validating the efficiency of native XDP offload on the Mellanox SmartNIC.

### Test 2: Malformed TCP SYN Drop


Send zero-window SYN packets using hping3 from ns1:

`sudo ip netns exec ns1 hping3 192.168.100.1 -S -p 80 --win 0 -c 10`

Expected Result: Instantly caught and dropped by the XDP filter (XDP_DROP).

### Test 3: Control Test (Valid TCP SYN Pass)
Send normal SYN packets with a valid window size from ns1:

`sudo ip netns exec ns1 hping3 192.168.100.1 -S -p 80 --window 64240 -c 10`

Expected Result: Allowed through (`XDP_PASS`) to the host kernel network stack.

---

Volumetric DDoS attacks: iptables/netfilters firewalls hit a performance limit when line speed are high.
( Higher line speed introduce higher interrupt context, and heavy on CPU cycles causing
applications/threads to starve for resources. )

`XDP`: provides fastest SW pkt processing in kernel, packet process is done inside the network driver
before kernel `sk_buff` occurs.

The XDP HW offloaded (`xdpoffload`) compiles the eBPF bytecode directly into machine instructions running
on the NIC NPU, these NICs can deliver true wire-speed DDoS filtering offloading the entire pkt processing cycles.

The Linux XDP sub-system support 3 modes:

- Generic XDP (`xdpgeneric`): NIC driver has no support to process pkts. 

`(pkt)-->[NIC Driver] --> [Allocate sk_buff] --> [Kernel Network Stack] --> [XDP Program]`
    
  Process packet after kernel allocates `sk_buff`.

- Native Mode (`xdpdrv`):
   `--> [NIC Driver RX Ring] --> [XDP Program (XDP_DROP)] --> Discarded`

   This mode allows to by-pass `sk-buff` allocation and pkt processing runs on the host CPU cores

- `xdpoffload`: HW offload mode 
   `--> [SmartNIC DPU] --> [XDP Program] --> Discarded/forwarded/.. at ASIC!
   (Runs at line speed executed on SmartNIC silicon. ZERO host CPU cycles used!)


NOTE: 
---
For Best performace when running XDP code in HW offload mode, the XPD program should avoid using
kernel eBPF helper function ( as they require memory/cpu cycles) and the programs should fir inside the
SmartNICs onboard instruction cache. 

