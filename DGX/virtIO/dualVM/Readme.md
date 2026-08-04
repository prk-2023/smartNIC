./t2_perf_status.sh ( check config/setting )
./t2_perf_apply.sh  
./t2_host_reset.sh 
./t2_host_setup.sh

t2_config.sh ( global config file )
./t2_build_guest_image.sh 1   <-- Build VM1 image
./t2_build_guest_image.sh 2   <-- Build VM2 image

./t2_launch_vm.sh 1 <- launch VM1
./t2_launch_vm.sh 2 <- launch VM1

ssh into vm1 and vm2 and ping ( FAIL )
debug: tcpdump enp1s0f0np0, and enp1s0f1np1 to monitor where the traffic is blocked. 

./t2_run_test.sh ( Can not test check report.md )
