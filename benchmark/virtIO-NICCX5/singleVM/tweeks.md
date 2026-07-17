1. To additional installing packages into generated image:
sudo sudo systemctl restart virtqemud
sudo virt-customize -a ./guest.qcow2 --install iperf3,sysstat,mpstat,qperf

2. missing /dev/kvm: 
sudo modprobe kvm kvm_amd
or 
sudo modprobe kvm kvm_intel

3. Enable kernel hugepages setup:
sudo sysctl -w vm.nr_hugepages=1024
sudo chmod 777 /dev/hugepages 

4. For software rdma device:
sudo modprobe rdma_rxe
sudo ip link add enp1s0f0np0 type dummy
sudo ip link set  enp1s0f0np0 up
sudo ip link add enp1s0f1np1 type dummy
sudo ip link set  enp1s0f1np1  up

bind sw rdma interface with regular network NIC:
sudo rdma link add rxe0 type rxe netdev enp3s0
or 
sudo rdma link add rxe0 type rxe netdev lo

5. CPU Governor Set all cores to performance mode:

echo performance | sudo tee /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor

Permanent setting:
sudo dnf install kernel-tools ; edit /etc/default/cpupower : GOVERNOR="performance"

or 
echo performance | sudo tee /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor
