#!/usr/bin/env bash
# setup_ports.sh - prepare a dual-port ConnectX-5 (DAC looped between ports)
#                  for the MULTI-QUEUE AF_XDP reflector.
#
# Usage: sudo ./setup_ports.sh <REFLECTOR_IFACE> <PEER_IFACE> <NUM_QUEUES>
#   e.g. sudo ./setup_ports.sh enp1s0f0np0 enp1s0f1np1 4
#
# Topology (same idea as Project 1):
#
#       root namespace                     netns "xsk-peer"
#   +-----------------------+           +---------------------+
#   | REFLECTOR_IFACE       |<== DAC ==>| PEER_IFACE          |
#   | 10.10.0.1/24          |           | 10.10.0.2/24        |
#   | N queues, XDP+AF_XDP  |           | udp_client.py       |
#   +-----------------------+           +---------------------+
#
# The peer port lives in its own namespace so traffic really crosses the DAC
# instead of being short-circuited over the loopback device.
#
# What is NEW compared with Project 1:
#   * N combined queues instead of 1                    (ethtool -L)
#   * UDP RSS hashing over the 4-tuple, so different
#     source ports land on different queues              (ethtool -N)
#   * Even indirection table across the N queues         (ethtool -X)
set -euo pipefail

A="${1:?usage: $0 <REFLECTOR_IFACE> <PEER_IFACE> <NUM_QUEUES>}"
B="${2:?usage: $0 <REFLECTOR_IFACE> <PEER_IFACE> <NUM_QUEUES>}"
N="${3:?usage: $0 <REFLECTOR_IFACE> <PEER_IFACE> <NUM_QUEUES>}"
NS="xsk-peer"

if [[ $EUID -ne 0 ]]; then
    echo "run as root (sudo)" >&2
    exit 1
fi

# ---- Reflector side (root namespace) ---------------------------------------
# N combined RX/TX queue pairs. The reflector program must be started with the
# SAME number (-n N): flows hashed to a queue without a socket would fall back
# to the kernel stack and never be reflected.
# (mlx5 resets the link when the channel count changes, hence the sleep below.)
ethtool -L "$A" combined "$N"

# By default many NICs hash UDP on the 2-tuple (src/dst IP) only. Then every
# flow between two fixed IPs lands on ONE queue. Hash on IPs + ports (sdfn)
# so flows with different UDP source ports spread over the queues.
ethtool -N "$A" rx-flow-hash udp4 sdfn \
    || echo "WARNING: could not set udp4 flow hash; flows may not spread" >&2

# Read the setting BACK: a driver can accept the command and still keep the old
# value. If ports are not part of the hash, every flow between the two fixed
# IPs lands on ONE queue (the symptom: a single busy row in the stats table).
if ethtool -n "$A" rx-flow-hash udp4 | grep -q "L4 bytes"; then
    echo "OK: UDP4 RSS hash includes the UDP ports"
else
    echo "WARNING: UDP4 RSS hash does NOT include ports -> all flows hit one queue." >&2
    echo "         Diagnose: scripts/check_rss.sh $A" >&2
    echo "         Fallback: scripts/steer_flows.sh $A $N   (explicit ntuple steering)" >&2
fi

# Spread the RSS indirection table evenly over queues 0..N-1.
ethtool -X "$A" equal "$N" \
    || echo "WARNING: could not set RSS indirection table" >&2

ip addr flush dev "$A"
ip addr add 10.10.0.1/24 dev "$A"
ip link set "$A" up

# ---- Peer side (namespace) ---------------------------------------------------
ip netns list | grep -qw "$NS" || ip netns add "$NS"
ip link set "$B" netns "$NS"
ip netns exec "$NS" ip link set lo up
ip netns exec "$NS" ip addr flush dev "$B"
ip netns exec "$NS" ip addr add 10.10.0.2/24 dev "$B"
ip netns exec "$NS" ip link set "$B" up

sleep 3   # let the links come up after the reconfiguration

echo "--- queues on $A ---"
ethtool -l "$A" | sed -n '/Current hardware settings/,$p'
echo "--- UDP4 hash fields (want: IP SA, IP DA, L4 bytes 0-3, 2-3) ---"
ethtool -n "$A" rx-flow-hash udp4 || true

echo "--- link state (expect 'Link detected: yes') ---"
ethtool "$A" | grep -E "Speed|Link detected" || true
ip netns exec "$NS" ethtool "$B" | grep -E "Speed|Link detected" || true

echo "--- sanity ping through the wire (kernel stack) ---"
ip netns exec "$NS" ping -c 2 -W 1 10.10.0.1 || echo "ping failed: check DAC / link"

echo "Ready. Reflector: $A (10.10.0.1, $N queues)   Peer: $B (10.10.0.2) in netns $NS"
echo "Start:  sudo ./xsk_reflect_mq -i $A -n $N"
