#!/usr/bin/env bash
#
# mlx5-eswitch-manager.sh
#
# Interactive helper for ConnectX (mlx5) NICs:
#   - Detects mlx5 PF interfaces and their PCI BDFs
#   - Shows current eSwitch mode per interface
#   - Create / delete SR-IOV VFs per interface
#   - Toggle eSwitch mode (legacy / switchdev) per interface
#   - Reset everything (VFs=0, mode=legacy) and stay, or reset+quit, or quit
#
# Tested target: NVIDIA GB10-class platforms with multiple ConnectX PFs
# (e.g. enp1s0f0np0, enp1s0f1np1, enP2p1s0f0np0, enP2p1s0f1np1)
#
# Requires: bash, iproute2, devlink (iproute2), root privileges.

set -uo pipefail

# ---------- helpers ----------------------------------------------------

RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[0;33m'
CYAN=$'\033[0;36m'; BOLD=$'\033[1m'; RESET=$'\033[0m'

die() { echo "${RED}Error:${RESET} $*" >&2; exit 1; }
info() { echo "${CYAN}$*${RESET}"; }
ok() { echo "${GREEN}$*${RESET}"; }
warn() { echo "${YELLOW}$*${RESET}"; }

need_root() {
    if [[ $EUID -ne 0 ]]; then
        die "This script must be run as root (sudo)."
    fi
}

need_bin() {
    command -v "$1" >/dev/null 2>&1 || die "Required tool '$1' not found in PATH."
}

pause() { read -rp "Press Enter to continue..." _; }

# ---------- discovery ----------------------------------------------------

# Parallel arrays, index-aligned:
#   IFACES[i]  -> netdev name        (e.g. enp1s0f0np0)
#   PCIS[i]    -> PCI BDF            (e.g. 0000:01:00.0)
#   MODES[i]   -> eswitch mode       (legacy / switchdev / unknown)
#   NUMVFS[i]  -> current sriov_numvfs
#   TOTVFS[i]  -> sriov_totalvfs (max supported)
IFACES=()
PCIS=()
MODES=()
NUMVFS=()
TOTVFS=()

detect_interfaces() {
    IFACES=(); PCIS=(); MODES=(); NUMVFS=(); TOTVFS=()

    local iface devpath driver pci numvfs totvfs mode

    for netdir in /sys/class/net/*; do
        iface=$(basename "$netdir")
        devpath="$netdir/device"

        [[ -e "$devpath" ]] || continue

        # Skip VF representors / VF netdevs: a PF has no 'physfn' symlink.
        [[ -e "$devpath/physfn" ]] && continue

        # Only interested in mlx5_core devices.
        driver=""
        if [[ -e "$devpath/driver" ]]; then
            driver=$(basename "$(readlink -f "$devpath/driver")")
        fi
        [[ "$driver" == "mlx5_core" ]] || continue

        # A real PF exposes sriov_totalvfs. Representors / other mlx5
        # aux devices won't have it, so this doubles as a PF filter.
        [[ -e "$devpath/sriov_totalvfs" ]] || continue

        pci=$(basename "$(readlink -f "$devpath")")
        numvfs=$(cat "$devpath/sriov_numvfs" 2>/dev/null || echo "?")
        totvfs=$(cat "$devpath/sriov_totalvfs" 2>/dev/null || echo "?")

        mode=$(devlink dev eswitch show "pci/$pci" 2>/dev/null \
                 | grep -oE 'mode (legacy|switchdev)' | awk '{print $2}')
        [[ -z "$mode" ]] && mode="unknown"

        IFACES+=("$iface")
        PCIS+=("$pci")
        MODES+=("$mode")
        NUMVFS+=("$numvfs")
        TOTVFS+=("$totvfs")
    done

    if [[ ${#IFACES[@]} -eq 0 ]]; then
        warn "No mlx5 PF interfaces detected."
    fi
}

print_table() {
    detect_interfaces
    echo
    printf "${BOLD}%-4s %-16s %-14s %-10s %-8s %-8s${RESET}\n" \
        "#" "INTERFACE" "PCI BDF" "ESWITCH" "NUMVFS" "MAXVFS"
    printf '%.0s-' {1..64}; echo
    local i
    for i in "${!IFACES[@]}"; do
        local modecolor="$RESET"
        [[ "${MODES[$i]}" == "switchdev" ]] && modecolor="$GREEN"
        [[ "${MODES[$i]}" == "legacy" ]] && modecolor="$YELLOW"
        printf "%-4s %-16s %-14s ${modecolor}%-10s${RESET} %-8s %-8s\n" \
            "$((i+1))" "${IFACES[$i]}" "${PCIS[$i]}" "${MODES[$i]}" \
            "${NUMVFS[$i]}" "${TOTVFS[$i]}"
    done
    echo
}

select_interface() {
    # Prints prompt, returns chosen index via echo (caller captures it).
    local i choice
    print_table >&2
    read -rp "Select interface # (or 0 to cancel): " choice
    if [[ ! "$choice" =~ ^[0-9]+$ ]] || (( choice < 0 || choice > ${#IFACES[@]} )); then
        echo "-1"
        return
    fi
    if (( choice == 0 )); then
        echo "-1"
        return
    fi
    echo "$((choice-1))"
}

# ---------- actions ----------------------------------------------------

manage_vfs() {
    local idx
    idx=$(select_interface)
    [[ "$idx" == "-1" ]] && return

    local iface="${IFACES[$idx]}" pci="${PCIS[$idx]}"
    local devpath="/sys/class/net/$iface/device"
    local cur max
    cur=$(cat "$devpath/sriov_numvfs" 2>/dev/null || echo 0)
    max=$(cat "$devpath/sriov_totalvfs" 2>/dev/null || echo 0)

    echo
    info "Interface: $iface  ($pci)"
    echo "Current VFs: $cur   Max supported: $max"
    echo
    echo "  1) Create / set VF count"
    echo "  2) Delete all VFs (set to 0)"
    echo "  0) Back"
    read -rp "Choice: " sub

    case "$sub" in
        1)
            read -rp "Number of VFs to create (0-$max): " n
            if [[ ! "$n" =~ ^[0-9]+$ ]] || (( n > max )); then
                warn "Invalid VF count."
                pause; return
            fi
            if (( cur > 0 )); then
                warn "Existing VFs present, clearing first (echo 0)..."
                echo 0 | tee "$devpath/sriov_numvfs" >/dev/null
            fi
            echo "$n" | tee "$devpath/sriov_numvfs" >/dev/null \
                && ok "Set sriov_numvfs=$n on $iface" \
                || warn "Failed to set VF count. Check dmesg."
            ;;
        2)
            echo 0 | tee "$devpath/sriov_numvfs" >/dev/null \
                && ok "Deleted all VFs on $iface" \
                || warn "Failed to clear VFs. Check dmesg."
            ;;
        0) return ;;
        *) warn "Invalid choice." ;;
    esac
    pause
}

toggle_eswitch_mode() {
    local idx
    idx=$(select_interface)
    [[ "$idx" == "-1" ]] && return

    local iface="${IFACES[$idx]}" pci="${PCIS[$idx]}" mode="${MODES[$idx]}"
    local devpath="/sys/class/net/$iface/device"
    local cur
    cur=$(cat "$devpath/sriov_numvfs" 2>/dev/null || echo 0)

    echo
    info "Interface: $iface  ($pci)   Current eSwitch mode: $mode"

    local target
    if [[ "$mode" == "legacy" ]]; then
        target="switchdev"
    elif [[ "$mode" == "switchdev" ]]; then
        target="legacy"
    else
        echo "  1) Set legacy"
        echo "  2) Set switchdev"
        echo "  0) Back"
        read -rp "Choice: " sub
        case "$sub" in
            1) target="legacy" ;;
            2) target="switchdev" ;;
            *) return ;;
        esac
    fi

    read -rp "Switch $iface from '$mode' to '$target'? [y/N]: " confirm
    [[ "$confirm" =~ ^[Yy]$ ]] || return

    if (( cur > 0 )); then
        warn "VFs are currently active ($cur). They must be unbound/cleared"
        warn "before the mode can change. Clearing VFs on $iface..."
        echo 0 | tee "$devpath/sriov_numvfs" >/dev/null
    fi

    if devlink dev eswitch set "pci/$pci" mode "$target" 2>/tmp/esw_err; then
        ok "Set eswitch mode '$target' on $iface ($pci)"
    else
        warn "Failed to set mode. Driver said:"
        cat /tmp/esw_err >&2
    fi
    pause
}

reset_all() {
    local quiet="${1:-0}"
    detect_interfaces
    local i
    for i in "${!IFACES[@]}"; do
        local iface="${IFACES[$i]}" pci="${PCIS[$i]}"
        local devpath="/sys/class/net/$iface/device"
        local cur
        cur=$(cat "$devpath/sriov_numvfs" 2>/dev/null || echo 0)

        if (( cur > 0 )); then
            echo 0 | tee "$devpath/sriov_numvfs" >/dev/null 2>&1
            [[ "$quiet" == "0" ]] && ok "Cleared VFs on $iface"
        fi

        devlink dev eswitch set "pci/$pci" mode legacy >/dev/null 2>&1
        [[ "$quiet" == "0" ]] && ok "Set eswitch mode legacy on $iface"
    done
    [[ "$quiet" == "0" ]] && ok "Reset complete: all VFs removed, all interfaces set to legacy."
}

# ---------- main menu ----------------------------------------------------

main_menu() {
    while true; do
        clear 2>/dev/null || true
        echo "${BOLD}=== ConnectX (mlx5) eSwitch / SR-IOV Manager ===${RESET}"
        print_table
        echo "  1) Refresh status"
        echo "  2) Manage VFs (create/delete) on an interface"
        echo "  3) Toggle eSwitch mode (legacy/switchdev) on an interface"
        echo "  4) Reset everything (VFs=0, mode=legacy) and stay in menu"
        echo "  5) Reset everything and quit"
        echo "  6) Quit (no reset)"
        echo
        read -rp "Choice: " choice
        case "$choice" in
            1) continue ;;
            2) manage_vfs ;;
            3) toggle_eswitch_mode ;;
            4)
                read -rp "Reset ALL interfaces (clear VFs, set legacy)? [y/N]: " c
                [[ "$c" =~ ^[Yy]$ ]] && reset_all
                pause
                ;;
            5)
                read -rp "Reset ALL interfaces and quit? [y/N]: " c
                if [[ "$c" =~ ^[Yy]$ ]]; then
                    reset_all
                    ok "Done. Exiting."
                    exit 0
                fi
                ;;
            6)
                echo "Exiting without changes."
                exit 0
                ;;
            *)
                warn "Invalid choice."
                pause
                ;;
        esac
    done
}

# ---------- entry point ----------------------------------------------------

need_root
need_bin devlink
need_bin ip

main_menu
