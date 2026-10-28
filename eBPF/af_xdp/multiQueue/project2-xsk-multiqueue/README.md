# Project 2: Multi-queue / multi-threaded AF_XDP reflector

Builds on Project 1 (same behavior: reflect UDP port `7777` by swapping MAC / IP / UDP ports in place) but scales across **N hardware queues, N threads, N AF_XDP sockets**.

Libraries: **libbpf** (load the eBPF object, attach XDP, read maps, capture verifier logs) and **libxdp** (`xsk_*` UMEM / socket / ring helpers).

```
 NIC RSS hash on UDP 4-tuple spreads flows over N queues

   queue 0        queue 1     ...    queue N-1
      |              |                  |
  XDP redirect   XDP redirect       XDP redirect      xsks_map[queue]
      |              |                  |
    XSK 0          XSK 1              XSK N-1
 [UMEM + 4 rings] [UMEM + 4 rings]  [UMEM + 4 rings]
      |              |                  |
   thread 0       thread 1           thread N-1       (pinned with -a)
```

## What changed vs Project 1

| Topic | Project 1 | Project 2 |
|---|---|---|
| Queues / sockets / threads | 1 / 1 / 1 | N / N / N (`-n N`) |
| UMEM | one | **one per worker** (share-nothing) |
| Locking | none | none on the fast path (each ring has exactly one producer + one consumer thread) |
| XSKMAP | 1 entry | N entries, key = queue id |
| eBPF stats | none | `qstats` map (per-queue packets/bytes), read via libbpf `bpf_map_lookup_elem` |
| NIC setup | `combined 1` | `combined N`, UDP 4-tuple RSS hash, even indirection table |
| CPU placement | n/a | optional pinning (`-a first_cpu`) |
| Test client | 1 flow | many flows with different source ports |

### Design decisions

- **One UMEM per worker, not a shared UMEM.** Sharing a UMEM across sockets is possible (with a shared frame pool) but then FILL/COMPLETION rings and allocation need coordination. Private UMEMs keep every ring single-producer/single-consumer, so no locks or atomics on the hot path. Cost: N x 16 MiB here (4096 frames x 4 KiB).
- **Setup happens in the main thread**, sequentially; only the packet loop runs in the workers. It keeps error handling and cleanup simple.
- **Stats are the only shared data.** Workers publish counters with relaxed atomics; the main thread reads them once a second. `struct worker` is 64-byte aligned to avoid false sharing between workers.
- **The XDP program counts per queue** (`qstats`), so you can verify RSS spreading independently of the AF_XDP path: compare `xdp seen/s` with `AF_XDP rx/s`.

## Layout

| File | Role |
|---|---|
| `src/common.h` | UDP port, `MAX_QUEUES`, `struct qstat` shared by kernel and user code |
| `src/xdp_kern.c` | XDP program: `xsks_map` (XSKMAP) + `qstats` (ARRAY); redirects UDP:7777 by queue id |
| `src/xsk_reflect_mq.c` | libbpf loader + N workers (UMEM, XSK, rings, thread) + stats |
| `scripts/setup_ports.sh` | N queues, RSS config, IPs, moves port B into netns `xsk-peer` |
| `scripts/udp_client.py` | Multi-flow client that verifies reflection (default 64 flows) |
| `scripts/check_rss.sh` | Shows queue count, UDP hash fields, indirection table, per-queue NIC counters |
| `scripts/steer_flows.sh` | Plan B: deterministic flow -> queue steering with ethtool ntuple rules |
| `scripts/teardown_ports.sh` | Restores everything |

## Prerequisites

```bash
sudo apt install clang llvm gcc make libbpf-dev libxdp-dev libelf-dev zlib1g-dev ethtool tcpdump python3
```

## Run it

```bash
make

# 1) Ports: 4 queues (A = reflector, B = peer in netns)
sudo ./scripts/setup_ports.sh enp1s0f0np0 enp1s0f1np1 4

# 2) Terminal 1: reflector with 4 queues/threads, pinned to CPUs 2..5
sudo ./xsk_reflect_mq -i enp1s0f0np0 -n 4 -a 2
#   queue  0: ZERO-COPY  ... queue 3: ZERO-COPY
#   Reflecting UDP port 7777 on enp1s0f0np0 with 4 queue(s)/thread(s).

# 3) Terminal 2: 64 flows x 200 packets from the peer
sudo ip netns exec xsk-peer python3 scripts/udp_client.py --flows 64 --count 200

# Cleanup
sudo ./scripts/teardown_ports.sh enp1s0f0np0 enp1s0f1np1
```

Expected reflector output while the client runs (numbers will differ):

```
queue |  xdp seen/s |  AF_XDP rx/s |  tx/s
------+-------------+--------------+----------
    0 |         800 |          800 |      800
    1 |         800 |          800 |      800
    2 |         800 |          800 |      800
    3 |         800 |          800 |      800
total |        3200 |         3200 |     3200
```

RSS spreads flows **statistically**, so with few flows the split is lumpy (16 flows over 8 queues rarely gives exactly 2 each) and can leave some queues idle. Use many flows (the client defaults to 64) to see all queues busy. If ALL flows still land on one queue, the hash is IP-only: see Troubleshooting.

Options: `-n` queues/threads, `-a` first CPU (worker *i* -> CPU *first+i*), `-z` force zero-copy, `-c` force copy, `-o` XDP object path, `-v` verbose libbpf.

## How the code maps to the concepts

| Concept | Where |
|---|---|
| **XDP** | `xsk_redirect_prog`; attached with `bpf_xdp_attach(..., XDP_FLAGS_DRV_MODE)` in `load_and_attach_xdp()` |
| **XSKMAP** | `xsks_map`; one entry per queue via `xsk_socket__update_xskmap()` in `worker_setup()` |
| **libbpf map access** | `qstats` read with `bpf_map_lookup_elem()` in `print_stats()` |
| **UMEM** (per worker) | `posix_memalign` + `xsk_umem__create()` in `worker_setup()` |
| **FILL / COMPLETION** | `refill_fill_ring()` / `complete_tx()` |
| **RX / TX rings** | `process_rx()` |
| **NIC queue** | `workers[i].queue_id`, bound in `xsk_socket__create()` |
| **Threads** | `worker_main()`: pin, then `refill -> poll -> process_rx -> complete_tx` |

## Performance tips (ConnectX-5)

- **Pick CPUs on the NIC's NUMA node**: `cat /sys/class/net/IFACE/device/numa_node`, then `lscpu | grep NUMA`.
- **Match IRQ and thread CPUs.** In zero-copy mode the driver's NAPI work runs on the queue's IRQ CPU. See `grep mlx5_comp /proc/interrupts` and `/proc/irq/<n>/smp_affinity_list`; ideally the app thread for queue *q* shares a core (or a hyperthread sibling) with that IRQ, or use a separate core on the same L3.
- **Scaling is roughly linear only with enough distinct flows.** One flow always maps to one queue.
- **Hugepages** for the UMEM would reduce TLB misses (not used here to keep the code simple).
- Python is a functional test only; use pktgen / TRex / DPDK for real load.

## Troubleshooting

| Symptom | Likely cause / fix |
|---|---|
| Warning: NIC has X queues but -n N | Run `ethtool -L IFACE combined N` (the setup script does it) |
| Some flows time out, others fine | NIC has more queues than sockets: those flows go to `XDP_PASS`. Match `-n` with `ethtool -l` |
| All traffic on one queue | UDP hash is IP-only. Check with `scripts/check_rss.sh IFACE` (while the reflector runs), fix with `ethtool -N IFACE rx-flow-hash udp4 sdfn`, and use several source ports |
| Some queues idle with few flows | Normal for hash-based RSS. Use more flows, or `scripts/steer_flows.sh IFACE N` for a deterministic flow -> queue mapping (needs ntuple support; keep `--base-port/--flows` consistent) |
| `queue K: xsk_socket__create: ...` | Queue K doesn't exist, XDP not attached natively, or memlock/permissions: run as root |
| `AF_XDP mode: COPY` | Kernel fell back; use `-z` to see the real error, check `dmesg`, try `ethtool --set-priv-flags IFACE rx_striding_rq off` |
| `XDP attach (native) failed` | MTU too big for XDP (keep 1500), HW LRO on (`ethtool -K IFACE lro off`), or another XDP program: `ip link set dev IFACE xdp off` |
| Verifier / libbpf errors | Re-run with `-v` |

## Next

Project 3: Rust (aya + xsk-rs). Same concepts, safe abstractions.
