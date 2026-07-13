```txt 
           Host
+-----------------------------------------+
|                                         |
|  PF0                       PF1          |
|   |                         |           |
|  VF0                       VF0          |
|   |                         |           |
|  VM1                       VM2          |
+-----------------------------------------+

VM1 (VF on Port0)
        |
   ConnectX-5 Port0
========================= DAC =========================
   ConnectX-5 Port1
        |
VM2 (VF on Port1)
```

- VM1 assigned a VF from CX5-Port0 
- VM2 assigned a VF from CX5-Port1


```
VM1 => VF0 (port0) => [CX5 NIC] => VF0(port1) => VM2 
```
Note: Each VM is mapped to one CX5 interface. 
```
Port0 (PF0)
 ├── VF0  ---> VM1
 ├── VF1
 ├── VF2
 └── ...

Port1 (PF1)
 ├── VF0  ---> VM2
 ├── VF1
 ├── VF2
 └── ...
```
Traffic doesn't traverse: `br0`, VirtIO, vhost-net or Host networking stack. 
=> SR-IOV performance should be close to bare metal.

Comparing with the other benchmark (virtIO-NICCX5) where data path is:
```
VM => VirtIO => Bridge => PF => DAC => PF
```

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
    - Enable VF 
    $ echo 1 | sudo tee /sys/class/net/enp1s0f0np0/device/sriov_numvfs
    1 
=>  $ echo 1 | sudo tee /sys/class/net/enp1s0f1np1/device/sriov_numvfs
=>  1   
=>  tee: /sys/class/net/enp1s0f1np1/device/sriov_numvfs: Input/output error
( from dmesg  :

---
**`dmesg`** :
```bash
$ dmesg
[ 2090.926758] mlx5_core 0000:01:00.1: E-Switch: Enable: mode(LEGACY), nvfs(1), necvfs(0), active vports(2)
[ 2091.034231] pci 0000:01:01.2: [15b3:1018] type 7f class 0xffffff conventional PCI
[ 2091.034260] pci 0000:01:01.2: unknown header type 7f, ignoring device
[ 2092.098636] mlx5_core 0000:01:00.1: mlx5_sriov_enable:195:(pid 30662): pci_enable_sriov failed : -5
[ 2092.099455] mlx5_core 0000:01:00.1: E-Switch: Unload vfs: mode(LEGACY), nvfs(1), necvfs(0), active vports(2)
[ 2092.108181] mlx5_core 0000:01:00.1: E-Switch: Disable: mode(LEGACY), nvfs(1), necvfs(0), active vports(1)

$ lspci -t
-[0000:00]-+-00.0
           +-00.2
           +-01.0
           +-01.1-[01]--+-00.0
           |            +-00.1
           |            \-00.2
           +-01.2-[02-04]--+-00.0
           |               +-00.1
           |               \-00.2-[03-04]----03.0-[04]----00.0
           +-01.6-[05]----00.0
           +-08.0
           +-08.1-[06]--+-00.0
           |            +-00.1
           |            +-00.2
           |            +-00.3
           |            +-00.4
           |            \-00.6
           +-14.0
           +-14.3
           +-18.0
           +-18.1
           +-18.2
           +-18.3
           +-18.4
           +-18.5
           +-18.6
           \-18.7

```
---
NOTE: With limitation Unable to test 

VF <=> VF benchmarking 

Switching to VF = PF benchmarking using 2 Linux systems.


Step 4: test data path [VF] <=DAC=> [VF] 

    pc1 [PF0 : VF0] === DAC === [VF0 : PF0] pc2

Step 5: test data path [VirtIO ][VF] <=DAC=> [VF][VIRTIO] 

    pc1-[VM] -- [PF0 : VF0] === DAC === [VF0 : PF0] -- [VM]-pc2


