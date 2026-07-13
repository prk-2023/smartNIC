# 1. one-time host setup - binds BOTH ports to DPDK, no vfio/IOMMU concerns
./host_ovs_dpdk_dualport_setup.sh
# check "dpdk_initialized: true" and both port link_state lines

# 2. build both VM images (reuses the exact same script from the SR-IOV leg -
#    it's generic mgmt+dataplane, doesn't care what's driving the dataplane NIC)
./build_sriov_vm_image.sh vm1 192.168.50.11 52:54:00:mm:mm:01 192.168.101.10 52:54:00:aa:bb:01
./build_sriov_vm_image.sh vm2 192.168.50.12 52:54:00:mm:mm:02 192.168.101.20 52:54:00:aa:bb:02

# 3. launch both, pointing at their respective vhost-user sockets
./launch_ovs_dpdk_vm_generic.sh vm1 /tmp/ovs-vhost/vhost-user0 52:54:00:aa:bb:01 tap-mgmt1 52:54:00:mm:mm:01 4,5
./launch_ovs_dpdk_vm_generic.sh vm2 /tmp/ovs-vhost/vhost-user1 52:54:00:aa:bb:02 tap-mgmt2 52:54:00:mm:mm:02 6,7
# check both "link_state: up" lines before proceeding

# 4. run the benchmark
./run_test_ovs_dpdk_dualvm.sh ovs_dpdk_dualvm_run1


```
    +------------------------------------------------------------------------+
    |                             FEDORA 43 HOST                             |
    |                                                                        |
    |    +--------------------------------------------------------------+    |
    |    |                      BENCHMARK GUEST VM                      |    |
    |    |                                                              |    |
    |    |      [ VM1: (virtio-net]               [ VM2 (virtio-net]    |    |
    |    +--------------|-------------------------------------|---------+    |
    |                   | (vhost-user0)                       |(vhost-user1) |
    |    +--------------|-------------------------------------|---------+    |
    |    |           (br-left)                              (br-right)  |    |
    |    |          OVS-DPDK Switch                      OVS-DPDK Switch|    |
    |    +--------------|---------------------------------------|-------+    |
    |                   |                                       |            |
    |            [ enp1s0f0np0 ]                         [ enp1s0f1np1 ]     |
    |             (dpdk0 port0)                           (dpdk1 port1)      |
    +-------------------|---------------------------------------|------------+
                        +========== Physical DAC Loopback ======+
                            br-mgmt (local, SW only)
                            ssh into both VMs not measured. 
```

NOTE: generate the vm1 and vm2 images :
- ./build_sriov_vm_image.sh vm1 192.168.50.11 52:54:00:00:01:01 192.168.101.10 52:54:00:aa:bb:01 
- ./build_sriov_vm_image.sh vm2 192.168.50.12 52:54:00:00:01:02 192.168.101.20 52:54:00:aa:bb:02
