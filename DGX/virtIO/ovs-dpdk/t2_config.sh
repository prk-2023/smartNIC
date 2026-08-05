#!/usr/bin/env bash
# t2_config.sh — shared config for the t2 test setup: VM1<->VM2 over ConnectX-7 PF0/PF1,
# via virtio-net/vhost-net bridges (NOT PCI passthrough — see topology diagram).
# Source this from every other t2_*.sh script: source "$(dirname "$0")/t2_config.sh"
# Do not execute directly.

### ---- Physical topology (test path) ----
# PF0 -- br-left  -- vnet0 -- VM1's virtio-net test NIC
# PF1 -- br-right -- vnet1 -- VM2's virtio-net test NIC
# PF0 <===== DAC =====> PF1  (external crossover cable)
PF0="enp1s0f0np0"
PF1="enp1s0f1np1"
BR_LEFT="br-left"
BR_RIGHT="br-right"
TAP_LEFT="vnet0"
TAP_RIGHT="vnet1"
TAP_USER="$(whoami)"

### ---- Management path (QEMU user-mode/SLIRP — no host bridge or iptables needed) ----
# Each VM's mgmt NIC uses QEMU's built-in SLIRP networking: internet access, DNS, and NAT
# all work automatically with zero host config. SSH reachability comes from QEMU's own
# hostfwd, not a host iptables DNAT rule - nothing on the host to set up or tear down.
SSH_DNAT_PORT_VM1=2201                # ssh -p 2201 bench@<dgx-ip>  -> VM1:22 (via QEMU hostfwd)
SSH_DNAT_PORT_VM2=2202                # ssh -p 2202 bench@<dgx-ip>  -> VM2:22 (via QEMU hostfwd)

### ---- Test-path VM IPs (static — same subnet, since br-left<->DAC<->br-right is one L2 domain) ----
VM1_TEST_IP="192.168.100.11"
VM2_TEST_IP="192.168.100.12"
TEST_PREFIX="24"

### ---- Test-path MACs (assigned at qemu launch time; matched by cloud-init netplan) ----
VM1_TEST_MAC="52:54:00:9a:00:01"
VM2_TEST_MAC="52:54:00:9a:00:02"

### ---- Mgmt-path static addressing (QEMU SLIRP subnet, not DHCP) ----
MGMT_NET="10.10.10.0/24"      # matches QEMU -netdev user,net= below
MGMT_GW="10.10.10.2"           # SLIRP's own default gateway convention for this subnet (net+2) - matches QEMU -netdev user,host=
MGMT_DNS="23.216.52.56"
MGMT_DHCPSTART_VM1="10.10.10.15"   # matches QEMU -netdev user,dhcpstart= for VM1
MGMT_DHCPSTART_VM2="10.10.10.16"   # matches QEMU -netdev user,dhcpstart= for VM2
MGMT_MAC_VM1="52:54:00:9a:01:01"
MGMT_MAC_VM2="52:54:00:9a:01:02"

### ---- Guest identity ----
GUEST_USER="bench"
GUEST_PASSWORD="test1234"     # password auth left on as fallback
SSH_PUBKEY_FILE="${SSH_PUBKEY_FILE:-$HOME/.ssh/id_rsa.pub}"   # override: SSH_PUBKEY_FILE=/path ./t2_build_guest_image.sh 1

### ---- VM resources (both VMs run concurrently — hugepages/CPU pins must cover BOTH) ----
VM_VCPUS=4
VM_MEM="2G"
HUGEPAGE_SIZE_KB=2048          # VERIFY against `ls /sys/kernel/mm/hugepages/` — t2_perf_status.sh checks this
HUGEPAGES_PER_VM=$(( $(echo "${VM_MEM}" | sed 's/G//') * 1024 * 1024 / HUGEPAGE_SIZE_KB ))
TOTAL_HUGEPAGES=$(( HUGEPAGES_PER_VM * 2 ))   # 2 VMs concurrently

### ---- UEFI firmware (aarch64 requirement) ----
AAVMF_CODE=/usr/share/AAVMF/AAVMF_CODE.fd
AAVMF_VARS_TEMPLATE=/usr/share/AAVMF/AAVMF_VARS.fd
GIC_VERSION=3    # matches this DGX's confirmed GICv3/VHE (sudo dmesg | grep -i kvm)

### ---- Working paths ----
T2_WORKDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_IMAGE="quay.io/containerdisks/fedora:43"   # multi-arch (amd64+arm64)

### ---- OVS-DPDK config ----
# PF PCI addresses (dpdk-devargs) - confirmed earlier via: devlink dev show
PF0_PCI="0000:01:00.0"
PF1_PCI="0000:01:00.1"

# OVS-DPDK's OWN hugepage-backed memory (separate from each VM's -object memory-backend-file
# allocation - both draw from the same system hugepage pool, so this adds to TOTAL_HUGEPAGES
# below, it doesn't share with the VMs' allocation).
DPDK_SOCKET_MEM_MB=1024      # VERIFY NUMA node count first (numactl -H) - this assumes single-node
DPDK_HUGEPAGES=$(( DPDK_SOCKET_MEM_MB * 1024 / HUGEPAGE_SIZE_KB ))
TOTAL_HUGEPAGES=$(( TOTAL_HUGEPAGES + DPDK_HUGEPAGES ))   # extends the VM-only total from above

# !!! PLACEHOLDERS - fill in after `lscpu -e` (see t2_perf_status.sh output). PMD poll threads
# busy-poll (100% CPU each) and must NOT overlap with VCPU_PIN/vhost pins in t2_launch_vm.sh,
# or with each other. DPDK_LCORE_MASK is the single control-thread core; PMD_CPU_MASK is a hex
# bitmask (not a core list) covering however many cores you dedicate to packet polling.
DPDK_LCORE_MASK="0x1"            # e.g. "0x1" for core 0 - fill in after checking topology
PMD_CPU_MASK="0x6"                # e.g. "0x6" for cores 1+2 - fill in after checking topology

# vhost-user client sockets - OVS connects OUT to these (QEMU listens as server). Path must
# match between t2_host_setup.sh (creates the OVS port pointing at this path) and
# t2_launch_vm.sh (QEMU's -chardev socket,path=... ,server=on).
VHOST_SOCK_DIR="/tmp/t2-vhost"
VHOST_SOCK_VM1="${VHOST_SOCK_DIR}/vhost-user-vm1"
VHOST_SOCK_VM2="${VHOST_SOCK_DIR}/vhost-user-vm2"
