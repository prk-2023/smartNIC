#!/usr/bin/env bash

# ============================================================
# SR-IOV SWITCHDEV VF-TO-VF BARE-METAL THROUGHPUT TEST
#
#                 NVIDIA GB10 (SWITCHDEV MODE)
#
#       PF0 (enp1s0f0np0)             PF1 (enP2p1s0f1np1)
#            |                             |
#     +------+------+               +------+------+
#     |             |               |             |
#   VF 0          REP 0           REP 0          VF 0
# enp1s0f0v0   enp1s0f0r0     enP2p1s0f1r0   enP2p1s0f1v0
#     |             |               |             |
#  left-ns          +--- OVS BRIDGE +          right-ns
# 10.0.0.1           (HW-Offloaded)            10.0.0.2
# ============================================================

set -u
set -o pipefail

# ============================================================
# Configuration
# ============================================================

# Physical Functions
LEFT_PF="enp1s0f0np0"
RIGHT_PF="enP2p1s0f1np1"

# Virtual Functions (Assigned to Network Namespaces)
LEFT_VF="enp1s0f0v0"
RIGHT_VF="enP2p1s0f1v0"

# VF Representors (Managed in Host Root NS by OVS)
LEFT_REP="enp1s0f0r0"
RIGHT_REP="enP2p1s0f1r0"

# OVS Bridge Name
OVS_BR="br-sriov-ns"

# VF indexes on the PFs
LEFT_VF_INDEX=0
RIGHT_VF_INDEX=0

AUTO_CREATE_VFS=1
REMOVE_SCRIPT_CREATED_VFS=1

# Network namespaces
LEFT_NS="left-vf-ns"
RIGHT_NS="right-vf-ns"

# Test IP addresses
LEFT_IP="10.0.0.1"
RIGHT_IP="10.0.0.2"
PREFIX="24"

# MTU & Benchmarks
MTU_VAL=9000
PING_COUNT=3
PING_TIMEOUT=1
IPERF_DURATION=60
IPERF_TCP_STREAMS=4
IPERF_UDP_BANDWIDTH="50G"
IPERF_UDP_LENGTH=8948
IPERF_UDP_STREAMS=1

RESULTS_DIR="./results"
SUMMARY_FILE="${RESULTS_DIR}/vf-summary.json"
STATE_FILE="/run/sriov-vf-baremetal-topology.state"
IPERF_SERVER_LOG="/tmp/iperf3-vf-server.log"

# Colors & Logging
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

log_info()  { echo -e "${BLUE}[INFO]${NC} $*"; }
log_ok()    { echo -e "${GREEN}[ OK ]${NC} $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }
pause_screen() { echo; read -r -p "Press ENTER to continue..."; }

require_root() {
    if [[ "${EUID}" -ne 0 ]]; then
        log_error "This script must be run as root."
        exit 1
    fi
}

check_dependencies() {
    local missing=()
    command -v ip >/dev/null 2>&1 || missing+=("ip")
    command -v ping >/dev/null 2>&1 || missing+=("ping")
    command -v iperf3 >/dev/null 2>&1 || missing+=("iperf3")
    command -v jq >/dev/null 2>&1 || missing+=("jq")
    command -v ovs-vsctl >/dev/null 2>&1 || missing+=("ovs-vsctl")

    if [[ ${#missing[@]} -gt 0 ]]; then
        log_error "Missing required commands: ${missing[*]}"
        exit 1
    fi
}

interface_exists() { ip link show "$1" >/dev/null 2>&1; }
namespace_exists() { ip netns list | awk '{print $1}' | grep -qx "$1"; }
interface_exists_in_ns() { ip netns exec "$1" ip link show "$2" >/dev/null 2>&1; }

set_setup_flag() {
    cat > "${STATE_FILE}" <<EOF
SETUP_COMPLETE=1
LEFT_PF=${LEFT_PF}
RIGHT_PF=${RIGHT_PF}
LEFT_VF=${LEFT_VF}
RIGHT_VF=${RIGHT_VF}
EOF
}

clear_setup_flag() { rm -f "${STATE_FILE}"; }
is_setup() { [[ -f "${STATE_FILE}" ]] && grep -q '^SETUP_COMPLETE=1$' "${STATE_FILE}"; }

require_setup() {
    if ! is_setup; then
        log_error "VF topology is not configured. Run Setup first."
        return 1
    fi
    return 0
}

# ============================================================
# Switchdev Mode & OVS Setup Helpers
# ============================================================

enable_one_vf() {
    local pf="$1"
    ip link set "${pf}" mtu "${MTU_VAL}"

    local sriov_file="/sys/class/net/${pf}/device/sriov_numvfs"
    local current
    current="$(cat "${sriov_file}")"

    if [[ "${current}" -ge 1 ]]; then
        log_ok "${pf} already has ${current} VF(s)"
        return 0
    fi

    log_info "Creating one VF on ${pf}..."
    echo 1 > "${sriov_file}"
    sleep 2
    log_ok "Created VF 0 on ${pf}"
    return 0
}

wait_for_interfaces() {
    local timeout=10
    log_info "Waiting for VFs and Representors..."
    while [[ "${timeout}" -gt 0 ]]; do
        if interface_exists "${LEFT_VF}" && interface_exists "${RIGHT_VF}" && \
           interface_exists "${LEFT_REP}" && interface_exists "${RIGHT_REP}"; then
            log_ok "All VFs (${LEFT_VF}, ${RIGHT_VF}) and Representors (${LEFT_REP}, ${RIGHT_REP}) detected."
            return 0
        fi
        sleep 1
        timeout=$((timeout - 1))
    done
    log_error "Timeout waiting for interfaces!"
    return 1
}

setup_ovs_switchdev() {
    log_info "Configuring Open vSwitch Hardware Offload..."
    
    # Ensure OVS hw-offload is active
    ovs-vsctl set Open_vSwitch . other_config:hw-offload=true

    # Create OVS Bridge
    if ! ovs-vsctl br-exists "${OVS_BR}"; then
        ovs-vsctl add-br "${OVS_BR}"
    fi

    # Attach Representor ports
    log_info "Adding VF representors to ${OVS_BR}..."
    ovs-vsctl --may-exist add-port "${OVS_BR}" "${LEFT_REP}"
    ovs-vsctl --may-exist add-port "${OVS_BR}" "${RIGHT_REP}"

    # Bring up physical, representor, and bridge links
    ip link set dev "${LEFT_PF}" up mtu "${MTU_VAL}"
    ip link set dev "${RIGHT_PF}" up mtu "${MTU_VAL}"
    ip link set dev "${LEFT_REP}" up mtu "${MTU_VAL}"
    ip link set dev "${RIGHT_REP}" up mtu "${MTU_VAL}"
    ip link set dev "${OVS_BR}" up mtu "${MTU_VAL}"

    log_ok "OVS Switchdev integration complete."
}

# ============================================================
# Reset & Setup Topology
# ============================================================

reset_topology() {
    echo
    log_info "Resetting SR-IOV Switchdev Topology..."
    clear_setup_flag

    pkill -x iperf3 2>/dev/null || true

    # Return VFs from namespaces
    for item in "${LEFT_NS}:${LEFT_VF}" "${RIGHT_NS}:${RIGHT_VF}"; do
        IFS=":" read -r ns dev <<< "${item}"
        if namespace_exists "${ns}" && interface_exists_in_ns "${ns}" "${dev}"; then
            ip netns exec "${ns}" ip link set "${dev}" netns 1 2>/dev/null || true
        fi
    done

    # Cleanup OVS bridge
    if ovs-vsctl br-exists "${OVS_BR}"; then
        log_info "Tearing down OVS bridge ${OVS_BR}..."
        ovs-vsctl del-br "${OVS_BR}" 2>/dev/null || true
    fi

    # Delete namespaces
    for ns in "${LEFT_NS}" "${RIGHT_NS}"; do
        if namespace_exists "${ns}"; then
            ip netns delete "${ns}" 2>/dev/null || true
            log_ok "Deleted namespace ${ns}"
        fi
    done

    # Remove VFs
    if [[ "${REMOVE_SCRIPT_CREATED_VFS}" -eq 1 ]]; then
        for pf in "${LEFT_PF}" "${RIGHT_PF}"; do
            if interface_exists "${pf}"; then
                local sriov_file="/sys/class/net/${pf}/device/sriov_numvfs"
                if [[ -e "${sriov_file}" && "$(cat "${sriov_file}")" -gt 0 ]]; then
                    echo 0 > "${sriov_file}" 2>/dev/null || true
                fi
            fi
        done
    fi

    log_ok "Topology cleared."
}

create_topology() {
    echo
    log_info "Creating SR-IOV Switchdev VF Topology..."
    reset_topology

    if [[ "${AUTO_CREATE_VFS}" -eq 1 ]]; then
        enable_one_vf "${LEFT_PF}" || return 1
        enable_one_vf "${RIGHT_PF}" || return 1
    fi

    wait_for_interfaces || return 1

    # Wire representors in Host root NS
    setup_ovs_switchdev || return 1

    # Create Namespaces
    ip netns add "${LEFT_NS}" || return 1
    ip netns add "${RIGHT_NS}" || return 1

    # Move VFs to Namespaces
    log_info "Moving ${LEFT_VF} into ${LEFT_NS}..."
    ip link set "${LEFT_VF}" netns "${LEFT_NS}" || return 1

    log_info "Moving ${RIGHT_VF} into ${RIGHT_NS}..."
    ip link set "${RIGHT_VF}" netns "${RIGHT_NS}" || return 1

    # Configure Left VF
    ip netns exec "${LEFT_NS}" ip link set "${LEFT_VF}" mtu "${MTU_VAL}"
    ip netns exec "${LEFT_NS}" ip addr add "${LEFT_IP}/${PREFIX}" dev "${LEFT_VF}"
    ip netns exec "${LEFT_NS}" ip link set "${LEFT_VF}" up
    ip netns exec "${LEFT_NS}" ip link set lo up

    # Configure Right VF
    ip netns exec "${RIGHT_NS}" ip link set "${RIGHT_VF}" mtu "${MTU_VAL}"
    ip netns exec "${RIGHT_NS}" ip addr add "${RIGHT_IP}/${PREFIX}" dev "${RIGHT_VF}"
    ip netns exec "${RIGHT_NS}" ip link set "${RIGHT_VF}" up
    ip netns exec "${RIGHT_NS}" ip link set lo up

    sleep 2
    set_setup_flag
    log_ok "SR-IOV Switchdev topology successfully set up."
    return 0
}

# ============================================================
# Benchmarks
# ============================================================

perform_ping_test() {
    require_setup || return 1
    log_info "Testing Bidirectional Ping..."
    
    ip netns exec "${LEFT_NS}" ping -c "${PING_COUNT}" -W "${PING_TIMEOUT}" "${RIGHT_IP}" && \
    ip netns exec "${RIGHT_NS}" ping -c "${PING_COUNT}" -W "${PING_TIMEOUT}" "${LEFT_IP}"

    if [[ $? -eq 0 ]]; then
        log_ok "BIDIRECTIONAL SWITCHDEV PING PASSED"
    else
        log_error "PING FAILED"
    fi
}

start_iperf_server() {
    ip netns exec "${RIGHT_NS}" iperf3 -s > "${IPERF_SERVER_LOG}" 2>&1 &
    IPERF_SERVER_PID=$!
    sleep 1
}

stop_iperf_server() {
    [[ -n "${IPERF_SERVER_PID:-}" ]] && kill "${IPERF_SERVER_PID}" 2>/dev/null || true
    ip netns exec "${RIGHT_NS}" pkill -x iperf3 2>/dev/null || true
}

perform_throughput_test() {
    require_setup || return 1
    mkdir -p "${RESULTS_DIR}"
    
    start_iperf_server
    trap stop_iperf_server RETURN

    log_info "Running TCP Throughput test (${IPERF_DURATION}s)..."
    local tcp_json="${RESULTS_DIR}/tcp.json"
    ip netns exec "${LEFT_NS}" iperf3 -c "${RIGHT_IP}" -t "${IPERF_DURATION}" -P "${IPERF_TCP_STREAMS}" -J > "${tcp_json}"

    local tcp_bps
    tcp_bps="$(jq -r '.end.sum_received.bits_per_second // 0' "${tcp_json}")"
    local tcp_gbps
    tcp_gbps="$(awk -v bps="${tcp_bps}" 'BEGIN { printf "%.2f", bps/1e9 }')"

    log_ok "Switchdev Offloaded TCP Throughput: ${tcp_gbps} Gbps"
}

# ============================================================
# Main Entry Point
# ============================================================

main() {
    require_root
    check_dependencies

    echo "============================================================"
    echo "    SR-IOV SWITCHDEV BARE-METAL TEST (OVS OFFLOADED)"
    echo "============================================================"
    echo "  1) Setup Topology"
    echo "  2) Reset Topology"
    echo "  3) Ping Test"
    echo "  4) Run Throughput Test"
    echo "  5) Quit"
    echo "============================================================"

    read -r -p "Select option [1-5]: " choice
    case "${choice}" in
        1) create_topology ;;
        2) reset_topology ;;
        3) perform_ping_test ;;
        4) perform_throughput_test ;;
        5) exit 0 ;;
        *) log_error "Invalid choice" ;;
    esac
}

main "$@"
