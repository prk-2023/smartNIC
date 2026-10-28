#!/usr/bin/env bash
# check_rss.sh - show how the NIC spreads received packets over RX queues.
#
# Usage: sudo ./check_rss.sh <REFLECTOR_IFACE>
#
# Run it WHILE the reflector is running (attaching XDP / opening AF_XDP
# sockets makes the mlx5 driver reconfigure its channels, so this shows the
# settings that are actually in effect during the test).
set -uo pipefail

IF="${1:?usage: $0 <REFLECTOR_IFACE>}"

echo "=== 1. Queues (want Combined current == the -n you pass to xsk-reflect) ==="
ethtool -l "$IF" | sed -n '/Current hardware settings/,$p'

echo
echo "=== 2. UDP4 hash fields ==="
echo "Need: IP SA, IP DA, L4 bytes 0&1 (src port), L4 bytes 2&3 (dst port)."
echo "If only IP SA / IP DA are listed, flows that differ only in UDP port all"
echo "land on ONE queue. Fix:  sudo ethtool -N $IF rx-flow-hash udp4 sdfn"
ethtool -n "$IF" rx-flow-hash udp4

echo
echo "=== 3. RSS indirection table and hash function ==="
echo "The table should reference queues 0..N-1, not just one."
ethtool -x "$IF" | head -20

echo
echo "=== 4. ntuple steering rules currently installed (if any) ==="
ethtool -n "$IF" | head -30

echo
echo "=== 5. Per-queue RX counters as counted by the NIC/driver ==="
echo "Send traffic, run this again, and see which rxN counters grow."
ethtool -S "$IF" | grep -E '(^|[[:space:]])rx[0-9]+_(packets|xdp_redirect)|rx_xsk_packets' || \
    echo "(no per-queue counters matched; try: ethtool -S $IF | grep -i rx)"
