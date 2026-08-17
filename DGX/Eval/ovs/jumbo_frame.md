To successfully pass Jumbo Frames (MTU 9000) every single element in the data path—from the Physical Network
to the Virtual Machines—must be configured with an MTU of at least 9000.

1. VM interfaces setto 9000 MTU 
2. vhost-user0 / vhost-user1 MTU also set to 9K if VM is used. 
3. bridge mtu:
   ovs: ovs-vsctl set bridge br-left mtu_request=9000
   if std linux bridge then use (ip link set dev br-left mtu 9000)

4. The Physical Function Ports (PF0 / PF1 at 01:00.0 and 01:00.1)

   ip link set dev <PF0_interface_name> mtu 9000
   ip link set dev <PF1_interface_name> mtu 9000
