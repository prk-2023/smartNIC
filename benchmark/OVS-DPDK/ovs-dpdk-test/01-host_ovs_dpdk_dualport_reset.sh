# # =====================================================================
# # CLEAN SLATE RESET: Wipe previous OVS database configurations & ports
# # =====================================================================
# echo "Wiping existing Open vSwitch configuration..."
#
# # 1. Forcefully terminate any leftover QEMU virtual machines
# sudo killall -9 qemu-system-x86_64 2>/dev/null || true
#
# # 2. Revert OVS to a factory-default database state
# # sudo ovs-vsctl Emergency-Reset
# sudo ovs-vsctl emer-reset
#
#
# # 3. Cleanly delete the bridges if they still linger in memory
# sudo ovs-vsctl del-br br-left 2>/dev/null || true
# sudo ovs-vsctl del-br br-right 2>/dev/null || true
# sudo ovs-vsctl del-br br-mgmt 2>/dev/null || true
#
# # 4. Tear down old persistent host management tap links
# sudo ip link set tap-mgmt1 down 2>/dev/null || true
# sudo ip link set tap-mgmt2 down 2>/dev/null || true
# sudo ip tuntap del dev tap-mgmt1 mode tap 2>/dev/null || true
# sudo ip tuntap del dev tap-mgmt2 mode tap 2>/dev/null || true
#
# # 5. Flush runtime vhost sockets so they can be regenerated cleanly
# sudo rm -rf /tmp/ovs-vhost/*
# sudo rm -f /var/run/openvswitch/vhost-user*
#
# # 6. Restart the Open vSwitch daemon to cleanly bind DPDK PMDs from scratch
# sudo systemctl restart openvswitch
#
# # Give OVS 3 seconds to complete its database handshake before adding ports
# sleep 3
#
# echo "completely blanks out the database schema: wiping everything"
# echo "sudo ovs-vsctl --if-exists del-br br-left \
#             -- --if-exists del-br br-right \
#             -- --if-exists del-br br-mgmt"
#
# ---
#!/bin/bash
echo "Stopping VMs and wiping Open vSwitch configuration..."

# Kill any running VMs holding onto sockets or hugepages
sudo killall -9 qemu-system-x86_64 2>/dev/null || true

# Delete old bridges
sudo ovs-vsctl --if-exists del-br br-left
sudo ovs-vsctl --if-exists del-br br-right
sudo ovs-vsctl --if-exists del-br br-mgmt

# Tear down management tap interfaces
sudo ip link set tap-mgmt1 down 2>/dev/null || true
sudo ip link set tap-mgmt2 down 2>/dev/null || true
sudo ip tuntap del dev tap-mgmt1 mode tap 2>/dev/null || true
sudo ip tuntap del dev tap-mgmt2 mode tap 2>/dev/null || true

# Force delete all old socket files completely so no dummies remain
sudo rm -f /var/run/openvswitch/vhost-user*
sudo rm -rf /tmp/ovs-vhost/*

# Restart the service to completely flush DPDK memory
sudo systemctl restart openvswitch
echo "Reset complete. System is a clean slate."
