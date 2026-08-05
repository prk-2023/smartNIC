```
                 Physical Network (DAC crossover)
                        |
               +----------------+
               |                |
             PF0              PF1
      enp1s0f0np0        enp1s0f1np1
               |                |
      +----------------+  +----------------+
      |   OVS br-left  |  |  OVS br-right  |
      +----------------+  +----------------+
               |                |
          tap-left         tap-right
               |                |
        virtio-net NIC    virtio-net NIC
          (ens-test)        (ens-test)
               |                |
             VM1              VM2
               |                |
        virtio-net NIC    virtio-net NIC
          (ens-mgmt)        (ens-mgmt)
               |                |
          QEMU SLIRP        QEMU SLIRP
       (SSH :2201)        (SSH :2202)
```
Data flow:
```text 
   VM1
 ens-test
    │
    ▼
tap-left
    │
    ▼
OVS br-left
    │
    ▼
   PF0
    │
==== DAC ====
    │
    ▼
   PF1
    │
    ▼
OVS br-right
    │
    ▼
tap-right
    │
    ▼
   VM2
```

Outcome: No internal PF switch or bridge:
```
            ConnectX NIC

      +-----------------------+
      |                       |
      |      No internal      |
      |   PF0 <-> PF1 switch  |
      |      or bridge        |
      |                       |
      +-----------------------+

      PF0                 PF1
       │                   │
       ▼                   ▼
   OVS br-left        OVS br-right
```



./t2_perf_status.sh ( check config/setting )
./t2_perf_apply.sh  
./t2_host_reset-ovs.sh 
./t2_host_setup-ovs.sh

t2_config.sh ( global config file )
./t2_build_guest_image.sh 1   <-- Build VM1 image
./t2_build_guest_image.sh 2   <-- Build VM2 image

./t2_launch_vm.sh 1 <- launch VM1
./t2_launch_vm.sh 2 <- launch VM1

ssh into vm1 and vm2 and ping ( FAIL )
debug: tcpdump enp1s0f0np0, and enp1s0f1np1 to monitor where the traffic is blocked. 

./t2_run_test.sh ( Can not test check report.md )


---

SW VM1 <=> VM2   ( using ovs to connect VM's )

modify the above OVS setup and add both tap0 and tap1 to PVS br-left:

sudo ovs-vsctl show
sudo ovs-vsctl del-port br-right enp1s0f1np1
sudo ovs-vsctl del-port br-right vnet1
sudo ovs-vsctl del-br br-right
sudo ovs-vsctl add-port br-left vnet1
sudo ovs-vsctl show

./t2_run_test ovs-sw => result/ovs-sw/summart.json


