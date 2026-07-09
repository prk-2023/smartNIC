#!/bin/bash
set -euo pipefail

### ---- Config ----
BASE_IMAGE="quay.io/containerdisks/fedora:41"
WORKDIR="$(pwd)/guest-image"
BASE_IMG="${WORKDIR}/guest-base.img"
OVERLAY_QCOW2="./guest.qcow2"
SEED_ISO="./seed.iso"
DISK_SIZE="20G"          # overlay virtual size cap; base image itself is small (cloud image, sparse)
GUEST_HOSTNAME="virtio-guest"
GUEST_USER="bench"
GUEST_PASSWORD="test1234"
GUEST_IP="192.168.100.10"
GUEST_PREFIX="24"
# NOTE: host-side counterpart (not managed by this script) - assign the matching
# subnet IP to the host interface that completes the DAC loopback path, e.g.:
#   sudo ip addr add 192.168.100.1/24 dev enp1s0f1np1
#   sudo ip link set enp1s0f1np1 up
# Do NOT put an IP on br0 itself - keep it pure L2 to avoid a same-subnet conflict.

mkdir -p "${WORKDIR}"

### ---- Step 1: Pull base containerdisk image ----
echo "[1/5] Pulling base image: ${BASE_IMAGE}"
podman pull "${BASE_IMAGE}"

### ---- Step 2: Extract qcow2 from the container ----
echo "[2/5] Extracting qcow2 from container"
# containerdisks images are FROM scratch - no shell, no entrypoint we can exec.
# Use 'create' (never runs anything) + 'export' (tars the rootfs) to find/extract the disk.
CID=$(podman create "${BASE_IMAGE}")
trap 'podman rm -f "${CID}" >/dev/null 2>&1 || true' EXIT

DISK_PATH_IN_CONTAINER="${DISK_PATH_IN_CONTAINER:-}"
if [[ -z "${DISK_PATH_IN_CONTAINER}" ]]; then
    # containerdisks images name the file disk/disk.img regardless of actual format
    # (usually raw, sometimes qcow2 internally) - match by path, not extension.
    DISK_PATH_IN_CONTAINER=$(podman export "${CID}" | tar -tv | awk '{print $NF}' | grep -E '^disk/disk\.(img|qcow2|raw)$' | head -n1 || true)
fi
if [[ -z "${DISK_PATH_IN_CONTAINER}" ]]; then
    # fallback: any regular file under disk/
    DISK_PATH_IN_CONTAINER=$(podman export "${CID}" | tar -tv | grep -E '^-' | awk '{print $NF}' | grep -E '^disk/' | head -n1 || true)
fi
if [[ -z "${DISK_PATH_IN_CONTAINER}" ]]; then
    echo "ERROR: could not locate any .qcow2 file inside the container image."
    echo "Full container filesystem listing:"
    echo "-----------------------------------"
    podman export "${CID}" | tar -tv
    echo "-----------------------------------"
    echo "Copy the correct path from above and either:"
    echo "  a) rerun with: DISK_PATH_IN_CONTAINER=/path/to/file.qcow2 $0"
    echo "  b) edit the grep pattern in this script to match it"
    exit 1
fi
DISK_PATH_IN_CONTAINER="/${DISK_PATH_IN_CONTAINER#/}"
echo "  found: ${DISK_PATH_IN_CONTAINER}"

if [[ ! -f "${BASE_IMG}" ]]; then
    podman cp "${CID}:${DISK_PATH_IN_CONTAINER}" "${BASE_IMG}"
    echo "  saved to ${BASE_IMG}"
else
    echo "  ${BASE_IMG} already exists, skipping re-copy (delete it to force re-extract)"
fi

podman rm -f "${CID}" >/dev/null 2>&1 || true
trap - ERR EXIT

# Detect actual format - containerdisks' disk.img is usually raw despite ambiguous naming.
# Use plain-text output, not --output=json: newer qemu-img nests multiple "format" keys
# (protocol layer + guest format), which breaks naive JSON key extraction.
BASE_FORMAT=$(qemu-img info "${BASE_IMG}" | awk -F': ' '/^file format:/{print $2}')
if [[ -z "${BASE_FORMAT}" ]]; then
    echo "ERROR: could not determine format of ${BASE_IMG}"
    qemu-img info "${BASE_IMG}"
    exit 1
fi
echo "  detected format: ${BASE_FORMAT}"

### ---- Step 3: Create writable overlay for the actual test VM ----
echo "[3/5] Creating writable overlay: ${OVERLAY_QCOW2}"
if [[ -f "${OVERLAY_QCOW2}" ]]; then
    echo "  ${OVERLAY_QCOW2} already exists — skipping (delete it first if you want a fresh overlay)"
else
    qemu-img create -f qcow2 -F "${BASE_FORMAT}" -b "$(realpath "${BASE_IMG}")" "${OVERLAY_QCOW2}" "${DISK_SIZE}"
fi
qemu-img info "${OVERLAY_QCOW2}"

### ---- Step 4: Write cloud-init user-data / meta-data ----
echo "[4/5] Writing cloud-init config"
mkdir -p cloud-init
cat > cloud-init/user-data <<EOF
#cloud-config
hostname: ${GUEST_HOSTNAME}

users:
  - name: ${GUEST_USER}
    plain_text_passwd: ${GUEST_PASSWORD}
    lock_passwd: false
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    groups: wheel
    ssh_authorized_keys:
       - ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQCR8FFSrwiycT9Ez+IL0TtY0z9f2IjO4rlwfbo4Kf0ulAVjlBn3Y+hkh3OBptnhN28dVTRWCFakBh8uB7kpBGfe7E844O5JxVIAefNqTIWLQHGV+IzX5ggf1Vw7f6l2uny9XSczsY3zUSBnPLpi1cd4nyy4ZDJrVkJHwx6/8JEGmCU32fhrwmgkvfHGUJMzXt/AP6LW7yKvRTtflloE3BEfmWrNemAg1j/bM398OQFQmtIRltecCWF2n8idJgm6jsd0uUK7bCOXy2UafQhlqLPSFB/+5Wi3Y/HzzvUwqTWCvnPlj3LOgbpOV+mEKqdlLsCqeGUUl3qrk5PL4qTgUMXwHma4ckn8WM2fCs1gl/I+WfR5Xh8pjH7u0pO5LS1dUP+gg47iYUbBm+I6cCbOOquTkcnZf+NtENbSSpmp8nIxXRr/iopc45+2CptkgjUG5WweX/Bpl97NpDngy1fBC2k9FL4oNaHEwfE2E11KrcHRmkn11sQ50txUKcpYxx/zU4U= devram@devram-ms7c88

ssh_pwauth: true

packages:
  - iperf3
  - sysstat
  - NetworkManager
  - mpstat
  - qperf

write_files:
  - path: /etc/NetworkManager/system-connections/eth0-static.nmconnection
    permissions: '0600'
    content: |
      [connection]
      id=eth0-static
      type=ethernet
      interface-name=ens3
      autoconnect=true
      autoconnect-priority=999

      [ethernet]
      mac-address=52:54:00:12:34:56

      [ipv4]
      method=manual
      address1=${GUEST_IP}/${GUEST_PREFIX}
      # no gateway/dns - isolated point-to-point test segment, not routed

      [ipv6]
      method=disabled

  - path: /etc/systemd/system/iperf3-server.service
    permissions: '0644'
    content: |
      [Unit]
      Description=iperf3 server (persistent, auto-restart)
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
      Description=qperf server (persistent, auto-restart)
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
      mpstat -P ALL 1 "\${DURATION}" > "\${OUTDIR}/guest_cpu.log" &
      cat /proc/interrupts | grep virtio > "\${OUTDIR}/interrupts_before.txt"
      wait
      cat /proc/interrupts | grep virtio > "\${OUTDIR}/interrupts_after.txt"
      ethtool -S ens3 > "\${OUTDIR}/ethtool_after.txt" 2>/dev/null
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
  - [ chmod, '600', /etc/NetworkManager/system-connections/eth0-static.nmconnection ]
  - [ systemctl, daemon-reload ]
  - [ systemctl, enable, --now, NetworkManager ]
  - [ nmcli, connection, reload ]
  - [ nmcli, connection, up, eth0-static ]
  - [ systemctl, enable, --now, iperf3-server.service ]
  - [ systemctl, enable, --now, qperf-server.service ]
  - [ mkdir, -p, /var/log/bench ]

final_message: "cloud-init finished, eth0 should be ${GUEST_IP}/${GUEST_PREFIX}"
EOF

cat > cloud-init/meta-data <<EOF
instance-id: ${GUEST_HOSTNAME}-01
local-hostname: ${GUEST_HOSTNAME}
EOF

### ---- Step 5: Build seed.iso ----
echo "[5/5] Building ${SEED_ISO}"
if command -v cloud-localds >/dev/null 2>&1; then
    cloud-localds "${SEED_ISO}" cloud-init/user-data cloud-init/meta-data
elif command -v genisoimage >/dev/null 2>&1; then
    genisoimage -output "${SEED_ISO}" -volid cidata -joliet -rock cloud-init/user-data cloud-init/meta-data
elif command -v xorriso >/dev/null 2>&1; then
    xorriso -as genisoimage -output "${SEED_ISO}" -volid cidata -joliet -rock cloud-init/user-data cloud-init/meta-data
else
    echo "No ISO tool found on host (cloud-localds / genisoimage / xorriso)."
    echo "Falling back to podman-based genisoimage container:"
    podman run --rm -v "$(pwd)/cloud-init:/data:Z" -w /data \
        quay.io/cloud-init/genisoimage \
        genisoimage -output /data/seed.iso -volid cidata -joliet -rock user-data meta-data
    mv cloud-init/seed.iso "${SEED_ISO}"
fi

echo
echo "Done."
echo "  Base image : ${BASE_IMG}"
echo "  Overlay    : ${OVERLAY_QCOW2}  <-- point QEMU's DISK= at this"
echo "  Seed ISO   : ${SEED_ISO}       <-- point QEMU's SEED= at this"
echo
echo "  Guest login: ssh ${GUEST_USER}@${GUEST_IP}  (password: ${GUEST_PASSWORD})"
echo "  Guest IP   : ${GUEST_IP}/${GUEST_PREFIX} (static, no gateway/DNS)"
echo "  Reminder   : set the matching host-side IP on the DAC-loopback interface, e.g.:"
echo "               sudo ip addr add ${GUEST_IP%.*}.1/${GUEST_PREFIX} dev <host_iface>"
echo "               (do NOT put an IP on br0 itself)"

echo "Install the required packages"
sudo virt-customize -a ./guest.qcow2 --install iperf3,sysstat,mpstat,qperf 
