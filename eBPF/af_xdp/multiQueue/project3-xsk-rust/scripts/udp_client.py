#!/usr/bin/env python3
"""
udp_client.py - multi-flow test client for the multi-queue AF_XDP reflector.

Run it INSIDE the peer namespace so packets really cross the DAC:

    sudo ip netns exec xsk-peer python3 scripts/udp_client.py --flows 64 --count 200

Why several flows?
------------------
The NIC picks an RX queue by hashing the packet's 4-tuple (src/dst IP + UDP
ports). One flow = one hash = ONE queue, so a single flow can never exercise
more than one worker thread. Here every flow uses a different UDP SOURCE port
(base_port + i), so the flows spread across the queues.

What is checked
---------------
Each flow sends UDP packets  10.10.0.2:<port_i> -> 10.10.0.1:7777.
The reflector swaps MAC/IP/ports and sends the same frame back, so the reply
arrives at the socket bound to <port_i> from 10.10.0.1:7777 with an identical
payload. Payloads carry (flow, sequence) so mix-ups are detected.

Python is slow (~100-200 kpps at best): this is a FUNCTIONAL test that shows
the queue spreading. Use a real generator (pktgen, TRex, DPDK) for benchmarks.
"""
import argparse
import select
import socket
import time


def make_payload(flow: int, seq: int, size: int) -> bytes:
    """Unique, verifiable payload: 'xsk-f003-s00000012' padded with dots."""
    return f"xsk-f{flow:03d}-s{seq:08d}".encode().ljust(size, b".")


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--src-ip", default="10.10.0.2")       # peer address
    p.add_argument("--base-port", type=int, default=5000)  # flow i uses base+i
    p.add_argument("--dst-ip", default="10.10.0.1")       # reflector address
    p.add_argument("--dst-port", type=int, default=7777)  # must match common.h
    p.add_argument("--flows", type=int, default=64,
                   help="number of UDP flows (RSS balances statistically: use many)")
    p.add_argument("--count", type=int, default=100, help="packets per flow")
    p.add_argument("--burst", type=int, default=32,
                   help="packets per flow sent before draining replies")
    p.add_argument("--size", type=int, default=64, help="UDP payload bytes")
    p.add_argument("--timeout", type=float, default=1.0,
                   help="seconds to wait for the replies of one burst")
    args = p.parse_args()

    # One socket per flow, each with a distinct source port -> distinct hash.
    socks = []
    for i in range(args.flows):
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.bind((args.src_ip, args.base_port + i))
        s.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 4 * 1024 * 1024)
        s.setblocking(False)
        socks.append(s)
    index_of = {s: i for i, s in enumerate(socks)}   # socket -> flow number

    sent = [0] * args.flows
    recv = [0] * args.flows
    bad = 0
    dst = (args.dst_ip, args.dst_port)
    t_start = time.perf_counter()

    # Work in bursts: send `burst` packets on every flow, then drain replies.
    # This avoids overflowing socket buffers while still keeping many packets
    # in flight across all queues at once.
    for first in range(0, args.count, args.burst):
        n = min(args.burst, args.count - first)

        for seq in range(first, first + n):
            for fi, s in enumerate(socks):
                s.sendto(make_payload(fi, seq, args.size), dst)
                sent[fi] += 1

        expected = n * args.flows
        got = 0
        deadline = time.monotonic() + args.timeout
        while got < expected:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                break                                  # some replies lost
            ready, _, _ = select.select(socks, [], [], remaining)
            for s in ready:
                fi = index_of[s]
                try:
                    while True:                        # drain this socket
                        data, addr = s.recvfrom(2048)
                        # Reply must look like it came from the reflector and
                        # must carry THIS flow's tag.
                        if addr == dst and data.startswith(f"xsk-f{fi:03d}-".encode()):
                            recv[fi] += 1
                        else:
                            bad += 1
                        got += 1
                except BlockingIOError:
                    pass

    elapsed = time.perf_counter() - t_start
    total_sent, total_recv = sum(sent), sum(recv)

    print(f"flows={args.flows} packets/flow={args.count} size={args.size}B")
    for fi in range(args.flows):
        flag = "" if recv[fi] == sent[fi] else "   <-- loss"
        print(f"  flow {fi:3d} (sport {args.base_port + fi}): "
              f"sent={sent[fi]} reflected={recv[fi]}{flag}")
    print(f"\n{total_recv}/{total_sent} reflected, {bad} unexpected, "
          f"{elapsed:.2f}s, ~{total_recv / elapsed:.0f} pps round-trip")
    print("Now look at the reflector's per-queue table: the flows should be "
          "spread over the queues.")
    return 0 if (total_recv == total_sent and bad == 0) else 1


if __name__ == "__main__":
    raise SystemExit(main())
