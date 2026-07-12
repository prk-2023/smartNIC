
SR-IOV benchmarking:

Trying to set up VF-to-VF benchmarking on a ConnectX-5 dual-port adapter, but the SR-IOV setup is currently failing on the second physical function.

Environment:

* NIC: Mellanox/NVIDIA ConnectX-5 MT27800
* Firmware: 16.35.4506 (MT_0000000425)
* OS: Fedora 43
* Kernel: 6.18.16-200.fc43.x86_64
* Driver: upstream mlx5_core

Current PCI layout:

```
0000:01:00.0  ConnectX-5 PF0
0000:01:00.1  ConnectX-5 PF1
```

SR-IOV capability is present on both PFs:

```
PF0:
Initial VFs: 8
Total VFs: 8

PF1:
Initial VFs: 8
Total VFs: 8
```

PF0 works correctly:

```
#echo 2 > /sys/bus/pci/devices/0000:01:00.0/sriov_numvfs
echo 2 | sudo tee   /sys/bus/pci/devices/0000\:01\:00.0/sriov_numvfs
```

creates:

```
01:00.2  ConnectX-5 Virtual Function
01:00.3  ConnectX-5 Virtual Function
```

However, enabling SR-IOV on PF1 fails even with only one VF:

```
echo 1 > /sys/bus/pci/devices/0000:01:00.1/sriov_numvfs
```

returns:

```
Input/output error
```

Kernel log:

```
mlx5_core 0000:01:00.1: E-Switch: Enable: mode(LEGACY), nvfs(1)
pci 0000:01:01.2: [15b3:1018] type 7f class 0xffffff
pci 0000:01:01.2: unknown header type 7f, ignoring device
mlx5_core 0000:01:00.1: mlx5_sriov_enable: pci_enable_sriov failed : -5
```

Observations:

* Initial issue was MMIO resource exhaustion when creating VFs, but that has been resolved.
* `pci=realloc`/resource changes are no longer the blocker because PF0 can successfully create VFs.
* Both PFs have identical firmware and driver versions.
* Switching eSwitch mode (legacy/switchdev) does not resolve the issue.
* SR-IOV capability and VF count are correctly exposed by firmware.
* The failure happens only on PF1.

Current suspicion:
The issue appears related to PCIe resource/bus/function enumeration for the second PF's VFs. PF1 VF allocation starts at:

```
VF offset: 9
```

and the first VF appears as:

```
01:01.2
```

but PCI reports:

```
unknown header type 7f
```

which suggests the VF is not being correctly enumerated by PCI.

For VF-to-VF benchmarking, the expected topology is:

```
PF0 -> VF(s)
PF1 -> VF(s)
VF <-> VF traffic benchmark
```

At the moment, only PF0 can create working VFs, preventing a dual-port VF-to-VF benchmark setup.

Could someone help confirm whether this is:

1. A BIOS PCIe resource allocation issue (ARI / bus numbering / Above 4G decoding)?
2. A ConnectX-5 firmware limitation/bug for dual-port SR-IOV?
3. A known mlx5_core/kernel issue with ConnectX-5 + kernel 6.18?

Additional data available:

* lspci -vv PCI capability dumps
* lspci topology
* dmesg SR-IOV failure logs
* mlx5 firmware details

-----
SR-IOV VF passthrough into a VM requires the IOMMU enabled in the kernel 
and each VF bound to `vfio-pci` before QEMU VM can claim it. 
This requires:
check:
cat /proc/cmdline | grep -E 'intel_iommu=on|iommu=pt'
Add if the arguments are missing 
sudo grubby --update-kernel=ALL --args="intel_iommu=on iommu=pt"   
# reboot to check.

2. Enable SR-IOV: VFs do not exist until they are explicitly created (`sriov_numvfs`), 
and CX-5 sometimes needs `mlxconfig SRIOV_EN=1` + firmware reset first if it's disabled 
at the firmware level. 

Fedora does not come with mlxconfig `mstflint` package provides `mstconfig`, 
which is the equivalent tool for querying and modifying firmware configuration. 

sudo dnf install mstflint
$ lspci -nn | grep 01:00
01:00.0 Ethernet controller [0200]: Mellanox Technologies MT27800 Family [ConnectX-5] [15b3:1017]
01:00.1 Ethernet controller [0200]: Mellanox Technologies MT27800 Family [ConnectX-5] [15b3:1017]
$ sudo mstconfig -d 01:00.0 query
write counter to semaphore: Operation not permitted
-E- Failed to open the device
Issue: 
- NIC firmware is an OEM variant that restricts firmware configuration access.
- firmware is too old or incompatible with the installed mstconfig.
- Secure Boot or kernel restrictions are preventing the low-level firmware access.
- The card is functioning normally for networking but does not expose the firmware management interface expected by mstconfig

Check
$ cat /sys/bus/pci/devices/0000:01:00.0/sriov_totalvfs
8
and
$cat  /sys/bus/pci/devices/0000:01:00.1/sriov_totalvfs
8
$cat /sys/bus/pci/devices/0000:01:00.0/sriov_numvfs
0
=> If `sriov_totalvfs` returns a value such as 8,64 or 128, then SR-IOV is already 
   enabled in firmware and you do not need mstconfig at all.
=> value 8 as above => CX5 firmware already enable SR-IOV. And Kernel recognizes tat the device supports 8 Virtual functions
=>  Firmware config can be skipped. 
NOTE: To enable SR-IOV BIOS and kernel boot arguments  are required 
look for :
- Intel VT-D enabled 
- PCIe settings: 4G Decoding enabled
- If SR-IOV setting enable 
- PCIe Bar reallocation 
If all this does not work you should see "not enough MMIO resource for SR-IOV" with below command
$ sudo dmesg | grep -i -E "pci|bar|resource|mlx"
This would require additional kernel boot arguments: 
sudo grubby --update-kernel=ALL --args="pci=realloc"

This will make sure the PCIe additional memory requiremets for VF's

Next step: Create the VFs
First, identify the network interface corresponding to 01:00.0:
$ls /sys/bus/pci/devices/0000:01:00.0/net
enp1s0f0np0
ls /sys/bus/pci/devices/0000:01:00.1/net
enp1s0f1np1
Now create the VF's:
$ echo 1 | sudo tee /sys/class/net/enp1s0f0np0/device/sriov_numvfs
$ echo 1 | sudo tee /sys/class/net/enp1s0f1np1/device/sriov_numvfs
verify:
$lspci | grep Virtual
or
$ ip link show
You should see 1 addition VFs associated with the each PF.

Now verify VFs:
lspci -D | grep Mellanox

-----------
