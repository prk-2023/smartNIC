- make
- sudo ./scripts/setup_ports.sh enp1s0f0np0 enp1s0f1np1 4

./scripts/setup_ports.sh <REFLECTOR_IFACE> <PEER_IFACE> <NUM_QUEUES> <CPU pinning Optional>

NUM_QUEUES: -n 8 
CPU Pinning: -a 2 ( worker i runs on CPU first_cpu + i )
- sudo ./xsk_reflect_mq -i enp1s0f0np0 -n 4 -a 2                        # terminal 1
- sudo ip netns exec xsk-peer python3 scripts/udp_client.py --flows 16   # terminal 2

Or run the below command from terminal #2 


sudo ip netns exec xsk-peer hping3 --udp -a 10.10.0.2 -s 5000 -p 7777 10.10.0.1 --flood

Note to run hping3 make sure to setup networn namespace as in udp_client.py


Error: generates error if queues are combined:

sudo ./xsk_reflect_mq -i enp1s0f0np0 -n 4  -a 2
WARNING: NIC has 1 queues but -n 4 was requested.
         Run: sudo ethtool -L enp1s0f0np0 combined 4
queue  0: ZERO-COPY
queue 1: xsk_socket__create: Invalid argument (does the NIC have that many queues?)

$ ethtool -l enp1s0f0np0
Channel parameters for enp1s0f0np0:
Pre-set maximums:
RX:             n/a
TX:             n/a
Other:          n/a
Combined:       12
Current hardware settings:
RX:             n/a
TX:             n/a
Other:          n/a
Combined:       1

Revert the combined effect:

$ sudo ethtool -L enp1s0f0np0 combined 12
$ ethtool -l enp1s0f0np0
Channel parameters for enp1s0f0np0:
Pre-set maximums:
RX:             n/a
TX:             n/a
Other:          n/a
Combined:       12
Current hardware settings:
RX:             n/a
TX:             n/a
Other:          n/a
Combined:       12
