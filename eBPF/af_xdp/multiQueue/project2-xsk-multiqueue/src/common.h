/* SPDX-License-Identifier: GPL-2.0 */
/*
 * common.h - definitions shared by the kernel (XDP) and user-space programs.
 *
 * Anything both sides must agree on lives here, so they can never drift apart.
 */
#ifndef COMMON_H
#define COMMON_H

#include <linux/types.h>

/* Only UDP packets with this destination port are steered to AF_XDP.
 * Everything else (ARP, ICMP, ssh, ...) continues to the normal kernel stack. */
#define ECHO_UDP_PORT 7777

/* Upper bound on queues: size of the XSKMAP and of the per-queue stats map. */
#define MAX_QUEUES 64

/*
 * Per-queue counters kept by the XDP program in the "qstats" map.
 * User space reads them through libbpf (bpf_map_lookup_elem). They count
 * packets seen BY THE XDP PROGRAM, independent of what AF_XDP does later,
 * which makes them a great way to check how RSS spreads flows over queues.
 */
struct qstat {
	__u64 pkts;
	__u64 bytes;
};

#endif /* COMMON_H */
