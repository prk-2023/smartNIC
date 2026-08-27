#!/usr/bin/env bash

# ============================================================
# PURE BARE-METAL (NO OVS) CROSSOVER TEST
#
#                     DAC crossover
#                  +-----------------------+
#                  |                       |
#             enp1s0f0np0              enp1s0f1np1
#              +----+-----+            +-----+----+
#              |  left-ns |            | right-ns |
#              |          |            |          |
#              |10.0.0.1  |            |10.0.0.2  |
#              +----------+            +----------+
#
# Physical NICs are moved directly into network namespaces.
# Traffic traverses ONLY the physical DAC and Kernel network stack.
# ============================================================

set -u

# ============================================================
# Configuration
# ============================================================

## If: NVIDIA's performance tuning utilities is used ( set_irq_affinity.sh script ) Do not use taskset with MASK_S1/MASK_S2
## $ sudo set_irq_affinity.sh enp1s0f0np0 
## $ sudo set_irq_affinity.sh enP2p1s0f1np1
#  Else:
## use MASK_S1 and MASK_S2 if using taskset for pinning 
## Do not use MASK_S1 and MASK_S2 if Nvidia 
MASK_S1="5-9"
MASK_S2="15-19"
IRQ_BAN="5,6,7,8,9,15,16,17,18,19"

# Physical NICs
LEFT_IF="enp1s0f0np0"
RIGHT_IF="enP2p1s0f1np1"

# Network namespaces
LEFT_NS="left-ns"
RIGHT_NS="right-ns"

# Test IP addresses
LEFT_IP="10.0.0.1"
RIGHT_IP="10.0.0.2"
PREFIX="24"
MTU_VAL=9000

# Ping parameters
PING_COUNT=3
PING_TIMEOUT=1

# Persistent state flag
STATE_FILE="/run/pure-baremetal-topology.state"

# Throughput test configuration
IPERF_DURATION=30
IPERF_TCP_STREAMS=10
#IPERF_UDP_BANDWIDTH="100G"
IPERF_UDP_BANDWIDTH="0"
IPERF_UDP_LENGTH=8948
IPERF_UDP_STREAMS=10

# Output directory
RESULTS_DIR="./results"
SUMMARY_FILE="${RESULTS_DIR}/summary.json"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Logging
log_info()  { echo -e "${BLUE}[INFO]${NC} $*"; }
log_ok()    { echo -e "${GREEN}[ OK ]${NC} $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }

pause_screen() {
    echo
    read -r -p "Press ENTER to continue..."
}

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
    command -v sysctl >/dev/null 2>&1 || missing+=("sysctl")

    if [[ ${#missing[@]} -gt 0 ]]; then
        log_error "Missing required commands: ${missing[*]}"
        exit 1
    fi
}

set_setup_flag()   { echo "SETUP_COMPLETE=1" > "${STATE_FILE}"; }
clear_setup_flag() { rm -f "${STATE_FILE}"; }
is_setup()         { [[ -f "${STATE_FILE}" ]] && grep -q '^SETUP_COMPLETE=1$' "${STATE_FILE}"; }

require_setup() {
    if ! is_setup; then
        log_error "Topology is not configured. Run Setup first."
        return 1
    fi
    return 0
}

interface_exists_in_ns() {
    local ns="$1"
    local dev="$2"
    ip netns exec "${ns}" ip link show "${dev}" >/dev/null 2>&1
}

namespace_exists() {
    ip netns list | awk '{print $1}' | grep -qx "$1"
}

apply_system_tuning() {
    log_info "Applying system performance and kernel tunings..."

    # 1. Huge pages configuration (2048 x 2MB = 4GB)
    log_info "Allocating 2048 hugepages (2MB each)..."
    echo 2048 > /proc/sys/vm/nr_hugepages

    cpupower frequency-set -g performance

    ethtool -G ${LEFT_IF} rx 8192 tx 8192
    ethtool -G ${RIGHT_IF} rx 8192 tx 8192


    
    # 2. BBR Congestion Control & Fair Queueing
    log_info "Enabling BBR congestion control and FQ qdisc..."
    sysctl -w net.core.default_qdisc="fq" >/dev/null
    sysctl -w net.ipv4.tcp_congestion_control="bbr" >/dev/null

    # 3. Expanding TCP Windows & Socket Buffers for high-speed paths
    log_info "Expanding TCP windows and socket buffer limits..."
    #sysctl -w net.core.rmem_max=67108864 >/dev/null
    sysctl -w net.core.rmem_max=134217728 >/dev/null
    #sysctl -w net.core.wmem_max=67108864 >/dev/null
    sysctl -w net.core.wmem_max=134217728 >/dev/null
    sysctl -w net.core.rmem_default=33554432 >/dev/null
    sysctl -w net.core.wmem_default=33554432 >/dev/null
    #sysctl -w net.ipv4.tcp_rmem="4096 87380 33554432" >/dev/null
    sysctl -w net.ipv4.tcp_rmem="4096 87380  134217728" >/dev/null
    #sysctl -w net.ipv4.tcp_wmem="4096 65536 33554432" >/dev/null
    sysctl -w net.ipv4.tcp_wmem="4096 65536 134217728" >/dev/null
    sysctl -w net.core.netdev_max_backlog=250000 >/dev/null
    sudo sync && echo 3 | sudo tee /proc/sys/vm/drop_caches


    log_ok "System tuning parameters successfully applied."
}

reset_topology() {
    echo
    echo "============================================================"
    echo " Resetting Pure Bare-Metal Topology"
    echo "============================================================"
    echo
    clear_setup_flag

    for pair in "${LEFT_NS}:${LEFT_IF}" "${RIGHT_NS}:${RIGHT_IF}"; do
        IFS=":" read -r ns dev <<< "${pair}"
        if namespace_exists "${ns}" && interface_exists_in_ns "${ns}" "${dev}"; then
            log_info "Returning interface ${dev} to host root namespace..."
            ip netns exec "${ns}" ip link set "${dev}" netns 1 2>/dev/null || true
        fi
    done

    for ns in "${LEFT_NS}" "${RIGHT_NS}"; do
        if namespace_exists "${ns}"; then
            ip netns delete "${ns}"
            log_ok "Deleted namespace ${ns}"
        fi
    done

    for dev in "${LEFT_IF}" "${RIGHT_IF}"; do
        if ip link show "${dev}" >/dev/null 2>&1; then
            ip addr flush dev "${dev}" 2>/dev/null || true
            ip link set "${dev}" down 2>/dev/null || true
        fi
    done

    log_ok "Pure bare-metal topology cleared."
}

create_topology() {
    echo
    echo "============================================================"
    echo " Creating Pure Bare-Metal Topology (No OVS)"
    echo "============================================================"
    echo

    reset_topology

    # Apply performance tunings before bringing up interfaces and tests
    apply_system_tuning

    if ! ip link show "${LEFT_IF}" >/dev/null 2>&1 || ! ip link show "${RIGHT_IF}" >/dev/null 2>&1; then
        log_error "One or both physical NICs (${LEFT_IF}, ${RIGHT_IF}) not found in host root namespace."
        return 1
    fi

    ip netns add "${LEFT_NS}"
    ip netns add "${RIGHT_NS}"

    log_info "Moving physical interfaces to namespaces..."
    ip link set "${LEFT_IF}" netns "${LEFT_NS}"
    ip link set "${RIGHT_IF}" netns "${RIGHT_NS}"

    log_info "Configuring IP addresses and MTU ${MTU_VAL}..."
    ip netns exec "${LEFT_NS}" ip link set "${LEFT_IF}" mtu "${MTU_VAL}"
    ip netns exec "${LEFT_NS}" ip addr add "${LEFT_IP}/${PREFIX}" dev "${LEFT_IF}"
    ip netns exec "${LEFT_NS}" ip link set "${LEFT_IF}" up
    ip netns exec "${LEFT_NS}" ip link set lo up

    ip netns exec "${RIGHT_NS}" ip link set "${RIGHT_IF}" mtu "${MTU_VAL}"
    ip netns exec "${RIGHT_NS}" ip addr add "${RIGHT_IP}/${PREFIX}" dev "${RIGHT_IF}"
    ip netns exec "${RIGHT_NS}" ip link set "${RIGHT_IF}" up
    ip netns exec "${RIGHT_NS}" ip link set lo up

    set_setup_flag
    log_ok "Pure Bare-Metal setup complete."
    return 0
}

ping_one_way() {
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

    ip netns exec "${source_ns}" ping -c "${PING_COUNT}" -W "${PING_TIMEOUT}" "${destination_ip}"
    if [[ $? -eq 0 ]]; then
        log_ok "${direction} ping successful"
        return 0
    fi
    log_error "${direction} ping FAILED"
    return 1
}

perform_ping_test() {
    require_setup || return 1
    local failed=0
    ping_one_way "${LEFT_NS}" "${RIGHT_IP}" "LEFT -> RIGHT" || failed=1
    ping_one_way "${RIGHT_NS}" "${LEFT_IP}" "RIGHT -> LEFT" || failed=1
    [[ "${failed}" -eq 0 ]] && log_ok "BIDIRECTIONAL PING TEST PASSED" || log_error "BIDIRECTIONAL PING TEST FAILED"
}

get_ping_rtt_ms() {
    ip netns exec "$1" ping -c 5 -W 1 "$2" 2>/dev/null | awk -F'/' '/^rtt|^round-trip/ {print $5; exit}'
}

start_iperf_server() {
    log_info "Starting iperf3 server in ${RIGHT_NS}"
    ##ip netns exec "${RIGHT_NS}" taskset -c ${MASK_S2} iperf3 -s > /tmp/iperf3-server.log 2>&1 &
    ip netns exec "${RIGHT_NS}" iperf3 -s > /tmp/iperf3-server.log 2>&1 &
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

stop_iperf_server() {
    if [[ -n "${IPERF_SERVER_PID:-}" ]]; then
        kill "${IPERF_SERVER_PID}" 2>/dev/null || true
        wait "${IPERF_SERVER_PID}" 2>/dev/null || true
        unset IPERF_SERVER_PID
    fi
    ip netns exec "${RIGHT_NS}" pkill -x iperf3 2>/dev/null || true
}

read_cpu_stat() {
    awk '/^cpu / {total=$2+$3+$4+$5+$6+$7+$8+$9; idle=$5+$6; print total, idle; exit}' /proc/stat
}

get_cpu_busy_percent() {
    local total_delta=$(($3 - $1))
    local idle_delta=$(($4 - $2))
    if [[ "${total_delta}" -le 0 ]]; then echo "0.00"; return; fi
    awk -v total="${total_delta}" -v idle="${idle_delta}" 'BEGIN {printf "%.2f", ((total-idle)/total)*100}'
}

perform_throughput_test() {
    require_setup || return 1

    echo
    echo "============================================================"
    echo " Pure Bare-Metal Throughput Test"
    echo "============================================================"
    echo
    echo "Path:"
    echo " ${LEFT_NS} (${LEFT_IF}) -> DAC -> ${RIGHT_NS} (${RIGHT_IF})"
    echo

    mkdir -p "${RESULTS_DIR}"
    local timestamp="$(date '+%Y-%m-%d %H:%M:%S %Z')"
    local timestamp_file="$(date '+%Y%m%d-%H%M%S')"
    local test_dir="${RESULTS_DIR}/pure-baremetal-${timestamp_file}"
    mkdir -p "${test_dir}"

    local tcp_json="${test_dir}/tcp.json"
    local udp_json="${test_dir}/udp.json"

    log_info "Checking connectivity before throughput test..."
    if ! ip netns exec "${LEFT_NS}" ping -c 3 -W 1 "${RIGHT_IP}" >/dev/null 2>&1; then
        log_error "Connectivity test failed."
        return 1
    fi
    log_ok "Connectivity test passed"

    log_info "Measuring ICMP RTT..."
    local rtt_ms="$(get_ping_rtt_ms "${LEFT_NS}" "${RIGHT_IP}")"
    if [[ -z "${rtt_ms}" ]]; then
        rtt_ms="0"
        log_warn "Could not determine RTT"
    else
        log_ok "ICMP RTT: ${rtt_ms} ms"
    fi

    start_iperf_server || return 1
    trap stop_iperf_server RETURN

    # TCP Test
    echo
    echo "------------------------------------------------------------"
    echo " TCP throughput"
    echo "------------------------------------------------------------"
    echo "Duration       : ${IPERF_DURATION}s"
    echo "TCP streams    : ${IPERF_TCP_STREAMS}"
    echo

    read -r tcp_start_total tcp_start_idle <<< "$(read_cpu_stat)"
    #ip netns exec "${LEFT_NS}" taskset -c ${MASK_S1} iperf3 -c "${RIGHT_IP}" -t "${IPERF_DURATION}" -P "${IPERF_TCP_STREAMS}" -Z -J > "${tcp_json}"
    ip netns exec "${LEFT_NS}" iperf3 -c "${RIGHT_IP}" -t "${IPERF_DURATION}" -P "${IPERF_TCP_STREAMS}" -Z -J > "${tcp_json}"
    local tcp_result=$?
    read -r tcp_end_total tcp_end_idle <<< "$(read_cpu_stat)"

    if [[ "${tcp_result}" -ne 0 ]]; then
        log_error "TCP iperf3 test failed"
        cat "${tcp_json}"
        return 1
    fi

    local tcp_bps="$(jq -r '.end.sum_received.bits_per_second // .end.sum_sent.bits_per_second // 0' "${tcp_json}")"
    local tcp_gbps="$(awk -v bps="${tcp_bps}" 'BEGIN { printf "%.2f", bps/1000000000 }')"
    local tcp_cpu_busy="$(get_cpu_busy_percent "${tcp_start_total}" "${tcp_start_idle}" "${tcp_end_total}" "${tcp_end_idle}")"

    log_ok "TCP throughput: ${tcp_gbps} Gbps"
    log_info "Host CPU busy: ${tcp_cpu_busy}%"

    # UDP Test
    echo
    echo "------------------------------------------------------------"
    echo " UDP throughput"
    echo "------------------------------------------------------------"
    echo "Duration       : ${IPERF_DURATION}s"
    echo "UDP bandwidth  : ${IPERF_UDP_BANDWIDTH}"
    echo "Packet length  : ${IPERF_UDP_LENGTH}"
    echo "UDP streams    : ${IPERF_UDP_STREAMS}"
    echo

    read -r udp_start_total udp_start_idle <<< "$(read_cpu_stat)"
    #ip netns exec "${LEFT_NS}" taskset -c ${MASK_S1} iperf3 -c "${RIGHT_IP}" -u -t "${IPERF_DURATION}" -l "${IPERF_UDP_LENGTH}" -P "${IPERF_UDP_STREAMS}" -b "${IPERF_UDP_BANDWIDTH}" -Z -J > "${udp_json}"
    ip netns exec "${LEFT_NS}" iperf3 -c "${RIGHT_IP}" -u -t "${IPERF_DURATION}" -l "${IPERF_UDP_LENGTH}" -P "${IPERF_UDP_STREAMS}" -b "${IPERF_UDP_BANDWIDTH}" -Z -J > "${udp_json}"
    local udp_result=$?
    read -r udp_end_total udp_end_idle <<< "$(read_cpu_stat)"

    if [[ "${udp_result}" -ne 0 ]]; then
        log_error "UDP iperf3 test failed"
        cat "${udp_json}"
        return 1
    fi

    local udp_bps="$(jq -r '.end.sum_received.bits_per_second // .end.sum.bits_per_second // 0' "${udp_json}")"
    local udp_jitter="$(jq -r '.end.sum_received.jitter_ms // .end.sum.jitter_ms // .end.sum_sent.jitter_ms // 0' "${udp_json}")"
    local udp_packets="$(jq -r '.end.sum_received.packets // 0' "${udp_json}")"
    local udp_seconds="$(jq -r '.end.sum_received.seconds // .end.sum.seconds // 0' "${udp_json}")"
    local udp_loss="$(jq -r '.end.sum_received.lost_percent // .end.sum.lost_percent // 0' "${udp_json}")"

    local udp_gbps="$(awk -v bps="${udp_bps}" 'BEGIN { printf "%.2f", bps/1000000000 }')"
    local udp_pps="$(awk -v packets="${udp_packets}" -v seconds="${udp_seconds}" 'BEGIN { if (seconds > 0) printf "%.0f", packets/seconds; else printf "0" }')"
    udp_loss="$(awk -v loss="${udp_loss}" 'BEGIN { printf "%.3f", loss }')"
    udp_jitter="$(awk -v jitter="${udp_jitter}" 'BEGIN { printf "%.6f", jitter }')"
    local udp_cpu_busy="$(get_cpu_busy_percent "${udp_start_total}" "${udp_start_idle}" "${udp_end_total}" "${udp_end_idle}")"

    log_ok "UDP throughput: ${udp_gbps} Gbps"
    log_ok "UDP PPS: ${udp_pps}"
    log_ok "UDP loss: ${udp_loss}%"
    log_info "Host CPU busy: ${udp_cpu_busy}%"

    cat > "${SUMMARY_FILE}" <<EOF
{
  "test_type": "pure_baremetal_no_ovs",
  "timestamp": "${timestamp}",
  "left_interface": "${LEFT_IF}",
  "right_interface": "${RIGHT_IF}",
  "left_namespace": "${LEFT_NS}",
  "right_namespace": "${RIGHT_NS}",
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
  "note": "host_cpu_busy_pct is aggregate host CPU utilization during the TCP test."
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

    log_ok "Pure bare-metal throughput test completed"
    return 0
}

reset_host_and_quit() {
    reset_topology
    if command -v nmcli >/dev/null 2>&1; then
        nmcli device set "${LEFT_IF}" managed yes 2>/dev/null || true
        nmcli device set "${RIGHT_IF}" managed yes 2>/dev/null || true
    fi
    ip link set "${LEFT_IF}" mtu 1500 up
    ip link set "${RIGHT_IF}" mtu 1500 up
    exit 0
}

show_menu() {
    clear
    echo "============================================================"
    echo "    PURE BARE-METAL (NO OVS) DAC CROSSOVER TEST"
    echo "============================================================"
    echo "    ${LEFT_NS} (${LEFT_IF}) <---> ${RIGHT_NS} (${RIGHT_IF})"
    echo "------------------------------------------------------------"
    if is_setup; then
        echo -e "Topology state: ${GREEN}SETUP COMPLETE${NC}"
    else
        echo -e "Topology state: ${YELLOW}NOT CONFIGURED${NC}"
    fi
    echo "------------------------------------------------------------"
    echo "  1) Setup"
    echo "  2) Reset system"
    echo "  3) Ping test"
    echo "  4) Bare-metal throughput"
    echo "  5) Reset host and quit"
    echo "  6) Quit"
    echo "============================================================"
}

main() {
    require_root
    check_dependencies

    while true; do
        show_menu
        read -r -p "Select option [1-6]: " choice
        case "${choice}" in
            1) create_topology; pause_screen ;;
            2) reset_topology; pause_screen ;;
            3) perform_ping_test; pause_screen ;;
            4) perform_throughput_test; pause_screen ;;
            5) reset_host_and_quit ;;
            6) exit 0 ;;
            *) log_error "Invalid choice"; pause_screen ;;
        esac
    done
}

main "$@"
