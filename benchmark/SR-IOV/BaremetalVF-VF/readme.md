Enable SR-IOV :

Step 1: 
    - Bios PCIe > 4G Decoding (Enable)
    - If any IOMMU also (Enable or Auto)
    - Intel VT-d enable and Virtualisation support enable 

Step 2: 
    - boot kernel command line :
    - sudo grubby --update-kernel=ALL --args="intel_iommu=on iommu=pt pci=realloc,assign-busses"
    - reboot 

Step 3: Enable Virtual Functions  
    - check the number of VF the device supports
    $ cat /sys/class/net/enp1s0f0np0/device/sriov_totalvfs
    8 
    $ cat /sys/class/net/enp1s0f1np1/device/sriov_totalvfs
    8
    - Enable SR-IOV: VF 
    $ echo 1 | sudo tee /sys/class/net/enp1s0f0np0/device/sriov_numvfs
    1 
=>  $ echo 1 | sudo tee /sys/class/net/enp1s0f1np1/device/sriov_numvfs
=>  1   
=>  tee: /sys/class/net/enp1s0f1np1/device/sriov_numvfs: Input/output error
( from dmesg  :

---

Benchmark Test:

Step 1: Baremetal : [VF] <== DAC ==> [VF] 

    pc1 [PF0 : VF0] === DAC === [VF0 : PF0] pc2

Test 1 (bare-metal VF-to-VF):
**PC1**:
$ sudo dnf install -y iperf3 sysstat qperf
./host_vf_baremetal_setup.sh enp1s0f0np0 192.168.101.10

**on PC2**:
sudo dnf install -y iperf3 sysstat qperf
$ ./host_vf_baremetal_setup.sh enp1s0f0np0 192.168.101.20


# need a qperf server running persistently - simplest is:
qperf &

**on PC1**:
./run_test_baremetal_vf.sh baremetal_vf_run1


