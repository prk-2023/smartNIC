#!/bin/bash
set -euo pipefail

### ---- Args ----
# Usage: ./build_sriov_vm_image.sh <vm_name> <mgmt_ip> <mgmt_mac> <vf_ip> <vf_mac>
VM_NAME="${1:?Usage: $0 <vm_name> <mgmt_ip> <mgmt_mac> <vf_ip> <vf_mac>}"
MGMT_IP="${2:?missing mgmt_ip}"
MGMT_MAC="${3:?missing mgmt_mac}"
VF_IP="${4:?missing vf_ip}"
VF_MAC="${5:?missing vf_mac}"

# Validate MAC format - catches placeholder/typo'd values like "52:54:00:mm:mm:01"
# BEFORE they get silently baked into cloud-init and fail hours later with a
# confusing "no route to host". Real hex only, 6 colon-separated octets.
MAC_RE='^([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}$'
for name_val in "mgmt_mac:${MGMT_MAC}" "vf_mac:${VF_MAC}"; do
    name="${name_val%%:*}"; val="${name_val#*:}"
    [[ "${val}" =~ ${MAC_RE} ]] || { echo "ERROR: ${name} '${val}' is not a valid MAC address (expected format aa:bb:cc:dd:ee:ff)"; exit 1; }
done

### ---- Config ----
BASE_IMAGE="quay.io/containerdisks/fedora:41"
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

if [[ ! -f "${SSH_PUBKEY_PATH}" ]]; then
    echo "ERROR: SSH public key not found at ${SSH_PUBKEY_PATH}"
    exit 1
fi
GUEST_SSH_PUBKEY="$(cat "${SSH_PUBKEY_PATH}")"

mkdir -p "${WORKDIR}"

echo "===== Building image for ${VM_NAME} ====="

### ---- Step 1-2: reuse base image (shared across VM1/VM2, built once) ----
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
echo "  base format: ${BASE_FORMAT}"

### ---- Step 2.5: bake packages into base (shared, once) ----
CUSTOMIZE_MARKER="${WORKDIR}/.customized"
if [[ ! -f "${CUSTOMIZE_MARKER}" ]]; then
    echo "[2.5/5] Baking packages into base image"
    LIBGUESTFS_BACKEND=direct virt-customize -a "${BASE_IMG}" --install iperf3,sysstat,qperf 2>/dev/null \
        || echo "  virt-customize failed here - will run manually on each overlay at the end instead"
    touch "${CUSTOMIZE_MARKER}"
fi

### ---- Step 3: per-VM overlay ----
echo "[3/5] Creating overlay: ${OVERLAY_QCOW2}"
if [[ -f "${OVERLAY_QCOW2}" ]]; then
    echo "  already exists, skipping (delete it first for a fresh overlay)"
else
    qemu-img create -f qcow2 -F "${BASE_FORMAT}" -b "$(realpath "${BASE_IMG}")" "${OVERLAY_QCOW2}" "${DISK_SIZE}"
fi

### ---- Step 4: cloud-init, matched by MAC for both interfaces ----
echo "[4/5] Writing cloud-init config for ${VM_NAME}"
mkdir -p "cloud-init-${VM_NAME}"
cat > "cloud-init-${VM_NAME}/user-data" <<EOF
#cloud-config
hostname: ${VM_NAME}

users:
  - name: ${GUEST_USER}
    plain_text_passwd: ${GUEST_PASSWORD}
    lock_passwd: false
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    groups: wheel
    ssh_authorized_keys:
      - ${GUEST_SSH_PUBKEY}

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
      # no gateway/dns - point-to-point test path over the physical DAC loop

      [ipv6]
      method=disabled

  - path: /etc/systemd/system/iperf3-server.service
    permissions: '0644'
    content: |
      [Unit]
      Description=iperf3 server
      After=network-online.target
      Wants=network-online.target
      [Service]
      ExecStart=/usr/bin/iperf3 -s -p 5201
      Restart=always
      RestartSec=2
      [Install]
      WantedBy=multi-user.target

  - path: /etc/systemd/system/qperf-server.service
    permissions: '0644'
    content: |
      [Unit]
      Description=qperf server
      After=network-online.target
      Wants=network-online.target
      [Service]
      ExecStart=/usr/bin/qperf
      Restart=always
      RestartSec=2
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
      VF_IFACE=""
      for d in /sys/class/net/*/device/driver; do
        drv=\$(basename "\$(readlink -f "\$d")")
        if [ "\$drv" = "mlx5_core" ]; then
          VF_IFACE=\$(basename "\$(dirname "\$(dirname "\$d")")")
          break
        fi
      done
      mpstat -P ALL 1 "\${DURATION}" > "\${OUTDIR}/guest_cpu.log" &
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
      ExecStart=/usr/local/bin/guest-monitor.sh %i 70

runcmd:
  - [ chmod, '600', /etc/NetworkManager/system-connections/mgmt-static.nmconnection ]
  - [ chmod, '600', /etc/NetworkManager/system-connections/vf-static.nmconnection ]
  - [ systemctl, daemon-reload ]
  - [ nmcli, connection, reload ]
  - [ nmcli, connection, up, mgmt-static ]
  - [ nmcli, connection, up, vf-static ]
  - [ systemctl, enable, --now, iperf3-server.service ]
  - [ systemctl, enable, --now, qperf-server.service ]
  - [ mkdir, -p, /var/log/bench ]

final_message: "${VM_NAME} cloud-init finished - mgmt ${MGMT_IP}, VF ${VF_IP}"
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

echo "Installing packages into ${OVERLAY_QCOW2} (in case base-image bake was skipped/failed)"
LIBGUESTFS_BACKEND=direct virt-customize -a "${OVERLAY_QCOW2}" --install iperf3,sysstat,qperf 2>/dev/null \
    || sudo virt-customize -a "${OVERLAY_QCOW2}" --install iperf3,sysstat,qperf

echo
echo "Done: ${VM_NAME}"
echo "  Overlay : ${OVERLAY_QCOW2}"
echo "  Seed    : ${SEED_ISO}"
echo "  Mgmt IP : ${MGMT_IP}  (ssh ${GUEST_USER}@${MGMT_IP})"
echo "  VF IP   : ${VF_IP}    (test traffic path)"
