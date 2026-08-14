#!/usr/bin/env bash

# ============================================================
# LINUX BRIDGE DAC CROSSOVER TEST
#
#                         DAC crossover
#                  +-----------------------+
#                  |                       |
#            enp1s0f0np0               enp1s0f1np1
#                  |                       |
#             +----+----+             +----+----+
#             | br-left |             |br-right |
#             |  Linux  |             |  Linux  |
#             |  bridge |             |  bridge |
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
RIGHT_IF="enP2p1s0f1np1"

# Linux bridges
LEFT_BR="br-left"
RIGHT_BR="br-right"

# Network namespaces
LEFT_NS="left-ns"
RIGHT_NS="right-ns"

# Veth interfaces
# Namespace side
LEFT_VETH_NS="left-veth"
RIGHT_VETH_NS="right-veth"

# Host / bridge side
LEFT_VETH_BR="left-veth-br"
RIGHT_VETH_BR="right-veth-br"

# Test IP addresses
LEFT_IP="10.0.0.1"
RIGHT_IP="10.0.0.2"
PREFIX="24"

# Ping parameters
PING_COUNT=10
PING_TIMEOUT=1

# Persistent state flag
STATE_FILE="/run/linux-bridge-dac-topology.state"

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

    command -v ip >/dev/null 2>&1 || missing+=("ip")
    command -v ping >/dev/null 2>&1 || missing+=("ping")

    if [[ ${#missing[@]} -gt 0 ]]; then
        log_error "Missing required commands:"
        printf '  %s\n' "${missing[@]}"
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

bridge_exists()
{
    interface_exists "$1" &&
        ip -d link show "$1" 2>/dev/null |
        grep -q 'bridge'
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
# Delete Linux bridge
# ============================================================

delete_bridge()
{
    local bridge="$1"

    if interface_exists "${bridge}"; then
        log_info "Deleting Linux bridge: ${bridge}"

        # Bring bridge down first
        ip link set dev "${bridge}" down 2>/dev/null || true

        # Delete the bridge
        #
        # Interfaces enslaved to the bridge are detached from it
        # when the bridge is removed.
        #
        ip link delete "${bridge}" type bridge 2>/dev/null || true

        log_ok "Deleted ${bridge}"
    else
        log_info "Linux bridge ${bridge} does not exist"
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
    echo " Resetting Linux bridge DAC topology"
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
    # Delete Linux bridges.
    #
    # This detaches the physical NICs and veth host sides.
    # --------------------------------------------------------

    delete_bridge "${LEFT_BR}"
    delete_bridge "${RIGHT_BR}"

    # --------------------------------------------------------
    # Delete any remaining veth interfaces.
    # --------------------------------------------------------

    delete_interface "${LEFT_VETH_BR}"
    delete_interface "${RIGHT_VETH_BR}"

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

    log_info "Creating network namespace: ${ns}"

    ip netns add "${ns}"

    log_ok "Created ${ns}"
}

# ============================================================
# Create veth pair
# ============================================================

# ============================================================
# Create veth pair
# ============================================================

create_veth_pair()
{
    local bridge_side="$1"
    local ns_side="$2"
    local ns="$3"

    log_info "Creating veth pair:"
    echo "         ${bridge_side} <----> ${ns_side}"

    # Remove stale interfaces if they exist.
    delete_interface "${bridge_side}"

    # The namespace side normally disappears together with the
    # namespace. This is just defensive cleanup.
    if ip netns exec "${ns}" ip link show "${ns_side}" >/dev/null 2>&1; then
        ip netns exec "${ns}" ip link delete "${ns_side}" 2>/dev/null || true
    fi

    if ! ip link add "${bridge_side}" type veth peer name "${ns_side}"; then
        log_error "Failed to create veth pair ${bridge_side} <-> ${ns_side}"
        return 1
    fi

    if ! ip link set "${ns_side}" netns "${ns}"; then
        log_error "Failed to move ${ns_side} into namespace ${ns}"
        delete_interface "${bridge_side}"
        return 1
    fi

    if ! ip link set "${bridge_side}" up; then
        log_error "Failed to bring ${bridge_side} up"
        return 1
    fi

    if ! ip netns exec "${ns}" \
        ip link set "${ns_side}" up; then

        log_error "Failed to bring ${ns_side} up in ${ns}"
        return 1
    fi

    log_ok "Created veth pair for ${ns}"

    return 0
}

##=-=-=-=-=
# create_veth_pair()
# {
#     local bridge_side="$1"
#     local ns_side="$2"
#     local ns="$3"
#
#     log_info "Creating veth pair:"
#     echo "         ${bridge_side} <----> ${ns_side}"
#
#     ip link add "${bridge_side}" type veth peer name "${ns_side}"
#
#     # Move namespace side into namespace
#     ip link set "${ns_side}" netns "${ns}"
#
#     # Bring host / bridge side up
#     ip link set "${bridge_side}" up
#
#     # Bring namespace side up
#     ip netns exec "${ns}" \
#         ip link set "${ns_side}" up
#
#     log_ok "Created veth pair for ${ns}"
# }

# ============================================================
# Configure namespace IP
# ============================================================

configure_namespace_ip()
{
    local ns="$1"
    local interface="$2"
    local ip_address="$3"

    log_info "Configuring ${ns}: ${ip_address}/${PREFIX}"

    ip netns exec "${ns}" \
        ip addr add "${ip_address}/${PREFIX}" dev "${interface}"

    ip netns exec "${ns}" \
        ip link set "${interface}" up

    # Bring namespace loopback up
    ip netns exec "${ns}" \
        ip link set lo up

    log_ok "${ns} configured"
}

# ============================================================
# Create Linux bridge
# ============================================================

create_bridge()
{
    local bridge="$1"

    log_info "Creating Linux bridge: ${bridge}"

    if bridge_exists "${bridge}"; then
        log_warn "Linux bridge ${bridge} already exists"
    else
        ip link add name "${bridge}" type bridge
    fi

    # Disable STP for this simple point-to-point test.
    #
    # This is not strictly required, but prevents STP from
    # introducing unnecessary delays into the test.
    ip link set dev "${bridge}" type bridge stp_state 0

    # Bring bridge up
    ip link set dev "${bridge}" up

    log_ok "Created ${bridge}"
}

# ============================================================
# Add port to Linux bridge
# ============================================================

add_bridge_port()
{
    sleep 3
    local bridge="$1"
    local interface="$2"

    log_info "Adding ${interface} -> ${bridge}"

    # Make sure the interface is not carrying an IP address.
    ip addr flush dev "${interface}" 2>/dev/null || true

    # Attach interface to bridge
    ip link set dev "${interface}" master "${bridge}"

    # Bring interface up
    ip link set dev "${interface}" up

    log_ok "${interface} attached to ${bridge}"
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

# ============================================================
# Verify Linux bridge topology
# ============================================================

verify_bridge_topology()
{
    local failed=0

    echo
    echo "------------------------------------------------------------"
    echo " Linux Bridge Topology"
    echo "------------------------------------------------------------"

    # --------------------------------------------------------
    # Bridges
    # --------------------------------------------------------

    if bridge_exists "${LEFT_BR}"; then
        log_ok "${LEFT_BR} exists"
    else
        log_error "${LEFT_BR} missing"
        failed=1
    fi

    if bridge_exists "${RIGHT_BR}"; then
        log_ok "${RIGHT_BR} exists"
    else
        log_error "${RIGHT_BR} missing"
        failed=1
    fi

    # --------------------------------------------------------
    # Physical ports
    # --------------------------------------------------------

    if ip link show dev "${LEFT_IF}" 2>/dev/null |
        grep -q "master ${LEFT_BR}"; then

        log_ok "${LEFT_IF} -> ${LEFT_BR}"
    else
        log_error "${LEFT_IF} is not attached to ${LEFT_BR}"
        failed=1
    fi

    if ip link show dev "${RIGHT_IF}" 2>/dev/null |
        grep -q "master ${RIGHT_BR}"; then

        log_ok "${RIGHT_IF} -> ${RIGHT_BR}"
    else
        log_error "${RIGHT_IF} is not attached to ${RIGHT_BR}"
        failed=1
    fi

    # --------------------------------------------------------
    # Veth bridge ports
    # --------------------------------------------------------

    if ip link show dev "${LEFT_VETH_BR}" 2>/dev/null |
        grep -q "master ${LEFT_BR}"; then

        log_ok "${LEFT_VETH_BR} -> ${LEFT_BR}"
    else
        log_error "${LEFT_VETH_BR} is not attached to ${LEFT_BR}"
        failed=1
    fi

    if ip link show dev "${RIGHT_VETH_BR}" 2>/dev/null |
        grep -q "master ${RIGHT_BR}"; then

        log_ok "${RIGHT_VETH_BR} -> ${RIGHT_BR}"
    else
        log_error "${RIGHT_VETH_BR} is not attached to ${RIGHT_BR}"
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
    verify_namespaces || failed=1
    verify_bridge_topology || failed=1

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
    echo " Linux Bridge Configuration"
    echo "------------------------------------------------------------"

    echo
    echo "--- ${LEFT_BR} ---"
    ip -d link show "${LEFT_BR}" 2>/dev/null || true
    bridge link show dev "${LEFT_IF}" 2>/dev/null || true
    bridge link show dev "${LEFT_VETH_BR}" 2>/dev/null || true

    echo
    echo "--- ${RIGHT_BR} ---"
    ip -d link show "${RIGHT_BR}" 2>/dev/null || true
    bridge link show dev "${RIGHT_IF}" 2>/dev/null || true
    bridge link show dev "${RIGHT_VETH_BR}" 2>/dev/null || true

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
    echo " Creating Linux bridge DAC topology"
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
    # They are L2-only Linux bridge ports.
    # No IP addresses are assigned to them.
    # --------------------------------------------------------

    log_info "Preparing physical interfaces"

    ip addr flush dev "${LEFT_IF}"
    ip addr flush dev "${RIGHT_IF}"

    ip link set "${LEFT_IF}" down
    ip link set "${RIGHT_IF}" down

    # --------------------------------------------------------
    # Create Linux bridges
    # --------------------------------------------------------

    create_bridge "${LEFT_BR}"
    create_bridge "${RIGHT_BR}"
    sleep 3

    # --------------------------------------------------------
    # Add physical NICs to Linux bridges
    # --------------------------------------------------------

    add_bridge_port "${LEFT_BR}" "${LEFT_IF}"
    add_bridge_port "${RIGHT_BR}" "${RIGHT_IF}"

    # --------------------------------------------------------
    # Create namespaces
    # --------------------------------------------------------

    create_namespace "${LEFT_NS}"
    create_namespace "${RIGHT_NS}"

    # --------------------------------------------------------
    # Create veth pairs
    # --------------------------------------------------------

    create_veth_pair \
        "${LEFT_VETH_BR}" \
        "${LEFT_VETH_NS}" \
        "${LEFT_NS}"

    create_veth_pair \
        "${RIGHT_VETH_BR}" \
        "${RIGHT_VETH_NS}" \
        "${RIGHT_NS}"

    # --------------------------------------------------------
    # Add veth host sides to Linux bridges
    # --------------------------------------------------------

    add_bridge_port "${LEFT_BR}" "${LEFT_VETH_BR}"
    add_bridge_port "${RIGHT_BR}" "${RIGHT_VETH_BR}"

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
    # Linux bridge performs normal L2 forwarding automatically.
    #
    # No OVS flows are required.
    # --------------------------------------------------------

    log_info "Linux bridge forwarding is enabled automatically."

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
# Show Linux bridge information
# ============================================================

show_bridge_info()
{
    echo
    echo "============================================================"
    echo " LINUX BRIDGE INFORMATION"
    echo "============================================================"

    if bridge_exists "${LEFT_BR}"; then
        echo
        echo "--- ${LEFT_BR} ---"
        bridge link show master "${LEFT_BR}" 2>/dev/null || true
        echo
        echo "FDB:"
        bridge fdb show br "${LEFT_BR}" 2>/dev/null || true
    fi

    if bridge_exists "${RIGHT_BR}"; then
        echo
        echo "--- ${RIGHT_BR} ---"
        bridge link show master "${RIGHT_BR}" 2>/dev/null || true
        echo
        echo "FDB:"
        bridge fdb show br "${RIGHT_BR}" 2>/dev/null || true
    fi
}

# ============================================================
# Show MAC tables
# ============================================================

show_mac_tables()
{
    echo
    echo "============================================================"
    echo " LINUX BRIDGE MAC TABLES"
    echo "============================================================"

    if bridge_exists "${LEFT_BR}"; then
        echo
        echo "--- ${LEFT_BR} ---"
        bridge fdb show br "${LEFT_BR}" 2>/dev/null || true
    fi

    if bridge_exists "${RIGHT_BR}"; then
        echo
        echo "--- ${RIGHT_BR} ---"
        bridge fdb show br "${RIGHT_BR}" 2>/dev/null || true
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

    echo "Linux bridges:"
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

    echo "Bridge-side veth interfaces:"
    echo "  LEFT_VETH_BR  = ${LEFT_VETH_BR}"
    echo "  RIGHT_VETH_BR = ${RIGHT_VETH_BR}"
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

    log_warn "Removing the Linux bridge DAC topology."

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
    create_topology
}

# ============================================================
# Menu
# ============================================================

show_menu()
{
    clear

    echo "============================================================"
    echo "       LINUX BRIDGE DAC CROSSOVER TEST TOPOLOGY"
    echo "============================================================"
    echo
    echo "                         DAC"
    echo "                          |"
    echo "     ${LEFT_IF} <-----------> ${RIGHT_IF}"
    echo "          |                       |"
    echo "      ${LEFT_BR}                  ${RIGHT_BR}"
    echo "          |                       |"
    echo "      ${LEFT_VETH_BR}          ${RIGHT_VETH_BR}"
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
    echo "     Remove Linux bridge topology and return to menu"
    echo
    echo "  3) Ping test"
    echo "     LEFT -> RIGHT and RIGHT -> LEFT"
    echo
    echo "  4) Reset host and quit"
    echo "     Remove topology and restore interface management"
    echo
    echo "  5) Quit"
    echo "     Leave topology running for manual testing"
    echo
    echo "  6) Show Linux bridge information"
    echo
    echo "  7) Show Linux bridge MAC tables"
    echo
    echo "  8) Show configuration"
    echo
    echo "============================================================"
}

# ============================================================
# Main
# ============================================================

main()
{
    require_root
    check_dependencies

    while true; do

        show_menu

        read -r -p "Select an option [1-8]: " choice

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
                reset_host_and_quit
                ;;

            5)
                echo
                log_info "Leaving topology untouched."
                echo
                exit 0
                ;;

            6)
                show_bridge_info
                pause_screen
                ;;

            7)
                show_mac_tables
                pause_screen
                ;;

            8)
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
