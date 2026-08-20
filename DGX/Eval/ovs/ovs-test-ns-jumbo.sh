#!/usr/bin/env bash

# ============================================================
# OVS DAC CROSSOVER TEST
#
#                         DAC crossover
#                  +-----------------------+
#                  |                       |
#            enp1s0f0np0               enp1s0f1np1
#                  |                       |
#             +----+----+             +----+----+
#             | br-left |             |br-right |
#             |   OVS   |             |   OVS   |
#             +----+----+             +----+----+
#                  |                       |
#             veth-left                veth-right
#                  |                       |
#             +----+-----+           +-----+----+
#             |  left-ns |           | right-ns |
#             |          |           |          |
#             |10.0.0.1  |           |10.0.0.2  |
#             +----------+           +----------+
#
# The ping endpoints are in separate network namespaces.
# Therefore traffic MUST traverse the physical DAC.
#
# ============================================================

set -u

# ============================================================
# Configuration
# ============================================================

# Physical NICs
LEFT_IF="enp1s0f0np0"
RIGHT_IF="enp1s0f1np1"

# OVS bridges
LEFT_BR="br-left"
RIGHT_BR="br-right"

# Network namespaces
LEFT_NS="left-ns"
RIGHT_NS="right-ns"

# Veth interfaces
# Namespace side
LEFT_VETH_NS="left-veth"
RIGHT_VETH_NS="right-veth"

# OVS/root side
LEFT_VETH_OVS="left-veth-ovs"
RIGHT_VETH_OVS="right-veth-ovs"

# Test IP addresses
LEFT_IP="10.0.0.1"
RIGHT_IP="10.0.0.2"
PREFIX="24"

# Ping parameters
PING_COUNT=10
PING_TIMEOUT=1

# Persistent state flag
STATE_FILE="/run/ovs-dac-topology.state"

# ============================================================
# Throughput test configuration
# ============================================================

# iperf3 test duration
IPERF_DURATION=10

# Number of parallel TCP streams
IPERF_TCP_STREAMS=4

# UDP target bandwidth
#
# "0" means use iperf3's default UDP bandwidth.
# For a 25G/100G comparison, you may want to set this explicitly,
# for example:
#
#   20G
#   25G
#   50G
#   100G
#
# NOTE: This MUST include a unit suffix (e.g. "G" for Gbits/sec).
# A bare number like "40" is interpreted by iperf3 as 40 bits/sec,
# which will throttle the UDP stream to almost nothing.
#IPERF_UDP_BANDWIDTH="0G"
IPERF_UDP_BANDWIDTH="50G"

# UDP packet length.
#
# 1472 is appropriate for a normal 1500-byte MTU IPv4 path.
# For jumbo frames, use something such as 8972.
#
### IPERF_UDP_LENGTH=1472
#IPERF_UDP_LENGTH=8972 
IPERF_UDP_LENGTH=8948

# Number of UDP test streams
IPERF_UDP_STREAMS=1

# Output directory
RESULTS_DIR="./results"

# Summary file
SUMMARY_FILE="${RESULTS_DIR}/summary.json"

# ============================================================
# Colors
# ============================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# ============================================================
# Logging
# ============================================================

log_info()
{
    echo -e "${BLUE}[INFO]${NC} $*"
}

log_ok()
{
    echo -e "${GREEN}[ OK ]${NC} $*"
}

log_warn()
{
    echo -e "${YELLOW}[WARN]${NC} $*"
}

log_error()
{
    echo -e "${RED}[ERROR]${NC} $*"
}

pause_screen()
{
    echo
    read -r -p "Press ENTER to continue..."
}

# ============================================================
# Root / dependency checks
# ============================================================

require_root()
{
    if [[ "${EUID}" -ne 0 ]]; then
        log_error "This script must be run as root."
        echo "Example:"
        echo "  sudo $0"
        exit 1
    fi
}

check_dependencies()
{
    local missing=()

    command -v ovs-vsctl >/dev/null 2>&1 || missing+=("ovs-vsctl")
    command -v ovs-ofctl >/dev/null 2>&1 || missing+=("ovs-ofctl")
    command -v ovs-appctl >/dev/null 2>&1 || missing+=("ovs-appctl")
    command -v ip >/dev/null 2>&1 || missing+=("ip")
    command -v ping >/dev/null 2>&1 || missing+=("ping")
    command -v iperf3 >/dev/null 2>&1 || missing+=("iperf3")
    command -v jq >/dev/null 2>&1 || missing+=("jq")

    if [[ ${#missing[@]} -gt 0 ]]; then
        log_error "Missing required commands:"
        printf '  %s\n' "${missing[@]}"
        echo
        echo "Fedora:"
        echo "  sudo dnf install iperf3 jq"
        exit 1
    fi
}

# ============================================================
# State management
# ============================================================

set_setup_flag()
{
    echo "SETUP_COMPLETE=1" > "${STATE_FILE}"
}

clear_setup_flag()
{
    rm -f "${STATE_FILE}"
}

is_setup()
{
    [[ -f "${STATE_FILE}" ]] &&
        grep -q '^SETUP_COMPLETE=1$' "${STATE_FILE}"
}

require_setup()
{
    if ! is_setup; then
        log_error "Topology is not marked as configured."
        echo "Please run Setup first."
        return 1
    fi

    return 0
}

# ============================================================
# Interface existence
# ============================================================

interface_exists()
{
    ip link show "$1" >/dev/null 2>&1
}

namespace_exists()
{
    ip netns list | awk '{print $1}' | grep -qx "$1"
}

# ============================================================
# Delete namespace
# ============================================================

delete_namespace()
{
    local ns="$1"

    if namespace_exists "${ns}"; then
        log_info "Deleting network namespace: ${ns}"
        ip netns delete "${ns}"
        log_ok "Deleted namespace ${ns}"
    else
        log_info "Namespace ${ns} does not exist"
    fi
}

# ============================================================
# Delete OVS bridge
# ============================================================

delete_bridge()
{
    local bridge="$1"

    if ovs-vsctl br-exists "${bridge}"; then
        log_info "Deleting OVS bridge: ${bridge}"
        ovs-vsctl del-br "${bridge}"
        log_ok "Deleted ${bridge}"
    else
        log_info "OVS bridge ${bridge} does not exist"
    fi
}

# ============================================================
# Delete Linux interface
# ============================================================

delete_interface()
{
    local interface="$1"

    if interface_exists "${interface}"; then
        log_info "Deleting interface: ${interface}"
        ip link delete "${interface}" 2>/dev/null || true
    fi
}

# ============================================================
# Reset topology
# ============================================================

reset_topology()
{
    echo
    echo "============================================================"
    echo " Resetting OVS DAC topology"
    echo "============================================================"
    echo

    clear_setup_flag

    # --------------------------------------------------------
    # Delete namespaces.
    #
    # Deleting the namespace also deletes the namespace side
    # of the veth pair.
    # --------------------------------------------------------

    delete_namespace "${LEFT_NS}"
    delete_namespace "${RIGHT_NS}"

    # --------------------------------------------------------
    # Delete OVS bridges.
    #
    # This removes the OVS ports attached to the bridges.
    # --------------------------------------------------------

    delete_bridge "${LEFT_BR}"
    delete_bridge "${RIGHT_BR}"

    # --------------------------------------------------------
    # Delete any remaining veth interfaces.
    # --------------------------------------------------------

    delete_interface "${LEFT_VETH_OVS}"
    delete_interface "${RIGHT_VETH_OVS}"

    # --------------------------------------------------------
    # Return physical NICs to a clean state.
    # --------------------------------------------------------

    ip addr flush dev "${LEFT_IF}" 2>/dev/null || true
    ip addr flush dev "${RIGHT_IF}" 2>/dev/null || true

    ip link set "${LEFT_IF}" down 2>/dev/null || true
    ip link set "${RIGHT_IF}" down 2>/dev/null || true

    log_ok "Topology removed"
}

# ============================================================
# Create namespace
# ============================================================

create_namespace()
{
    local ns="$1"

    if namespace_exists "${ns}"; then
        log_warn "Namespace ${ns} already exists"
        return 0
    fi

    log_info "Creating namespace: ${ns}"

    ip netns add "${ns}"

    log_ok "Created ${ns}"
}

# ============================================================
# Create veth pair
# ============================================================

# create_veth_pair()
# {
#     local ovs_side="$1"
#     local ns_side="$2"
#     local ns="$3"
#
#     log_info "Creating veth pair:"
#     echo "         ${ovs_side} <----> ${ns_side}"
#
#     ip link add "${ovs_side}" type veth peer name "${ns_side}"
#
#     # Move namespace side into namespace
#     ip link set "${ns_side}" netns "${ns}"
#
#     # Bring OVS side up
#     ip link set "${ovs_side}" up
#
#     # Bring namespace side up
#     ip netns exec "${ns}" ip link set "${ns_side}" up
#
#     log_ok "Created veth pair for ${ns}"
# }

create_veth_pair()
{
    local ovs_side="$1"
    local ns_side="$2"
    local ns="$3"

    log_info "Creating veth pair:"
    echo "         ${ovs_side} <----> ${ns_side}"

    ip link add "${ovs_side}" type veth peer name "${ns_side}"

    # Move namespace side into namespace
    ip link set "${ns_side}" netns "${ns}"

    # Configure jumbo MTU on OVS side
    ip link set "${ovs_side}" mtu 9000 
    ip link set "${ovs_side}" up

    # Configure jumbo MTU on namespace side
    ip netns exec "${ns}" \
        ip link set "${ns_side}" mtu 9000 

    ip netns exec "${ns}" \
        ip link set "${ns_side}" up

    log_ok "Created ${ns_side}<->${ovs_side} with MTU 9000"
}

# ============================================================
# Configure namespace IP
# ============================================================

# configure_namespace_ip()
# {
#     local ns="$1"
#     local interface="$2"
#     local ip_address="$3"
#
#     log_info "Configuring ${ns}: ${ip_address}/${PREFIX}"
#
#     ip netns exec "${ns}" \
#         ip addr add "${ip_address}/${PREFIX}" dev "${interface}"
#
#     ip netns exec "${ns}" \
#         ip link set "${interface}" up
#
#     # Bring namespace loopback up
#     ip netns exec "${ns}" \
#         ip link set lo up
#
#     log_ok "${ns} configured"
# }

configure_namespace_ip()
{
    local ns="$1"
    local interface="$2"
    local ip_address="$3"

    log_info "Configuring ${ns}: ${ip_address}/${PREFIX}"

    ip netns exec "${ns}" \
        ip link set "${interface}" mtu 9000 

    ip netns exec "${ns}" \
        ip addr add "${ip_address}/${PREFIX}" dev "${interface}"

    ip netns exec "${ns}" \
        ip link set "${interface}" up

    ip netns exec "${ns}" \
        ip link set lo up

    log_ok "${ns} configured with MTU 9000"
}

# ============================================================
# Create OVS bridge
# ============================================================

create_bridge()
{
    local bridge="$1"

    log_info "Creating OVS bridge: ${bridge}"

    ovs-vsctl --may-exist add-br "${bridge}"
    sleep 1

    ip link set "${bridge}" mtu 9000
    ip link set "${bridge}" up
    sleep 1

    log_ok "Created ${bridge}"
}

# ============================================================
# Add port to OVS
# ============================================================

add_ovs_port()
{
    local bridge="$1"
    local interface="$2"

    log_info "Adding ${interface} -> ${bridge}"

    ovs-vsctl --may-exist add-port "${bridge}" "${interface}"

    ip link set "${interface}" up

    log_ok "${interface} attached to ${bridge}"
}

# ============================================================
# Configure OVS forwarding
# ============================================================

configure_ovs_flows()
{
    log_info "Configuring OVS NORMAL forwarding..."

    ovs-ofctl del-flows "${LEFT_BR}" 2>/dev/null || true
    ovs-ofctl del-flows "${RIGHT_BR}" 2>/dev/null || true

    ovs-ofctl add-flow "${LEFT_BR}" \
        "priority=0,actions=NORMAL"

    ovs-ofctl add-flow "${RIGHT_BR}" \
        "priority=0,actions=NORMAL"

    log_ok "OVS NORMAL forwarding configured"
}

# ============================================================
# Verify physical interfaces
# ============================================================

verify_physical_interfaces()
{
    local failed=0

    echo
    echo "------------------------------------------------------------"
    echo " Physical Interfaces"
    echo "------------------------------------------------------------"

    if ! interface_exists "${LEFT_IF}"; then
        log_error "${LEFT_IF} does not exist"
        failed=1
    else
        log_ok "${LEFT_IF} exists"
    fi

    if ! interface_exists "${RIGHT_IF}"; then
        log_error "${RIGHT_IF} does not exist"
        failed=1
    else
        log_ok "${RIGHT_IF} exists"
    fi

    return "${failed}"
}

# ============================================================
# Verify namespaces
# ============================================================

verify_namespaces()
{
    local failed=0

    echo
    echo "------------------------------------------------------------"
    echo " Network Namespaces"
    echo "------------------------------------------------------------"

    if namespace_exists "${LEFT_NS}"; then
        log_ok "${LEFT_NS} exists"
    else
        log_error "${LEFT_NS} does not exist"
        failed=1
    fi

    if namespace_exists "${RIGHT_NS}"; then
        log_ok "${RIGHT_NS} exists"
    else
        log_error "${RIGHT_NS} does not exist"
        failed=1
    fi

    return "${failed}"
}

verify_mtu()
{
    local failed=0

    echo
    echo "------------------------------------------------------------"
    echo " MTU Verification"
    echo "------------------------------------------------------------"

    local interfaces=(
        "${LEFT_IF}"
        "${RIGHT_IF}"
    )

    for interface in "${interfaces[@]}"; do
        local mtu
        mtu=$(ip link show "${interface}" |
              awk '/mtu/ {for(i=1;i<=NF;i++) if($i=="mtu") print $(i+1)}')

        if [[ "${mtu}" == "9000" ]]; then
            log_ok "${interface}: MTU ${mtu}"
        else
            log_error "${interface}: MTU ${mtu}, expected 9000"
            failed=1
        fi
    done

    for interface in \
        "${LEFT_VETH_OVS}" \
        "${RIGHT_VETH_OVS}"; do

        local mtu
        mtu=$(ip link show "${interface}" |
              awk '/mtu/ {for(i=1;i<=NF;i++) if($i=="mtu") print $(i+1)}')

        if [[ "${mtu}" == "9000" ]]; then
            log_ok "${interface}: MTU ${mtu}"
        else
            log_error "${interface}: MTU ${mtu}, expected 9000"
            failed=1
        fi
    done

    return "${failed}"
}

# ============================================================
# Verify OVS topology
# ============================================================

verify_ovs_topology()
{
    local failed=0

    echo
    echo "------------------------------------------------------------"
    echo " OVS Topology"
    echo "------------------------------------------------------------"

    # Bridges
    if ovs-vsctl br-exists "${LEFT_BR}"; then
        log_ok "${LEFT_BR} exists"
    else
        log_error "${LEFT_BR} missing"
        failed=1
    fi

    if ovs-vsctl br-exists "${RIGHT_BR}"; then
        log_ok "${RIGHT_BR} exists"
    else
        log_error "${RIGHT_BR} missing"
        failed=1
    fi

    # Physical ports
    if [[ "$(ovs-vsctl port-to-br "${LEFT_IF}" 2>/dev/null || true)" == "${LEFT_BR}" ]]; then
        log_ok "${LEFT_IF} -> ${LEFT_BR}"
    else
        log_error "${LEFT_IF} is not attached to ${LEFT_BR}"
        failed=1
    fi

    if [[ "$(ovs-vsctl port-to-br "${RIGHT_IF}" 2>/dev/null || true)" == "${RIGHT_BR}" ]]; then
        log_ok "${RIGHT_IF} -> ${RIGHT_BR}"
    else
        log_error "${RIGHT_IF} is not attached to ${RIGHT_BR}"
        failed=1
    fi

    # Veth OVS ports
    if [[ "$(ovs-vsctl port-to-br "${LEFT_VETH_OVS}" 2>/dev/null || true)" == "${LEFT_BR}" ]]; then
        log_ok "${LEFT_VETH_OVS} -> ${LEFT_BR}"
    else
        log_error "${LEFT_VETH_OVS} is not attached to ${LEFT_BR}"
        failed=1
    fi

    if [[ "$(ovs-vsctl port-to-br "${RIGHT_VETH_OVS}" 2>/dev/null || true)" == "${RIGHT_BR}" ]]; then
        log_ok "${RIGHT_VETH_OVS} -> ${RIGHT_BR}"
    else
        log_error "${RIGHT_VETH_OVS} is not attached to ${RIGHT_BR}"
        failed=1
    fi

    return "${failed}"
}

# ============================================================
# Verify namespace IP configuration
# ============================================================

verify_namespace_ip()
{
    local ns="$1"
    local interface="$2"
    local expected_ip="$3"

    if ip netns exec "${ns}" \
        ip addr show "${interface}" |
        grep -q "${expected_ip}/${PREFIX}"; then

        log_ok "${ns}/${interface} = ${expected_ip}/${PREFIX}"
        return 0
    fi

    log_error "${ns}/${interface} does not have ${expected_ip}/${PREFIX}"
    return 1
}

# ============================================================
# Full topology verification
# ============================================================

verify_topology()
{
    local failed=0

    echo
    echo "============================================================"
    echo " Verifying topology"
    echo "============================================================"

    verify_physical_interfaces || failed=1
    verify_mtu || failed=1
    verify_namespaces || failed=1
    verify_ovs_topology || failed=1

    verify_namespace_ip \
        "${LEFT_NS}" \
        "${LEFT_VETH_NS}" \
        "${LEFT_IP}" || failed=1

    verify_namespace_ip \
        "${RIGHT_NS}" \
        "${RIGHT_VETH_NS}" \
        "${RIGHT_IP}" || failed=1

    echo
    echo "------------------------------------------------------------"
    echo " OVS Configuration"
    echo "------------------------------------------------------------"

    ovs-vsctl show

    echo
    echo "------------------------------------------------------------"
    echo " Namespace Configuration"
    echo "------------------------------------------------------------"

    echo
    echo "--- ${LEFT_NS} ---"
    ip netns exec "${LEFT_NS}" ip addr

    echo
    echo "--- ${RIGHT_NS} ---"
    ip netns exec "${RIGHT_NS}" ip addr

    echo

    if [[ "${failed}" -eq 0 ]]; then
        log_ok "Topology verification successful"
        return 0
    fi

    log_error "Topology verification FAILED"
    return 1
}

# ============================================================
# Create complete topology
# ============================================================

create_topology()
{
    echo
    echo "============================================================"
    echo " Creating OVS DAC topology"
    echo "============================================================"
    echo

    # --------------------------------------------------------
    # Start clean
    # --------------------------------------------------------

    reset_topology

    # --------------------------------------------------------
    # Verify physical interfaces exist
    # --------------------------------------------------------

    if ! verify_physical_interfaces; then
        log_error "Required physical interface is missing."
        return 1
    fi

    # --------------------------------------------------------
    # Prepare physical interfaces
    #
    # They are L2-only OVS ports.
    # No IP addresses are assigned to them.
    # --------------------------------------------------------

    log_info "Preparing physical interfaces"

    ip addr flush dev "${LEFT_IF}"
    ip addr flush dev "${RIGHT_IF}"

    ip link set "${LEFT_IF}" down
    ip link set "${RIGHT_IF}" down

    # --- jumbo frame setup 
    ip link set dev "${LEFT_IF}" mtu 9000
    ip link set dev "${RIGHT_IF}" mtu 9000
    # --------------------------------------------------------
    # Create OVS bridges
    # --------------------------------------------------------

    create_bridge "${LEFT_BR}"
    create_bridge "${RIGHT_BR}"
    ip link set dev "${LEFT_BR}" mtu 9000
    ip link set dev "${RIGHT_BR}" mtu 9000

    # --------------------------------------------------------
    # Add physical NICs to OVS
    # --------------------------------------------------------

    add_ovs_port "${LEFT_BR}" "${LEFT_IF}"
    add_ovs_port "${RIGHT_BR}" "${RIGHT_IF}"

    # --------------------------------------------------------
    # Create namespaces
    # --------------------------------------------------------

    create_namespace "${LEFT_NS}"
    create_namespace "${RIGHT_NS}"

    # --------------------------------------------------------
    # Create veth pairs
    # --------------------------------------------------------

    create_veth_pair \
        "${LEFT_VETH_OVS}" \
        "${LEFT_VETH_NS}" \
        "${LEFT_NS}"

    create_veth_pair \
        "${RIGHT_VETH_OVS}" \
        "${RIGHT_VETH_NS}" \
        "${RIGHT_NS}"

    ip link set dev "${LEFT_VETH_OVS}  mtu 9000

    ip link set dev "${RIGHT_VETH_OVS}  mtu 9000

    ip netns exec "${LEFT_NS}" ip link set dev "${LEFT_VETH_NS}" mtu 9000

    ip netns exec "${RIGHT_NS}" ip link set dev "${RIGHT_VETH_NS}" mtu 9000
   
    # --------------------------------------------------------
    # Add veth root sides to OVS
    # --------------------------------------------------------

    add_ovs_port "${LEFT_BR}" "${LEFT_VETH_OVS}"
    add_ovs_port "${RIGHT_BR}" "${RIGHT_VETH_OVS}"

    # --------------------------------------------------------
    # Configure namespace IPs
    # --------------------------------------------------------

    configure_namespace_ip \
        "${LEFT_NS}" \
        "${LEFT_VETH_NS}" \
        "${LEFT_IP}"

    configure_namespace_ip \
        "${RIGHT_NS}" \
        "${RIGHT_VETH_NS}" \
        "${RIGHT_IP}"

    # --------------------------------------------------------
    # Configure OVS forwarding
    # --------------------------------------------------------

    configure_ovs_flows

    # --------------------------------------------------------
    # Verify
    # --------------------------------------------------------

    if verify_topology; then
        set_setup_flag
        log_ok "Topology setup completed successfully"
        return 0
    fi

    log_error "Topology setup failed"

    clear_setup_flag

    return 1
}

# ============================================================
# Ping one way
# ============================================================

ping_one_way()
{
    local source_ns="$1"
    local destination_ip="$2"
    local direction="$3"

    echo
    echo "------------------------------------------------------------"
    echo " ${direction}"
    echo " Source namespace : ${source_ns}"
    echo " Destination      : ${destination_ip}"
    echo " Ping count       : ${PING_COUNT}"
    echo "------------------------------------------------------------"

    ip netns exec "${source_ns}" \
        ping \
            -c "${PING_COUNT}" \
            -W "${PING_TIMEOUT}" \
            "${destination_ip}"

    local result=$?

    if [[ "${result}" -eq 0 ]]; then
        log_ok "${direction} ping successful"
        return 0
    fi

    log_error "${direction} ping FAILED"
    return 1
}

# ============================================================
# Bidirectional ping test
# ============================================================

perform_ping_test()
{
    if ! require_setup; then
        return 1
    fi

    echo
    echo "============================================================"
    echo " Bidirectional DAC Ping Test"
    echo "============================================================"
    echo
    echo "IMPORTANT:"
    echo "The ping endpoints are in separate network namespaces."
    echo "Traffic therefore has to traverse the physical DAC."
    echo

    local failed=0

    # LEFT -> RIGHT
    ping_one_way \
        "${LEFT_NS}" \
        "${RIGHT_IP}" \
        "LEFT -> RIGHT" || failed=1

    # RIGHT -> LEFT
    ping_one_way \
        "${RIGHT_NS}" \
        "${LEFT_IP}" \
        "RIGHT -> LEFT" || failed=1

    echo
    echo "============================================================"

    if [[ "${failed}" -eq 0 ]]; then
        log_ok "BIDIRECTIONAL PING TEST PASSED"
        return 0
    fi

    log_error "BIDIRECTIONAL PING TEST FAILED"
    return 1
}

# ============================================================
# Throughput test helpers
# ============================================================

get_ping_rtt_ms()
{
    local source_ns="$1"
    local destination_ip="$2"

    ip netns exec "${source_ns}" \
        ping \
            -c 5 \
            -W 1 \
            "${destination_ip}" 2>/dev/null |
        awk -F'/' '/^rtt|^round-trip/ {
            print $5
            exit
        }'
}

# ============================================================
# Run iperf3 server
# ============================================================

start_iperf_server()
{
    log_info "Starting iperf3 server in ${RIGHT_NS}"

    ip netns exec "${RIGHT_NS}" \
        iperf3 -s > /tmp/iperf3-server.log 2>&1 &

    IPERF_SERVER_PID=$!

    sleep 1

    if ! kill -0 "${IPERF_SERVER_PID}" 2>/dev/null; then
        log_error "Failed to start iperf3 server"
        cat /tmp/iperf3-server.log
        return 1
    fi

    log_ok "iperf3 server started"

    return 0
}

# ============================================================
# Stop iperf3 server
# ============================================================

stop_iperf_server()
{
    if [[ -n "${IPERF_SERVER_PID:-}" ]]; then
        kill "${IPERF_SERVER_PID}" 2>/dev/null || true
        wait "${IPERF_SERVER_PID}" 2>/dev/null || true
        unset IPERF_SERVER_PID
    fi

    # Make sure no stale server remains inside the namespace.
    ip netns exec "${RIGHT_NS}" \
        pkill -x iperf3 2>/dev/null || true
}

# ============================================================
# Read host CPU usage
#
# This is a simple /proc/stat based measurement.
# It is intentionally not treated as PMD utilization.
# ============================================================

read_cpu_stat()
{
    awk '/^cpu / {
        total=$2+$3+$4+$5+$6+$7+$8+$9
        idle=$5+$6
        print total, idle
        exit
    }' /proc/stat
}

get_cpu_busy_percent()
{
    local start_total="$1"
    local start_idle="$2"
    local end_total="$3"
    local end_idle="$4"

    local total_delta=$((end_total - start_total))
    local idle_delta=$((end_idle - start_idle))

    if [[ "${total_delta}" -le 0 ]]; then
        echo "0.00"
        return
    fi

    awk \
        -v total="${total_delta}" \
        -v idle="${idle_delta}" \
        'BEGIN {
            printf "%.2f", ((total-idle)/total)*100
        }'
}

# ============================================================
# Throughput test
#
# Runs:
#   1. ICMP RTT
#   2. TCP throughput
#   3. UDP throughput / PPS / loss
#
# All traffic originates in left-ns and terminates in right-ns.
# Therefore traffic must traverse:
#
# left-ns
#   -> br-left
#   -> physical NIC
#   -> DAC
#   -> physical NIC
#   -> br-right
#   -> right-ns
#
# ============================================================

perform_throughput_test()
{
    if ! require_setup; then
        return 1
    fi

    echo
    echo "============================================================"
    echo " Bare-Metal OVS Throughput Test"
    echo "============================================================"
    echo
    echo "Path:"
    echo
    echo " ${LEFT_NS}"
    echo "    |"
    echo " ${LEFT_BR}"
    echo "    |"
    echo " ${LEFT_IF}"
    echo "    |"
    echo "   DAC"
    echo "    |"
    echo " ${RIGHT_IF}"
    echo "    |"
    echo " ${RIGHT_BR}"
    echo "    |"
    echo " ${RIGHT_NS}"
    echo
    echo "This test does NOT use the VM/vhost-user path."
    echo

    mkdir -p "${RESULTS_DIR}"

    local timestamp
    timestamp="$(date '+%Y-%m-%d %H:%M:%S %Z')"

    local timestamp_file
    timestamp_file="$(date '+%Y%m%d-%H%M%S')"

    local test_dir="${RESULTS_DIR}/ovs-baremetal-${timestamp_file}"

    mkdir -p "${test_dir}"

    local tcp_json="${test_dir}/tcp.json"
    local udp_json="${test_dir}/udp.json"

    # --------------------------------------------------------
    # Verify connectivity
    # --------------------------------------------------------

    log_info "Checking connectivity before throughput test..."

    if ! ip netns exec "${LEFT_NS}" \
        ping -c 3 -W 1 "${RIGHT_IP}" >/dev/null 2>&1; then

        log_error "Connectivity test failed."
        return 1
    fi

    log_ok "Connectivity test passed"

    # --------------------------------------------------------
    # ICMP RTT
    # --------------------------------------------------------

    log_info "Measuring ICMP RTT..."

    local rtt_ms
    rtt_ms="$(get_ping_rtt_ms "${LEFT_NS}" "${RIGHT_IP}")"

    if [[ -z "${rtt_ms}" ]]; then
        rtt_ms="0"
        log_warn "Could not determine RTT"
    else
        log_ok "ICMP RTT: ${rtt_ms} ms"
    fi

    # --------------------------------------------------------
    # Start iperf3 server
    # --------------------------------------------------------

    if ! start_iperf_server; then
        return 1
    fi

    trap stop_iperf_server RETURN

    # --------------------------------------------------------
    # TCP test
    # --------------------------------------------------------

    echo
    echo "------------------------------------------------------------"
    echo " TCP throughput"
    echo "------------------------------------------------------------"
    echo
    echo "Duration       : ${IPERF_DURATION}s"
    echo "TCP streams    : ${IPERF_TCP_STREAMS}"
    echo

    read -r tcp_start_total tcp_start_idle <<< "$(read_cpu_stat)"

    ip netns exec "${LEFT_NS}" \
        iperf3 \
            -c "${RIGHT_IP}" \
            -t "${IPERF_DURATION}" \
            -P "${IPERF_TCP_STREAMS}" \
            -J \
            > "${tcp_json}"

    local tcp_result=$?

    read -r tcp_end_total tcp_end_idle <<< "$(read_cpu_stat)"

    if [[ "${tcp_result}" -ne 0 ]]; then
        log_error "TCP iperf3 test failed"
        cat "${tcp_json}"
        return 1
    fi

    local tcp_bps
    tcp_bps="$(jq -r '
        if .end.sum_received.bits_per_second != null
        then .end.sum_received.bits_per_second
        else .end.sum_sent.bits_per_second
        end
    ' "${tcp_json}")"

    local tcp_gbps
    tcp_gbps="$(awk -v bps="${tcp_bps}" \
        'BEGIN { printf "%.2f", bps/1000000000 }')"

    local tcp_cpu_busy
    tcp_cpu_busy="$(get_cpu_busy_percent \
        "${tcp_start_total}" \
        "${tcp_start_idle}" \
        "${tcp_end_total}" \
        "${tcp_end_idle}")"

    log_ok "TCP throughput: ${tcp_gbps} Gbps"
    log_info "Host CPU busy: ${tcp_cpu_busy}%"

    # --------------------------------------------------------
    # UDP test
    # --------------------------------------------------------

    echo
    echo "------------------------------------------------------------"
    echo " UDP throughput"
    echo "------------------------------------------------------------"
    echo
    echo "Duration       : ${IPERF_DURATION}s"
    echo "UDP bandwidth  : ${IPERF_UDP_BANDWIDTH}"
    echo "Packet length  : ${IPERF_UDP_LENGTH}"
    echo "UDP streams    : ${IPERF_UDP_STREAMS}"
    echo

    read -r udp_start_total udp_start_idle <<< "$(read_cpu_stat)"

    local udp_bandwidth_args=()

    if [[ "${IPERF_UDP_BANDWIDTH}" != "0" ]]; then
        udp_bandwidth_args=(-b "${IPERF_UDP_BANDWIDTH}")
    fi

    ip netns exec "${LEFT_NS}" \
        iperf3 \
            -c "${RIGHT_IP}" \
            -u \
            -t "${IPERF_DURATION}" \
            -l "${IPERF_UDP_LENGTH}" \
            -P "${IPERF_UDP_STREAMS}" \
            "${udp_bandwidth_args[@]}" \
            -J \
            > "${udp_json}"

    local udp_result=$?

    read -r udp_end_total udp_end_idle <<< "$(read_cpu_stat)"

    if [[ "${udp_result}" -ne 0 ]]; then
        log_error "UDP iperf3 test failed"
        cat "${udp_json}"
        return 1
    fi

    # ----------------------------------------------------
    # FIX (bug #1): the original jq filter mixed a boolean
    # comparison with `//`, so it always printed "true"
    # instead of the actual bits_per_second value. Use a
    # plain `//` fallback chain instead.
    # ----------------------------------------------------
    local udp_bps
    udp_bps="$(jq -r '
        .end.sum_received.bits_per_second
        // .end.sum.bits_per_second
        // 0
        ' "${udp_json}")"

    local udp_jitter
    udp_jitter="$(
    jq -r '
        .end.sum_received.jitter_ms
        // .end.sum.jitter_ms
        // .end.sum_sent.jitter_ms
        // 0
        ' "${udp_json}")"

    local udp_gbps
    udp_gbps="$(
    awk -v bps="${udp_bps}" \
        'BEGIN {
            printf "%.2f", bps / 1000000000
        }')"

    # ----------------------------------------------------
    # FIX (bug #2): udp_seconds previously queried
    # ".packets" a second time instead of ".seconds",
    # which forced udp_pps to always compute as 1.
    # ----------------------------------------------------
    local udp_packets
    udp_packets="$(jq -r '
            .end.sum_received.packets // 0
        ' "${udp_json}")"

    local udp_seconds
    udp_seconds="$(jq -r '
            .end.sum_received.seconds // .end.sum.seconds // 0
        ' "${udp_json}")"

    local udp_pps
    udp_pps="$(
    awk \
        -v packets="${udp_packets}" \
        -v seconds="${udp_seconds}" \
        'BEGIN {
            if (seconds > 0)
                printf "%.0f", packets / seconds
            else
                printf "0"
        }' )"

    # ----------------------------------------------------
    # FIX (bug #3): udp_loss was never populated from the
    # iperf3 JSON before being formatted with awk, so it
    # always printed 0.000. Pull it from jq first.
    # ----------------------------------------------------
    local udp_loss
    udp_loss="$(jq -r '
            .end.sum_received.lost_percent
            // .end.sum.lost_percent
            // 0
        ' "${udp_json}")"

    udp_loss="$(awk -v loss="${udp_loss}" \
        'BEGIN { printf "%.3f", loss }')"

    udp_jitter="$(
    awk -v jitter="${udp_jitter}" \
        'BEGIN {
            printf "%.6f", jitter
        }')"

    local udp_cpu_busy
    udp_cpu_busy="$(get_cpu_busy_percent \
         "${udp_start_total}" \
        "${udp_start_idle}" \
        "${udp_end_total}" \
        "${udp_end_idle}")"

    log_ok "UDP throughput: ${udp_gbps} Gbps"
    log_ok "UDP PPS: ${udp_pps}"
    # FIX (bug #4): "log_ ok" (stray space) -> "log_ok"
    log_ok "UDP loss: ${udp_loss}%"
    log_info "Host CPU busy: ${udp_cpu_busy}%"

    # --------------------------------------------------------
    # Generate summary.json
    # --------------------------------------------------------

    cat > "${SUMMARY_FILE}" <<EOF
{
  "test_type": "baremetal_ovs",
  "timestamp": "${timestamp}",
  "left_interface": "${LEFT_IF}",
  "right_interface": "${RIGHT_IF}",
  "left_namespace": "${LEFT_NS}",
  "right_namespace": "${RIGHT_NS}",
  "ovs_left_bridge": "${LEFT_BR}",
  "ovs_right_bridge": "${RIGHT_BR}",
  "tcp_throughput_gbps": ${tcp_gbps},
  "udp_jitter_ms": ${udp_jitter},
  "udp_throughput_gbps": ${udp_gbps},
  "udp_pps": ${udp_pps},
  "udp_lost_percent": ${udp_loss},
  "icmp_rtt_ms": ${rtt_ms},
  "tcp_latency": "${rtt_ms} ms",
  "udp_latency": "${rtt_ms} ms",
  "host_cpu_busy_pct": ${tcp_cpu_busy},
  "tcp_parallel_streams": ${IPERF_TCP_STREAMS},
  "udp_packet_length": ${IPERF_UDP_LENGTH},
  "udp_streams": ${IPERF_UDP_STREAMS},
  "iperf3_duration_sec": ${IPERF_DURATION},
  "raw_tcp_result": "${tcp_json}",
  "raw_udp_result": "${udp_json}",
  "note": "host_cpu_busy_pct is aggregate host CPU utilization during the TCP test. Use ovs-appctl dpif-netdev/pmd-stats-show for OVS-DPDK PMD statistics when comparing against OVS-DPDK."
}
EOF

    echo
    echo "============================================================"
    echo " Throughput Test Results"
    echo "============================================================"
    echo
    printf " TCP throughput : %s Gbps\n" "${tcp_gbps}"
    printf " UDP throughput : %s Gbps\n" "${udp_gbps}"
    printf " UDP PPS        : %s\n" "${udp_pps}"
    printf " UDP loss       : %s %%\n" "${udp_loss}"
    printf " ICMP RTT       : %s ms\n" "${rtt_ms}"
    printf " Host CPU busy  : %s %%\n" "${tcp_cpu_busy}"
    echo
    echo "Raw TCP result:"
    echo "  ${tcp_json}"
    echo
    echo "Raw UDP result:"
    echo "  ${udp_json}"
    echo
    echo "Summary:"
    echo "  ${SUMMARY_FILE}"
    echo
    echo "============================================================"

    log_ok "Bare-metal OVS throughput test completed"

    return 0
}

# ============================================================
# Show OVS flows
# ============================================================

show_flows()
{
    echo
    echo "============================================================"
    echo " OVS FLOWS"
    echo "============================================================"

    if ovs-vsctl br-exists "${LEFT_BR}"; then
        echo
        echo "--- ${LEFT_BR} ---"
        ovs-ofctl dump-flows "${LEFT_BR}"
    fi

    if ovs-vsctl br-exists "${RIGHT_BR}"; then
        echo
        echo "--- ${RIGHT_BR} ---"
        ovs-ofctl dump-flows "${RIGHT_BR}"
    fi
}

# ============================================================
# Show MAC tables
# ============================================================

show_mac_tables()
{
    echo
    echo "============================================================"
    echo " OVS MAC TABLES"
    echo "============================================================"

    if ovs-vsctl br-exists "${LEFT_BR}"; then
        echo
        echo "--- ${LEFT_BR} ---"
        ovs-appctl fdb/show "${LEFT_BR}"
    fi

    if ovs-vsctl br-exists "${RIGHT_BR}"; then
        echo
        echo "--- ${RIGHT_BR} ---"
        ovs-appctl fdb/show "${RIGHT_BR}"
    fi
}

# ============================================================
# Show configuration
# ============================================================

show_configuration()
{
    echo
    echo "============================================================"
    echo " Current Configuration"
    echo "============================================================"
    echo

    echo "Physical interfaces:"
    echo "  LEFT_IF       = ${LEFT_IF}"
    echo "  RIGHT_IF      = ${RIGHT_IF}"
    echo

    echo "OVS bridges:"
    echo "  LEFT_BR       = ${LEFT_BR}"
    echo "  RIGHT_BR      = ${RIGHT_BR}"
    echo

    echo "Network namespaces:"
    echo "  LEFT_NS       = ${LEFT_NS}"
    echo "  RIGHT_NS      = ${RIGHT_NS}"
    echo

    echo "Namespace interfaces:"
    echo "  LEFT_VETH     = ${LEFT_VETH_NS}"
    echo "  RIGHT_VETH    = ${RIGHT_VETH_NS}"
    echo

    echo "IPs:"
    echo "  LEFT_IP       = ${LEFT_IP}/${PREFIX}"
    echo "  RIGHT_IP      = ${RIGHT_IP}/${PREFIX}"
    echo

    echo "Ping count:"
    echo "  PING_COUNT    = ${PING_COUNT}"
    echo

    echo "Topology state:"

    if is_setup; then
        echo -e "  ${GREEN}SETUP COMPLETE${NC}"
    else
        echo -e "  ${YELLOW}NOT CONFIGURED${NC}"
    fi

    echo
}

# ============================================================
# Reset host and quit
# ============================================================

reset_host_and_quit()
{
    echo
    echo "============================================================"
    echo " Reset Host"
    echo "============================================================"
    echo

    log_warn "Removing the OVS DAC topology."

    reset_topology

    # --------------------------------------------------------
    # If NetworkManager is installed, hand interfaces back
    # to NetworkManager.
    # --------------------------------------------------------

    if command -v nmcli >/dev/null 2>&1; then
        log_info "NetworkManager detected."

        nmcli device set "${LEFT_IF}" managed yes 2>/dev/null || true
        nmcli device set "${RIGHT_IF}" managed yes 2>/dev/null || true

        log_info "Physical interfaces returned to NetworkManager."
    fi

    log_ok "Host network topology reset."
    log_info "Exiting."

    exit 0
}

# ============================================================
# Setup
# ============================================================

setup()
{
    # set cx eswitch to switchdev mode TODO: replace PCI to probe pci-address 
    devlink dev eswitch set pci/0000:01:00.0 mode switchdev
    devlink dev eswitch set pci/0000:01:00.1 mode switchdev

    # Enable HW offloading of OpenVswitch
    ovs-vsctl set Open_vSwitch . other_config:hw-offload=true
    systemctl restart openvswitch

    create_topology
}

# ============================================================
# Menu
# ============================================================

show_menu()
{
    clear

    echo "============================================================"
    echo "          OVS DAC CROSSOVER TEST TOPOLOGY"
    echo "============================================================"
    echo
    echo "                         DAC"
    echo "                          |"
    echo "     ${LEFT_IF} <-----------> ${RIGHT_IF}"
    echo "          |                       |"
    echo "      ${LEFT_BR}                  ${RIGHT_BR}"
    echo "          |                       |"
    echo "      ${LEFT_VETH_OVS}             ${RIGHT_VETH_OVS}"
    echo "          |                       |"
    echo "      ${LEFT_NS}                  ${RIGHT_NS}"
    echo "      ${LEFT_IP}                 ${RIGHT_IP}"
    echo
    echo "------------------------------------------------------------"

    if is_setup; then
        echo -e "Topology state: ${GREEN}SETUP COMPLETE${NC}"
    else
        echo -e "Topology state: ${YELLOW}NOT CONFIGURED${NC}"
    fi

    echo "------------------------------------------------------------"
    echo
    echo "  1) Setup"
    echo "     Delete existing topology and create it again"
    echo
    echo "  2) Reset system"
    echo "     Remove OVS topology and return to menu"
    echo
    echo "  3) Ping test"
    echo "     LEFT -> RIGHT and RIGHT -> LEFT"
    echo
    echo "  4) Bare-metal OVS throughput" 
    echo "     TCP/UDP iperf3 test through physical DAC"
    echo 
    echo "  5) Reset host and quit" 
    echo "     Remove topology and restore interface management" 
    echo 
    echo "  6) Quit" 
    echo "     Leave topology running for manual testing" 
    echo 
    echo "  7) Show OVS flows" 
    echo 
    echo "  8) Show OVS MAC tables" 
    echo 
    echo "  9) Show configuration"
    echo "============================================================"
}

# ============================================================
# Main
# ============================================================

main()
{
    require_root
    nmcli device set "${LEFT_IF}" managed no
    nmcli device set "${RIGHT_IF}" managed no
    check_dependencies

    while true; do

        show_menu

        read -r -p "Select an option [1-9]: " choice

        case "${choice}" in

            1)
                setup
                pause_screen
                ;;

            2)
                reset_topology
                pause_screen
                ;;

            3)
                perform_ping_test
                pause_screen
                ;;

            4)
                perform_throughput_test
                pause_screen
                ;;

            5)
                reset_host_and_quit
                ;;

            6)
                echo
                log_info "Leaving topology untouched."
                echo
                exit 0
                ;;

            7)
                show_flows
                pause_screen
                ;;

            8)
                show_mac_tables
                pause_screen
                ;;

            9)
                show_configuration
                pause_screen
                ;;

            *)
                log_error "Invalid option."
                pause_screen
                ;;

        esac
    done
}

# ============================================================
# Entry point
# ============================================================

main "$@"
