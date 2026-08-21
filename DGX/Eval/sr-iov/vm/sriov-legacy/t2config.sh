#!/usr/bin/env bash
# t2_config.sh — Shared configuration for SR-IOV Legacy Mode test setup

### ---- Physical Topology ----
# Direct DAC Cable between PF0 and PF1
PF0="enp1s0f0np0"
PF1="enp1s0f1np1"

### ---- SR-IOV & Network Settings ----
VF_NUM=0      # Index of VF to pass into each guest VM (VF 0)
MTU="9000"    # Jumbo frame MTU setting

### ---- Management Path (QEMU User Network SLIRP) ----
SSH_DNAT_PORT_VM1=2201                # ssh -p 2201 bench@<host-ip>
SSH_DNAT_PORT_VM2=2202                # ssh -p 2202 bench@<host-ip>

### ---- Guest Test Subnet Configuration ----
VM1_TEST_IP="192.168.100.11"
VM2_TEST_IP="192.168.100.12"
TEST_PREFIX="24"

# Hardware MAC addresses set on Host PF for VF 0
VM1_TEST_MAC="52:54:00:9a:00:01"
VM2_TEST_MAC="52:54:00:9a:00:02"

### ---- Management Subnet Configuration ----
MGMT_NET="10.10.10.0/24"
MGMT_GW="10.10.10.2"
MGMT_DHCPSTART_VM1="10.10.10.15"
MGMT_DHCPSTART_VM2="10.10.10.16"
MGMT_MAC_VM1="52:54:00:9a:01:01"
MGMT_MAC_VM2="52:54:00:9a:01:02"

### ---- Guest Identity ----
GUEST_USER="bench"
GUEST_PASSWORD="test1234"
SSH_PUBKEY_FILE="${SSH_PUBKEY_FILE:-$HOME/.ssh/id_rsa.pub}"

### ---- VM CPU & Memory Sizing ----
VM_VCPUS=4
VM_MEM="2G"
HUGEPAGE_SIZE_KB=2048
HUGEPAGES_PER_VM=$(( $(echo "${VM_MEM}" | sed 's/G//') * 1024 * 1024 / HUGEPAGE_SIZE_KB ))
TOTAL_HUGEPAGES=$(( HUGEPAGES_PER_VM * 2 ))

### ---- Firmware Paths (ARM64 Grace Blackwell / AAVMF) ----
AAVMF_CODE=/usr/share/AAVMF/AAVMF_CODE.fd
AAVMF_VARS_TEMPLATE=/usr/share/AAVMF/AAVMF_VARS.fd
GIC_VERSION=3

### ---- Working Directories & Images ----
T2_WORKDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_IMAGE="quay.io/containerdisks/fedora:43"
