# Project 3: Rust (aya + xsk-rs) multi-queue AF_XDP reflector

Same behavior and architecture as Project 2 (reflect UDP port `7777` by swapping MAC / IP / UDP ports in place, one hardware queue + one thread + one AF_XDP socket + one private UMEM each), re-written in Rust:

| | Project 2 (C) | Project 3 (Rust) |
|---|---|---|
| XDP program | `xdp_kern.c` (clang) | `xsk-reflect-ebpf` (**aya-ebpf**, nightly + bpf-linker) |
| Load / attach / maps | libbpf | **aya** |
| UMEM, socket, rings | libxdp (`xsk_*`) | **xsk-rs** (wraps libxdp) |
| Threads | pthreads | `std::thread` |
| Packet rewrite | pointer casts | safe slice code + unit tests |

```
 NIC RSS hash on UDP 4-tuple spreads flows over N queues

   queue 0        queue 1     ...    queue N-1
      |              |                  |
  XDP redirect   XDP redirect       XDP redirect      XSKS_MAP[queue]   (aya)
      |              |                  |
    XSK 0          XSK 1              XSK N-1                           (xsk-rs)
 [UMEM + 4 rings] [UMEM + 4 rings]  [UMEM + 4 rings]
      |              |                  |
   thread 0       thread 1           thread N-1      (pinned with -a)
```

## Layout

| Path | Role |
|---|---|
| `xsk-reflect-common/` | `no_std` crate: `ECHO_UDP_PORT`, `MAX_QUEUES`, `QStat`, shared by kernel and user code |
| `xsk-reflect-ebpf/` | The XDP program in Rust (aya-ebpf): `XSKS_MAP` (XSKMAP) + `QSTATS` (per-CPU per-queue counters). Own workspace, built for `bpfel-unknown-none` |
| `xsk-reflect/src/main.rs` | CLI, aya load/attach, map handling, worker creation, statistics, shutdown |
| `xsk-reflect/src/worker.rs` | One worker: UMEM + socket + rings + the packet loop |
| `xsk-reflect/src/packet.rs` | `reflect_udp()` plus unit tests (no root needed) |
| `xsk-reflect/src/nic.rs` | ethtool queue-count query, zero-copy check (raw libc) |
| `scripts/` | Same as Project 2: `setup_ports.sh`, `teardown_ports.sh`, `udp_client.py`, `check_rss.sh`, `steer_flows.sh` |

## Prerequisites

```bash
# System packages. xsk-rs builds a vendored libxdp (with the cc crate), which needs a C
# compiler; clang is also used for libxdp's small BPF helper.
sudo apt install clang llvm make pkg-config libelf-dev zlib1g-dev ethtool tcpdump python3

# Rust (>= 1.85, xsk-rs 0.8+ uses edition 2024): stable for user space,
# nightly + rust-src + bpf-linker for the eBPF crate
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh
rustup toolchain install nightly --component rust-src
cargo install bpf-linker
```

## Build and run

```bash
make            # = make ebpf + make user
make test       # unit tests for the packet rewrite (no root, no NIC)

# 1) Ports: 4 queues (A = reflector, B = peer in netns)  -- same script as Project 2
sudo ./scripts/setup_ports.sh enp1s0f0np0 enp1s0f1np1 4

# 2) Terminal 1: reflector, 4 queues/threads pinned to CPUs 2..5
sudo ./target/release/xsk-reflect -i enp1s0f0np0 -n 4 -a 2

# 3) Terminal 2: 64 flows from the peer
sudo ip netns exec xsk-peer python3 scripts/udp_client.py --flows 64 --count 200

# Cleanup
sudo ./scripts/teardown_ports.sh enp1s0f0np0 enp1s0f1np1
```

Output is identical to Project 2 (per-queue table with `xdp seen/s`, `AF_XDP rx/s`, `tx/s`). Options: `-n/--queues`, `-a/--first-cpu`, `-z/--zero-copy`, `-c/--copy`, `-o/--bpf-obj`, `--frames`. Set `RUST_LOG=debug` to see aya's log output.

### Fallback: reuse Project 2's C XDP object

If you only want to try the Rust user space first (or the nightly/bpf-linker setup is a hassle), skip `make ebpf` and point the loader at Project 2's compiled object. Its names differ, so pass them:

```bash
sudo ./target/release/xsk-reflect -i enp1s0f0np0 -n 4 \
  -o ../project2-xsk-multiqueue/xdp_kern.o \
  --prog xsk_redirect_prog --xsks-map xsks_map --qstats-map qstats
```

(`QStat` is two `u64`s, same layout as the C `struct qstat`; the loader accepts both the C `ARRAY` map and the Rust `PERCPU_ARRAY` map.)

## How the code maps to the concepts

| Concept | Where |
|---|---|
| **XDP program** | `xsk_redirect` in `xsk-reflect-ebpf/src/main.rs`; attached with `Xdp::attach(iface, XdpFlags::DRV_MODE)` in `main()` |
| **XSKMAP** | `XSKS_MAP` (eBPF); filled by `XskMap::set(queue, fd, 0)` in `main()` |
| **Reading an eBPF map** | `QSTATS` (PERCPU_ARRAY) read with `PerCpuArray::get()` and summed over CPUs in `QStats::pkts()` |
| **UMEM** (per worker) | `Umem::new(..)` in `Worker::new()` |
| **XSK + RX/TX rings** | `Socket::new(..)` in `Worker::new()` |
| **FILL ring** | `Worker::refill()` (`FillQueue::produce`) |
| **RX ring** | `RxQueue::poll_and_consume` in `Worker::run()` |
| **TX ring** | `Worker::process_batch()` (`TxQueue::produce_and_wakeup`) |
| **COMPLETION ring** | `Worker::reap_completions()` (`CompQueue::consume`) |
| **NIC queue** | `queue_id` given to `Socket::new`; must match the XSKMAP key |

## Rust-specific design notes

- **Where the `unsafe` is, and why.** Every ring operation in xsk-rs is `unsafe`: the compiler cannot know whether the kernel or us owns a frame. The invariant we uphold is the frame life-cycle: a `FrameDesc` is either in `Worker::free` or in exactly one ring. Each `unsafe` block carries a `SAFETY:` comment saying which part of that invariant it relies on. Everything else (packet parsing, stats, CLI) is safe code.
- **Share-nothing by ownership.** `Worker::spawn(self, ..)` *moves* the whole worker (UMEM, rings, free list) into its thread, so another thread cannot touch them. The only shared data is `Arc<WorkerStats>` (relaxed atomics, 64-byte aligned to avoid false sharing).
- **Drop order matters.** `Worker` declares `umem` last so the socket and rings are released before the UMEM.
- **No `libxdp` program loading.** `XSK_LIBXDP_FLAGS_INHIBIT_PROG_LOAD` is set, so xsk-rs/libxdp never installs its default XDP program; aya owns the program and the XSKMAP.
- **Per-CPU counters instead of atomics.** The eBPF target has no atomic read-modify-write in Rust (`AtomicU64::fetch_add` does not exist there), so `QSTATS` is a `PerCpuArray`: each CPU increments its own copy with a plain add and user space sums the copies. This is also faster, since CPUs never share a cache line.
- **eBPF code reads raw bytes** (`[u8; N]`, alignment 1) instead of casting to header structs, so reads are valid wherever the driver put the frame, and every access goes through one bounds-checking helper (`ptr_at`) that the verifier can follow.
- **No memcmp in eBPF.** Header fields are compared as integers, not as byte arrays, because array equality can compile to a `memcmp` call that eBPF cannot link.
- **Cleanup:** the XDP link is detached explicitly after the worker threads exit; dropping `Ebpf` would also do it.

## Version pins

`aya 0.13`, `aya-ebpf 0.1`, `xsk-rs 0.11` with the `use_cc_build` feature (see `Cargo.lock`). Newer major versions exist and have different APIs; upgrade them deliberately, and keep `aya` and `aya-ebpf` on matching generations.

## What was and was not verified

Checked while writing this (Rust 1.91, Linux sandbox without a NIC):
- the user-space workspace builds in release mode without warnings;
- the 5 unit tests in `packet.rs` pass (swap correctness, IP options, IP checksum unchanged, involution, rejection of non-UDP/ARP/truncated frames);
- the eBPF crate compiles for the real `bpfel-unknown-none` target up to the link step. The emitted LLVM IR contains only the two expected helper calls (`bpf_map_lookup_elem`, `bpf_redirect_map`), no `memcmp`/`memcpy`/atomics/panic paths, the maps come out as `PERCPU_ARRAY` and `XSKMAP`, and the program is in the `xdp` section. (A first version used `AtomicU64::fetch_add`, which only fails on the BPF target; fixed with per-CPU counters.)

**Not** checked, because it needs your environment: the final link with `bpf-linker`, acceptance by the kernel verifier, and everything at runtime on the ConnectX-5 (native XDP attach, zero-copy, RSS spread). If the eBPF build or verifier gives you trouble, use the C-object fallback above to separate user-space problems from eBPF problems, and send me the error.

## Troubleshooting

| Symptom | Likely cause / fix |
|---|---|
| `cargo build` fails in `libxdp-sys` (`Cannot find tool llc`, `configure`, read-only build dir) | Use `xsk-rs = { version = "0.11", default-features = false, features = ["use_cc_build"] }` (already set in `xsk-reflect/Cargo.toml`) |
| `Error: invalid map type 6` (or another number) at startup | The user-space binary and the eBPF object are out of sync: a PERCPU_ARRAY (type 6) map was opened as a plain `Array`. Rebuild BOTH (`make clean && make`); the loader here handles ARRAY and PERCPU_ARRAY and names the map in the error |
| `make ebpf`: `bpf-linker` not found / `can't find crate for core` | `cargo install bpf-linker`; `rustup toolchain install nightly --component rust-src` |
| `loading eBPF object ... No such file` | Run `make ebpf`, and run the binary from the project root (or pass `-o`) |
| `loading XDP program (verifier error?)` | Run with `RUST_LOG=debug` to see the verifier log; try the C-object fallback |
| `attaching XDP in native mode` fails | MTU too large for XDP (keep 1500), HW LRO on (`ethtool -K IFACE lro off`), or another XDP program: `ip link set dev IFACE xdp off` |
| `queue K: ... creating AF_XDP socket` | Queue K doesn't exist (`ethtool -L IFACE combined N`), or not running as root |
| Mode shows `COPY` | Kernel fell back; use `-z` to see the real error, check `dmesg`, try `ethtool --set-priv-flags IFACE rx_striding_rq off` |
| Warning: NIC has X queues but --queues N | Run `ethtool -L IFACE combined N` (the setup script does it) |
| Few queues busy / flows not spreading | RSS is statistical: use many flows; see `scripts/check_rss.sh` and Project 2's README |
