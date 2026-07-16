#!/bin/bash
set -euo pipefail

# ============================================================================
# 02-build_virtio_vm_image.sh
# Builds a benchmark VM image (mgmt NIC + data NIC via cloud-init, iperf3/
# qperf servers, guest-monitor service). Same image/cloud-init used across
# the OVS-DPDK, OVS-kernel, and pure-virtio benchmark runs - only the host
# dataplane setup/launch scripts differ, so results are directly comparable.
# ============================================================================
VM_NAME="${1:?Usage: $0 <vm_name> <mgmt_ip> <mgmt_mac> <vf_ip> <vf_mac>}"
MGMT_IP="${2:?missing mgmt_ip}"
MGMT_MAC="${3:?missing mgmt_mac}"
VF_IP="${4:?missing vf_ip}"
VF_MAC="${5:?missing vf_mac}"

# Validate MAC format
MAC_RE='^([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}$'
for name_val in "mgmt_mac:${MGMT_MAC}" "vf_mac:${VF_MAC}"; do
    name="${name_val%%:*}"; val="${name_val#*:}"
    [[ "${val}" =~ ${MAC_RE} ]] || { echo "ERROR: ${name} '${val}' is not a valid MAC address"; exit 1; }
done

### ---- Config ----
BASE_IMAGE="quay.io/containerdisks/fedora:43"
WORKDIR="$(pwd)/guest-image"
BASE_IMG="${WORKDIR}/guest-base.img"
OVERLAY_QCOW2="./${VM_NAME}.qcow2"
SEED_ISO="./${VM_NAME}-seed.iso"
DISK_SIZE="20G"
GUEST_USER="bench"
GUEST_PASSWORD="test1234"
MGMT_PREFIX="24"
VF_PREFIX="24"
SSH_PUBKEY_PATH="${SSH_PUBKEY_PATH:-$HOME/.ssh/id_rsa.pub}"

# OPTIMIZATION: Bundled DPDK utility tools directly inside the VM image template
PACKAGES="iperf3,sysstat,qperf,dpdk,dpdk-tools,ethtool,pciutils"

if [[ ! -f "${SSH_PUBKEY_PATH}" ]]; then
    echo "ERROR: SSH public key not found at ${SSH_PUBKEY_PATH}"
    exit 1
fi
GUEST_SSH_PUBKEY="$(cat "${SSH_PUBKEY_PATH}")"

mkdir -p "${WORKDIR}"

echo "===== Building image for ${VM_NAME} ====="

### ---- Step 1-2: reuse base image ----
if [[ ! -f "${BASE_IMG}" ]]; then
    echo "[1-2/5] Base image missing - pulling and extracting"
    podman pull "${BASE_IMAGE}"
    CID=$(podman create "${BASE_IMAGE}")
    trap 'podman rm -f "${CID}" >/dev/null 2>&1 || true' EXIT
    DISK_PATH=$(podman export "${CID}" | tar -tv | awk '{print $NF}' | grep -E '^disk/disk\.(img|qcow2|raw)$' | head -n1)
    podman cp "${CID}:/${DISK_PATH#/}" "${BASE_IMG}"
    podman rm -f "${CID}" >/dev/null 2>&1 || true
    trap - ERR EXIT
else
    echo "[1-2/5] Base image already present, skipping"
fi

BASE_FORMAT=$(qemu-img info "${BASE_IMG}" | awk -F': ' '/^file format:/{print $2}')

### ---- Step 2.5: bake packages into base ----
CUSTOMIZE_MARKER="${WORKDIR}/.customized"
if [[ ! -f "${CUSTOMIZE_MARKER}" ]]; then
    echo "[2.5/5] Baking packages into base image"
    LIBGUESTFS_BACKEND=direct virt-customize -a "${BASE_IMG}" --install "${PACKAGES}" 2>/dev/null \
        || echo "  virt-customize failed here - will run manually on each overlay at the end instead"
    touch "${CUSTOMIZE_MARKER}"
fi

### ---- Step 3: per-VM overlay ----
echo "[3/5] Creating overlay: ${OVERLAY_QCOW2}"
if [[ -f "${OVERLAY_QCOW2}" ]]; then
    echo "  already exists, skipping"
else
    qemu-img create -f qcow2 -F "${BASE_FORMAT}" -b "$(realpath "${BASE_IMG}")" "${OVERLAY_QCOW2}" "${DISK_SIZE}"
fi

### ---- Step 4: cloud-init ----
echo "[4/5] Writing cloud-init config for ${VM_NAME}"
mkdir -p "cloud-init-${VM_NAME}"
cat > "cloud-init-${VM_NAME}/user-data" <<EOF
#cloud-config
hostname: ${VM_NAME}

users:
  - name: ${GUEST_USER}
    lock_passwd: false
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    groups: wheel
    ssh_authorized_keys:
      - ${GUEST_SSH_PUBKEY}

chpasswd:
  list: |
    ${GUEST_USER}:${GUEST_PASSWORD}
  expire: false

ssh_pwauth: true

write_files:
  - path: /etc/NetworkManager/system-connections/mgmt-static.nmconnection
    permissions: '0600'
    content: |
      [connection]
      id=mgmt-static
      type=ethernet
      autoconnect=true
      autoconnect-priority=999

      [ethernet]
      mac-address=${MGMT_MAC}

      [ipv4]
      method=manual
      address1=${MGMT_IP}/${MGMT_PREFIX}

      [ipv6]
      method=disabled

  - path: /etc/NetworkManager/system-connections/vf-static.nmconnection
    permissions: '0600'
    content: |
      [connection]
      id=vf-static
      type=ethernet
      autoconnect=true
      autoconnect-priority=999

      [ethernet]
      mac-address=${VF_MAC}

      [ipv4]
      method=manual
      address1=${VF_IP}/${VF_PREFIX}

      [ipv6]
      method=disabled

  - path: /etc/systemd/system/iperf3-server.service
    permissions: '0644'
    content: |
      [Unit]
      Description=iperf3 server
      After=network-online.target
      [Service]
      ExecStart=/usr/bin/iperf3 -s -p 5201
      Restart=always
      [Install]
      WantedBy=multi-user.target

  - path: /etc/systemd/system/qperf-server.service
    permissions: '0644'
    content: |
      [Unit]
      Description=qperf server
      After=network-online.target
      [Service]
      ExecStart=/usr/bin/qperf
      Restart=always
      [Install]
      WantedBy=multi-user.target

  - path: /usr/local/bin/guest-monitor.sh
    permissions: '0755'
    content: |
      #!/bin/bash
      RUN="\${1:-manual_run}"
      DURATION="\${2:-70}"
      OUTDIR="/var/log/bench/\${RUN}"
      mkdir -p "\${OUTDIR}"
      
      # OPTIMIZATION: Dynamic detection switched from mlx5_core to virtio_net matching the exact MAC
      VF_IFACE=""
      for d in /sys/class/net/*/device/driver; do
        drv=\$(basename "\$(readlink -f "\$d")")
        if [ "\$drv" = "virtio_net" ]; then
          cand_iface=\$(basename "\$(dirname "\$(dirname "\$d")")")
          cand_mac=\$(cat "/sys/class/net/\${cand_iface}/address")
          if [ "\${cand_mac,,}" = "${VF_MAC,,}" ]; then
            VF_IFACE="\${cand_iface}"
            break
          fi
        fi
      done
      
      mpstat -P ALL 1 "\${DURATION}" > "\${OUTDIR}/guest_cpu.log" &
      [ -n "\${VF_IFACE}" ] && ethtool -S "\${VF_IFACE}" > "\${OUTDIR}/ethtool_vf_before.txt" 2>/dev/null
      wait
      [ -n "\${VF_IFACE}" ] && ethtool -S "\${VF_IFACE}" > "\${OUTDIR}/ethtool_vf_after.txt" 2>/dev/null
      echo "guest monitor done: \${RUN}" > "\${OUTDIR}/DONE"

  - path: /etc/systemd/system/guest-monitor@.service
    permissions: '0644'
    content: |
      [Unit]
      Description=Guest-side monitoring for run %i
      [Service]
      Type=simple
      ExecStart=/usr/local/bin/guest-monitor.sh %i %I

runcmd:
  - [ chmod, '600', /etc/NetworkManager/system-connections/mgmt-static.nmconnection ]
  - [ chmod, '600', /etc/NetworkManager/system-connections/vf-static.nmconnection ]
  - [ systemctl, daemon-reload ]
  - [ nmcli, connection, reload ]
  - [ nmcli, connection, up, mgmt-static ]
  - [ nmcli, connection, up, vf-static ]
  - nmcli connection modify "Wired connection 1" connection.autoconnect no || true
  - [ systemctl, enable, --now, iperf3-server.service ]
  - [ systemctl, enable, --now, qperf-server.service ]
  - [ mkdir, -p, /var/log/bench ]

final_message: "${VM_NAME} cloud-init finished"
EOF

cat > "cloud-init-${VM_NAME}/meta-data" <<EOF
instance-id: ${VM_NAME}-$(date +%s)
local-hostname: ${VM_NAME}
EOF

### ---- Step 5: seed.iso ----
echo "[5/5] Building ${SEED_ISO}"
if command -v cloud-localds >/dev/null 2>&1; then
    cloud-localds "${SEED_ISO}" "cloud-init-${VM_NAME}/user-data" "cloud-init-${VM_NAME}/meta-data"
else
    genisoimage -output "${SEED_ISO}" -volid cidata -joliet -rock "cloud-init-${VM_NAME}/user-data" "cloud-init-${VM_NAME}/meta-data"
fi

LIBGUESTFS_BACKEND=direct virt-customize -a "${OVERLAY_QCOW2}" --install "${PACKAGES}" 2>/dev/null \
    || sudo virt-customize -a "${OVERLAY_QCOW2}" --install "${PACKAGES}"

echo "Done: ${VM_NAME}"
