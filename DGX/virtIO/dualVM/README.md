# t2 — VirtIO VM<->VM Benchmark (ConnectX-7 PF0/PF1, DGX Spark)

```
                 Physical Network (DAC crossover)
                        |
               +----------------+
               |                |
             PF0              PF1
      enp1s0f0np0        enp1s0f1np1
               |                |
          +---------+      +---------+
          | br-left |      | br-right|
          +---------+      +---------+
               |                |
           vnet0 TAP        vnet1 TAP
               |                |
        virtio-net NIC    virtio-net NIC
             (ens-test)     (ens-test)
               |                |
             VM1              VM2
               |                |
        virtio-net NIC    virtio-net NIC
           (ens-mgmt)       (ens-mgmt)
               |                |
          QEMU SLIRP        QEMU SLIRP
        (per-VM, hostfwd    (per-VM, hostfwd
         ssh -p 2201)        ssh -p 2202)
```

All scripts are prefixed `t2_` and source a shared `t2_config.sh` — edit values there, not in the individual scripts.

## Run order

```bash
./t2_perf_status.sh        # read-only audit
./t2_perf_apply.sh         # applies safe live tunings; reboot only if it says so
./t2_host_setup.sh         # creates br-left/br-right + taps (test path only)
./t2_build_guest_image.sh 1
./t2_build_guest_image.sh 2
./t2_launch_vm.sh 1        # fill in VCPU_PIN first (see script header)
./t2_launch_vm.sh 2        # different VCPU_PIN values than VM1 - they run concurrently
./t2_run_test.sh run1
./t2_host_reset.sh         # tears down br-left/br-right, restores PF0/PF1 to plain netdevs
```

## Why the mgmt path uses QEMU SLIRP, not a host bridge

Each VM's mgmt NIC uses QEMU's built-in user-mode (SLIRP) networking instead of a
host-side NAT bridge — internet access, DNS, and NAT all work automatically with zero
host configuration, and SSH reachability comes from QEMU's own `hostfwd`
(`ssh -p 2201/2202 bench@<dgx-ip>`), not a host iptables DNAT rule. There's nothing on
the host to set up or tear down for this path, and nothing that can conflict with
firewalld/podman/other iptables users — that entire class of problem the earlier
NAT-bridge design ran into simply doesn't apply here.

## Why the benchmark path is separate from the management path

The actual VM1<->VM2 iperf3/qperf traffic runs entirely over `ens-test` (`br-left <-> DAC <-> br-right`), driven by SSHing into VM1 *through the mgmt path* and telling it to run the client - the mgmt path itself is never part of what's measured. `t2_run_test.sh` snapshots `ethtool -S` counters on both PF0 and PF1 before/after each run and warns if either shows implausibly little TX traffic, which would indicate something's wrong with the bridge wiring rather than a real result.

## Before you run t2_launch_vm.sh

Both `VCPU_PIN` arrays start empty on purpose - the script refuses to launch rather than guess at core placement. Run `lscpu -e` and check the PF's NUMA node (`t2_perf_status.sh` prints this), then pick **disjoint** core sets for VM1 and VM2, since they run at the same time and would otherwise contend for the same physical cores.

## Known gap

`pin_vhost.sh` (referenced in the launch script's closing message) isn't included - vhost-net kernel threads spawn lazily after traffic starts, so pinning them needs a short script matching on `vhost-<pid>` process names, written the same way the vCPU-pinning loop in `t2_launch_vm.sh` matches on `CPU*`. Worth writing once you've confirmed the rest of the pipeline works end to end.
