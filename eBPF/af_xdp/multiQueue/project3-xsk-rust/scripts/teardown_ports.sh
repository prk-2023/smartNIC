#!/usr/bin/env bash
# teardown_ports.sh - undo setup_ports.sh
#
# Usage: sudo ./teardown_ports.sh <REFLECTOR_IFACE> <PEER_IFACE>
set -euo pipefail

A="${1:?usage: $0 <REFLECTOR_IFACE> <PEER_IFACE>}"
B="${2:?usage: $0 <REFLECTOR_IFACE> <PEER_IFACE>}"
NS="xsk-peer"

if [[ $EUID -ne 0 ]]; then
    echo "run as root (sudo)" >&2
    exit 1
fi

# Make sure no XDP program is left on the reflector port.
ip link set dev "$A" xdp off 2>/dev/null || true

# Move the peer port back to the root namespace (PID 1's namespace), then
# delete the now-empty namespace.
if ip netns list | grep -qw "$NS"; then
    ip netns exec "$NS" ip addr flush dev "$B" 2>/dev/null || true
    ip netns exec "$NS" ip link set "$B" netns 1 2>/dev/null || true
    ip netns del "$NS"
fi

ip addr flush dev "$A" || true

# Restore the NIC's maximum queue count (best effort) and reset RSS to default.
MAXQ=$(ethtool -l "$A" 2>/dev/null | awk '/Pre-set maximums/{f=1} f&&/Combined/{print $2; exit}')
[[ -n "${MAXQ:-}" ]] && ethtool -L "$A" combined "$MAXQ" || true
ethtool -X "$A" default 2>/dev/null || true

echo "Teardown done."
