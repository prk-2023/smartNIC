// SPDX-License-Identifier: GPL-2.0
/*
 * xdp_kern.c - the XDP half of Project 2 (multi-queue).
 *
 * Runs in the NIC driver (mlx5) for every received frame, on the CPU that is
 * servicing that RX queue's NAPI poll. With N queues, N instances of this
 * program run in parallel on different CPUs - that is why the shared state it
 * touches (qstats) must be updated atomically.
 *
 * Job:
 *   - IPv4/UDP to ECHO_UDP_PORT -> count it, then redirect it to the AF_XDP
 *     socket registered for the SAME queue index in xsks_map.
 *   - anything else             -> XDP_PASS (normal kernel stack).
 *
 * Data path:  NIC RX queue N --> this program --> xsks_map[N] --> XSK N's RX ring
 */
#include <linux/bpf.h>
#include <linux/if_ether.h>   /* struct ethhdr, ETH_P_IP           */
#include <linux/ip.h>         /* struct iphdr                      */
#include <linux/udp.h>        /* struct udphdr                     */
#include <linux/in.h>         /* IPPROTO_UDP                       */
#include <bpf/bpf_helpers.h>  /* SEC(), __uint(), bpf_map_lookup_elem, ... */
#include <bpf/bpf_endian.h>   /* bpf_htons()                       */

#include "common.h"

/*
 * XSKMAP: "RX queue index -> AF_XDP socket".
 * User space inserts one socket per queue (xsk_socket__update_xskmap),
 * using the queue id as the key.
 */
struct {
	__uint(type, BPF_MAP_TYPE_XSKMAP);
	__uint(max_entries, MAX_QUEUES);
	__type(key, __u32);
	__type(value, __u32);
} xsks_map SEC(".maps");

/*
 * qstats: plain ARRAY map, index = RX queue, value = {pkts, bytes}.
 * Read from user space with bpf_map_lookup_elem() to see the per-queue split.
 * (A PERCPU_ARRAY would avoid atomics; ARRAY keeps the user side simpler.)
 */
struct {
	__uint(type, BPF_MAP_TYPE_ARRAY);
	__uint(max_entries, MAX_QUEUES);
	__type(key, __u32);
	__type(value, struct qstat);
} qstats SEC(".maps");

SEC("xdp")
int xsk_redirect_prog(struct xdp_md *ctx)
{
	/* [data, data_end) is the raw frame. The verifier demands a bounds
	 * check before every header access. */
	void *data     = (void *)(long)ctx->data;
	void *data_end = (void *)(long)ctx->data_end;

	/* ---- Ethernet ---- */
	struct ethhdr *eth = data;
	if ((void *)(eth + 1) > data_end)
		return XDP_PASS;
	if (eth->h_proto != bpf_htons(ETH_P_IP))   /* e.g. ARP: leave to kernel */
		return XDP_PASS;

	/* ---- IPv4 ---- */
	struct iphdr *ip = (void *)(eth + 1);
	if ((void *)(ip + 1) > data_end)
		return XDP_PASS;
	if (ip->protocol != IPPROTO_UDP)
		return XDP_PASS;

	__u32 ihl = ip->ihl * 4;                   /* header length incl. options */
	if (ihl < sizeof(*ip))
		return XDP_PASS;

	/* ---- UDP ---- */
	struct udphdr *udp = (void *)ip + ihl;
	if ((void *)(udp + 1) > data_end)
		return XDP_PASS;
	if (udp->dest != bpf_htons(ECHO_UDP_PORT))
		return XDP_PASS;

	/* ---- Per-queue accounting ---- */
	__u32 q = ctx->rx_queue_index;
	struct qstat *st = bpf_map_lookup_elem(&qstats, &q);
	if (st) {                                  /* NULL if q >= MAX_QUEUES    */
		/* Different queues run on different CPUs, and (rarely) the same
		 * slot could be hit concurrently: use atomic adds. */
		__sync_fetch_and_add(&st->pkts, 1);
		__sync_fetch_and_add(&st->bytes, (__u64)(data_end - data));
	}

	/* ---- Steer to the socket bound to THIS queue ----
	 * 3rd arg = fallback action when no socket is registered for the queue
	 * (e.g. NIC has more queues than we bound): XDP_PASS to the kernel. */
	return bpf_redirect_map(&xsks_map, q, XDP_PASS);
}

char _license[] SEC("license") = "GPL";
