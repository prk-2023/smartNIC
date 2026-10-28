#!/usr/bin/env bash
# steer_flows.sh - FALLBACK: steer flows to queues with explicit ethtool ntuple
#                  rules instead of relying on the RSS hash.
#
# Usage: sudo ./steer_flows.sh <REFLECTOR_IFACE> <NUM_QUEUES> [FLOWS] [BASE_PORT] [DST_PORT]
#   e.g. sudo ./steer_flows.sh enp1s0f0np0 4 64 5000 7777
#
# Installs one rule per test flow:
#     UDP src-port (BASE_PORT + i), dst-port DST_PORT  ->  queue (i % NUM_QUEUES)
#
# This gives a deterministic, predictable spread (flow 0 -> q0, flow 1 -> q1,...)
# and is independent of the Toeplitz hash. It matches scripts/udp_client.py,
# whose flow i uses source port base_port + i. The ports here must match the
# client's --base-port / --flows.
#
# NOTE: if the driver rejects the rules (e.g. "Operation not supported"), stay
# with RSS (see check_rss.sh) - this script is only a plan B.
set -euo pipefail

IF="${1:?usage: $0 <IFACE> <NUM_QUEUES> [FLOWS] [BASE_PORT] [DST_PORT]}"
NQ="${2:?usage: $0 <IFACE> <NUM_QUEUES> [FLOWS] [BASE_PORT] [DST_PORT]}"
FLOWS="${3:-64}"
BASE="${4:-5000}"
DST="${5:-7777}"

if [[ $EUID -ne 0 ]]; then
    echo "run as root (sudo)" >&2
    exit 1
fi

# ntuple filtering is an optional NIC feature and must be enabled first.
ethtool -K "$IF" ntuple on

# Remove any rules from a previous run (locations 0..FLOWS-1), ignore errors.
for ((i = 0; i < FLOWS; i++)); do
    ethtool -N "$IF" delete "$i" 2>/dev/null || true
done

# One rule per flow.  loc = rule slot (lets us delete it later by number).
for ((i = 0; i < FLOWS; i++)); do
    q=$((i % NQ))
    port=$((BASE + i))
    ethtool -N "$IF" flow-type udp4 src-port "$port" dst-port "$DST" \
        action "$q" loc "$i"
done

echo "Installed rules:"
ethtool -n "$IF" | head -60
