1. Install:

sudo dnf install openvswitch openvswitch-dpdk

2. Start openvswitch daemon:

sudo systemctl status openvswitch 

if disabled:

sudo systemctl start openvswitch 

sudo ovs-vsctl show

- sanity check before we configure ( fedora )

$sudo systemctl is-active openvswitch
active 

$sudo ovs-vsctl show
0da738c6-3132-406e-84da-bb0c58d1fdcd
    ovs_version: "3.6.2-1.fc43"



