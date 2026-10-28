// SPDX-License-Identifier: GPL-2.0
/*
 * xsk_reflect_mq.c - Project 2: multi-queue, multi-threaded AF_XDP reflector.
 *
 * Libraries used
 * --------------
 *   libbpf : open/load the eBPF object, attach XDP, read the qstats map,
 *            capture verifier/log messages.
 *   libxdp : the xsk_* helpers (UMEM, socket, ring access).
 *
 * Architecture: "share nothing" - one worker thread per RX queue
 * ---------------------------------------------------------------
 *
 *   NIC RSS hash (UDP 4-tuple) spreads flows over N hardware queues
 *
 *     queue 0          queue 1          ...        queue N-1
 *        |                |                            |
 *   XDP redirect     XDP redirect                XDP redirect     (xsks_map[q])
 *        |                |                            |
 *      XSK 0            XSK 1                       XSK N-1
 *   [UMEM+4 rings]   [UMEM+4 rings]              [UMEM+4 rings]
 *        |                |                            |
 *    thread 0         thread 1                    thread N-1  (each pinned to a CPU)
 *
 * Every worker owns its OWN UMEM, its OWN four rings and its OWN free-frame
 * stack. The rings are single-producer/single-consumer, so as long as exactly
 * one thread touches a given socket, NO LOCKS and NO ATOMICS are needed on the
 * fast path. The only cross-thread traffic is the statistics counters, which
 * the main thread reads.
 *
 * Per-worker frame life-cycle (identical to Project 1):
 *
 *   free stack --> FILL ring --> NIC RX --> RX ring --> [swap headers]
 *        ^                                                    |
 *        +---- COMPLETION ring <-- NIC TX <-- TX ring <-------+
 */
#define _GNU_SOURCE
#include <errno.h>
#include <getopt.h>
#include <inttypes.h>
#include <net/if.h>           /* if_nametoindex(), struct ifreq            */
#include <netinet/in.h>       /* htons(), IPPROTO_UDP                      */
#include <poll.h>
#include <pthread.h>
#include <sched.h>            /* cpu_set_t, CPU_SET                        */
#include <signal.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>

#include <linux/ethtool.h>    /* ETHTOOL_GCHANNELS (query queue count)     */
#include <linux/if_ether.h>   /* struct ethhdr, ETH_P_IP, ETH_ALEN         */
#include <linux/if_link.h>    /* XDP_FLAGS_DRV_MODE                        */
#include <linux/if_xdp.h>     /* XDP_* flags, struct xdp_desc/options      */
#include <linux/ip.h>         /* struct iphdr                              */
#include <linux/sockios.h>    /* SIOCETHTOOL                               */
#include <linux/udp.h>        /* struct udphdr                             */

#include <bpf/bpf.h>          /* bpf_xdp_attach/detach, bpf_map_lookup_elem */
#include <bpf/libbpf.h>       /* bpf_object__*, libbpf_set_print            */
#include <xdp/xsk.h>          /* xsk_umem__*, xsk_socket__*, ring helpers   */

#include "common.h"

#ifndef SOL_XDP
#define SOL_XDP 283
#endif

/* ------------------------------------------------------------------------ */
/* Tunables (per worker)                                                    */
/* ------------------------------------------------------------------------ */
#define NUM_FRAMES  4096                         /* frames per UMEM           */
#define FRAME_SIZE  XSK_UMEM__DEFAULT_FRAME_SIZE /* 4096 B per frame          */
#define BATCH_SIZE  64                           /* descriptors per loop pass */
#define FILL_PRIME  XSK_RING_PROD__DEFAULT_NUM_DESCS

/* ------------------------------------------------------------------------ */
/* Global configuration (written once in main, read-only afterwards)        */
/* ------------------------------------------------------------------------ */
static const char *g_ifname;          /* interface to attach to               */
static int         g_nqueues = 4;     /* number of queues == number of threads */
static int         g_first_cpu = -1;  /* pin worker i to CPU first_cpu+i; -1 = no pin */
static uint16_t    g_mode_flag;       /* 0 = auto (try ZC), XDP_ZEROCOPY, XDP_COPY */
static int         g_verbose;         /* libbpf debug output                  */

static volatile sig_atomic_t running = 1;   /* cleared by SIGINT/SIGTERM      */

static void on_signal(int sig)
{
	(void)sig;
	running = 0;
}

/* ------------------------------------------------------------------------ */
/* One worker == one queue == one thread == one XSK                         */
/* ------------------------------------------------------------------------ */
struct worker {
	/* identity */
	uint32_t  queue_id;           /* RX/TX hardware queue this worker owns  */
	int       cpu;                /* CPU to pin to (-1 = don't)             */
	pthread_t thread;
	int       started;            /* pthread_create succeeded?              */

	/* UMEM: this worker's private packet memory */
	void            *umem_area;
	struct xsk_umem *umem;

	/* the four rings ("prod" = we write, "cons" = we read) */
	struct xsk_ring_prod fill;    /* UMEM-level : we give EMPTY frames       */
	struct xsk_ring_cons comp;    /* UMEM-level : kernel returns SENT frames */
	struct xsk_ring_cons rx;      /* socket-level: kernel gives RECEIVED     */
	struct xsk_ring_prod tx;      /* socket-level: we give frames to SEND    */

	/* the socket */
	struct xsk_socket *xsk;
	int                xsk_fd;

	/* frames we own that are not in any ring (UMEM offsets) */
	uint64_t free_stack[NUM_FRAMES];
	uint32_t free_cnt;

	/* statistics: written only by this worker, read by the main thread */
	uint64_t rx_pkts;
	uint64_t tx_pkts;
	uint64_t dropped;
} __attribute__((aligned(64)));  /* own cache lines: no false sharing between workers */

/* ------------------------------------------------------------------------ */
/* Frame bookkeeping                                                        */
/* ------------------------------------------------------------------------ */

/* RX/COMPLETION addresses may point inside a frame (XDP headroom); the FILL
 * ring wants the frame base, so align down. */
static inline uint64_t frame_base(uint64_t addr)
{
	return addr & ~((uint64_t)FRAME_SIZE - 1);
}

static inline void frame_free(struct worker *w, uint64_t addr)
{
	w->free_stack[w->free_cnt++] = frame_base(addr);
}

/* ------------------------------------------------------------------------ */
/* FILL ring: give empty frames to the kernel so the NIC has RX buffers     */
/* ------------------------------------------------------------------------ */
static void refill_fill_ring(struct worker *w, uint32_t max)
{
	uint32_t n = w->free_cnt < max ? w->free_cnt : max;
	uint32_t idx;

	uint32_t room = xsk_prod_nb_free(&w->fill, n);   /* free slots in ring */
	if (room < n)
		n = room;
	if (!n)
		return;

	/* Producer pattern: reserve -> write -> submit */
	if (xsk_ring_prod__reserve(&w->fill, n, &idx) != n)
		return;
	for (uint32_t i = 0; i < n; i++)
		*xsk_ring_prod__fill_addr(&w->fill, idx++) =
			w->free_stack[--w->free_cnt];
	xsk_ring_prod__submit(&w->fill, n);
}

/* ------------------------------------------------------------------------ */
/* COMPLETION ring: reclaim frames the NIC has finished transmitting        */
/* ------------------------------------------------------------------------ */
static void complete_tx(struct worker *w)
{
	uint32_t idx;

	/* Consumer pattern: peek -> read -> release */
	uint32_t n = xsk_ring_cons__peek(&w->comp, BATCH_SIZE, &idx);
	if (!n)
		return;
	for (uint32_t i = 0; i < n; i++)
		frame_free(w, *xsk_ring_cons__comp_addr(&w->comp, idx++));
	xsk_ring_cons__release(&w->comp, n);

	/* Relaxed atomic store: the main thread reads this concurrently. */
	__atomic_add_fetch(&w->tx_pkts, n, __ATOMIC_RELAXED);
}

/* With XDP_USE_NEED_WAKEUP a syscall is only needed when the kernel asks. */
static void kick_tx(struct worker *w)
{
	if (xsk_ring_prod__needs_wakeup(&w->tx))
		sendto(w->xsk_fd, NULL, 0, MSG_DONTWAIT, NULL, 0);
}

/* ------------------------------------------------------------------------ */
/* Packet edit: request -> "reply" by swapping source and destination       */
/* ------------------------------------------------------------------------ */
/*
 * Swaps MACs, IPv4 addresses and UDP ports in place. No checksum fix-up is
 * needed: IP/UDP checksums are one's-complement sums, which are commutative,
 * so exchanging two summed fields leaves the sum unchanged.
 * Returns 0 on success, -1 if the frame isn't the IPv4/UDP we expect.
 */
static int reflect_udp(uint8_t *pkt, uint32_t len)
{
	if (len < ETH_HLEN + sizeof(struct iphdr) + sizeof(struct udphdr))
		return -1;

	struct ethhdr *eth = (struct ethhdr *)pkt;
	if (eth->h_proto != htons(ETH_P_IP))
		return -1;

	struct iphdr *ip = (struct iphdr *)(eth + 1);
	uint32_t ihl = ip->ihl * 4u;
	if (ip->protocol != IPPROTO_UDP || ihl < sizeof(*ip) ||
	    len < ETH_HLEN + ihl + sizeof(struct udphdr))
		return -1;

	struct udphdr *udp = (struct udphdr *)((uint8_t *)ip + ihl);

	uint8_t mac[ETH_ALEN];                       /* MAC swap  */
	memcpy(mac, eth->h_source, ETH_ALEN);
	memcpy(eth->h_source, eth->h_dest, ETH_ALEN);
	memcpy(eth->h_dest, mac, ETH_ALEN);

	uint32_t a = ip->saddr;                      /* IP swap   */
	ip->saddr = ip->daddr;
	ip->daddr = a;

	uint16_t p = udp->source;                    /* port swap */
	udp->source = udp->dest;
	udp->dest = p;
	return 0;
}

/* ------------------------------------------------------------------------ */
/* RX -> edit -> TX                                                         */
/* ------------------------------------------------------------------------ */
static void process_rx(struct worker *w)
{
	uint32_t idx_rx = 0;
	struct xdp_desc ok[BATCH_SIZE];   /* descriptors that will be transmitted */
	uint32_t n_ok = 0;

	/* 1) Take a batch of received descriptors from the RX ring. */
	uint32_t rcvd = xsk_ring_cons__peek(&w->rx, BATCH_SIZE, &idx_rx);
	if (!rcvd)
		return;
	__atomic_add_fetch(&w->rx_pkts, rcvd, __ATOMIC_RELAXED);

	/* 2) Edit each packet in place. A descriptor is {addr, len}; addr is an
	 *    OFFSET into this worker's UMEM, turned into a pointer only here. */
	for (uint32_t i = 0; i < rcvd; i++) {
		const struct xdp_desc *d = xsk_ring_cons__rx_desc(&w->rx, idx_rx++);
		uint8_t *pkt = xsk_umem__get_data(w->umem_area, d->addr);

		if (reflect_udp(pkt, d->len) == 0) {
			ok[n_ok++] = *d;
		} else {
			frame_free(w, d->addr);      /* not ours: recycle */
			__atomic_add_fetch(&w->dropped, 1, __ATOMIC_RELAXED);
		}
	}

	/* 3) RX descriptors consumed: give the RX ring slots back. */
	xsk_ring_cons__release(&w->rx, rcvd);
	if (!n_ok)
		return;

	/* 4) Reserve TX slots; if full, reap completions and kick, then retry. */
	uint32_t idx_tx = 0;
	while (xsk_ring_prod__reserve(&w->tx, n_ok, &idx_tx) != n_ok) {
		if (!running) {
			for (uint32_t i = 0; i < n_ok; i++)
				frame_free(w, ok[i].addr);
			return;
		}
		complete_tx(w);
		kick_tx(w);
	}

	/* 5) Same frame goes to TX: ownership passes to the kernel. */
	for (uint32_t i = 0; i < n_ok; i++) {
		struct xdp_desc *t = xsk_ring_prod__tx_desc(&w->tx, idx_tx++);
		t->addr = ok[i].addr;
		t->len  = ok[i].len;
	}
	xsk_ring_prod__submit(&w->tx, n_ok);
	kick_tx(w);
}

/* ------------------------------------------------------------------------ */
/* Worker thread body                                                       */
/* ------------------------------------------------------------------------ */
static void *worker_main(void *arg)
{
	struct worker *w = arg;

	/* Pin to a CPU: keeps this queue's rings/UMEM hot in one core's cache and
	 * avoids the scheduler bouncing the thread around. */
	if (w->cpu >= 0) {
		cpu_set_t set;
		CPU_ZERO(&set);
		CPU_SET(w->cpu, &set);
		int e = pthread_setaffinity_np(pthread_self(), sizeof(set), &set);
		if (e)
			fprintf(stderr, "queue %u: cannot pin to CPU %d: %s\n",
				w->queue_id, w->cpu, strerror(e));
	}

	struct pollfd pfd = { .fd = w->xsk_fd, .events = POLLIN };

	while (running) {
		refill_fill_ring(w, BATCH_SIZE);  /* keep the NIC supplied with buffers  */
		poll(&pfd, 1, 100);               /* sleep until RX (100 ms cap for Ctrl-C);
						   * also wakes the driver if FILL ran dry */
		process_rx(w);                    /* RX ring -> edit -> TX ring          */
		complete_tx(w);                   /* COMPLETION ring -> free stack       */
	}
	return NULL;
}

/* ------------------------------------------------------------------------ */
/* libbpf: load + attach                                                    */
/* ------------------------------------------------------------------------ */

/* Route libbpf's messages (warnings, and the verifier log on load failure) to
 * stderr; debug-level chatter only with -v. */
static int libbpf_print(enum libbpf_print_level level, const char *fmt, va_list ap)
{
	if (level == LIBBPF_DEBUG && !g_verbose)
		return 0;
	return vfprintf(stderr, fmt, ap);
}

/* Open + load the eBPF object, attach XDP in native mode, and hand back the
 * file descriptors of the two maps we need. */
static int load_and_attach_xdp(const char *obj_path, int ifindex,
			       struct bpf_object **obj_out,
			       int *xsks_map_fd, int *qstats_fd)
{
	/* Parse the ELF, create map/program placeholders. */
	struct bpf_object *obj = bpf_object__open_file(obj_path, NULL);
	if (!obj) {
		fprintf(stderr, "open %s failed: %s\n", obj_path, strerror(errno));
		return -1;
	}

	/* Create maps in the kernel and load the program (verifier runs here). */
	int err = bpf_object__load(obj);
	if (err) {
		fprintf(stderr, "bpf_object__load: %s\n", strerror(-err));
		bpf_object__close(obj);
		return -1;
	}

	struct bpf_program *prog = bpf_object__find_program_by_name(obj, "xsk_redirect_prog");
	struct bpf_map *m_xsks   = bpf_object__find_map_by_name(obj, "xsks_map");
	struct bpf_map *m_qstats = bpf_object__find_map_by_name(obj, "qstats");
	if (!prog || !m_xsks || !m_qstats) {
		fprintf(stderr, "program/maps not found in %s\n", obj_path);
		bpf_object__close(obj);
		return -1;
	}

	/* DRV_MODE = native XDP inside the mlx5 driver (needed for zero-copy). */
	err = bpf_xdp_attach(ifindex, bpf_program__fd(prog), XDP_FLAGS_DRV_MODE, NULL);
	if (err) {
		fprintf(stderr, "XDP attach (native) failed: %s\n", strerror(-err));
		bpf_object__close(obj);
		return -1;
	}

	*obj_out     = obj;
	*xsks_map_fd = bpf_map__fd(m_xsks);
	*qstats_fd   = bpf_map__fd(m_qstats);
	return 0;
}

/* Warn if the NIC's queue count doesn't match what we bind. If the NIC has
 * MORE queues than we serve, flows hashed there hit an empty XSKMAP slot,
 * fall back to XDP_PASS and never reach us. */
static void check_nic_channels(const char *ifname, int nqueues)
{
	struct ethtool_channels ch = { .cmd = ETHTOOL_GCHANNELS };
	struct ifreq ifr;
	int fd = socket(AF_INET, SOCK_DGRAM, 0);

	if (fd < 0)
		return;
	memset(&ifr, 0, sizeof(ifr));
	strncpy(ifr.ifr_name, ifname, IFNAMSIZ - 1);
	ifr.ifr_data = (void *)&ch;

	if (ioctl(fd, SIOCETHTOOL, &ifr) == 0) {
		/* mlx5 reports its queues as "combined" channels. */
		uint32_t nic_q = ch.combined_count ? ch.combined_count : ch.rx_count;
		if (nic_q != (uint32_t)nqueues)
			fprintf(stderr,
				"WARNING: NIC has %u queues but -n %d was requested.\n"
				"         Run: sudo ethtool -L %s combined %d\n",
				nic_q, nqueues, ifname, nqueues);
	}
	close(fd);
}

/* ------------------------------------------------------------------------ */
/* libxdp: per-worker UMEM + socket                                         */
/* ------------------------------------------------------------------------ */
static int worker_setup(struct worker *w, int xsks_map_fd)
{
	/* 1) UMEM memory: page-aligned, private to this worker. */
	size_t umem_size = (size_t)NUM_FRAMES * FRAME_SIZE;
	if (posix_memalign(&w->umem_area, getpagesize(), umem_size)) {
		fprintf(stderr, "queue %u: posix_memalign failed\n", w->queue_id);
		return -1;
	}
	memset(w->umem_area, 0, umem_size);

	/* 2) Register it: creates + mmaps the FILL and COMPLETION rings. */
	int err = xsk_umem__create(&w->umem, w->umem_area, umem_size,
				   &w->fill, &w->comp, NULL);
	if (err) {
		fprintf(stderr, "queue %u: xsk_umem__create: %s\n",
			w->queue_id, strerror(-err));
		return -1;
	}

	/* 3) Socket bound to (interface, THIS queue): creates RX + TX rings. */
	struct xsk_socket_config cfg = {
		.rx_size      = XSK_RING_CONS__DEFAULT_NUM_DESCS,
		.tx_size      = XSK_RING_PROD__DEFAULT_NUM_DESCS,
		/* We attached our own XDP program: don't let libxdp load its own. */
		.libxdp_flags = XSK_LIBXDP_FLAGS__INHIBIT_PROG_LOAD,
		.bind_flags   = XDP_USE_NEED_WAKEUP | g_mode_flag,
	};
	err = xsk_socket__create(&w->xsk, g_ifname, w->queue_id, w->umem,
				 &w->rx, &w->tx, &cfg);
	if (err) {
		fprintf(stderr, "queue %u: xsk_socket__create: %s "
			"(does the NIC have that many queues?)\n",
			w->queue_id, strerror(-err));
		return -1;
	}
	w->xsk_fd = xsk_socket__fd(w->xsk);

	/* 4) xsks_map[queue_id] = this socket. From now on XDP can redirect. */
	err = xsk_socket__update_xskmap(w->xsk, xsks_map_fd);
	if (err) {
		fprintf(stderr, "queue %u: update xskmap: %s\n",
			w->queue_id, strerror(-err));
		return -1;
	}

	/* 5) All frames start free; preload the FILL ring. */
	for (uint32_t i = 0; i < NUM_FRAMES; i++)
		w->free_stack[w->free_cnt++] = (uint64_t)i * FRAME_SIZE;
	refill_fill_ring(w, FILL_PRIME);

	/* 6) Report zero-copy vs copy mode chosen by the kernel. */
	struct xdp_options opts;
	socklen_t optlen = sizeof(opts);
	if (getsockopt(w->xsk_fd, SOL_XDP, XDP_OPTIONS, &opts, &optlen) == 0)
		printf("queue %2u: %s\n", w->queue_id,
		       (opts.flags & XDP_OPTIONS_ZEROCOPY) ? "ZERO-COPY" : "COPY");
	return 0;
}

/* Release everything a worker owns (safe on partially-initialised workers). */
static void worker_destroy(struct worker *w)
{
	if (w->xsk)
		xsk_socket__delete(w->xsk);   /* also removes it from the XSKMAP */
	if (w->umem)
		xsk_umem__delete(w->umem);
	free(w->umem_area);
}

/* ------------------------------------------------------------------------ */
/* Statistics (main thread)                                                 */
/* ------------------------------------------------------------------------ */
static void print_stats(struct worker *ws, int n, int qstats_fd,
			uint64_t *prev_xdp, uint64_t *prev_rx, uint64_t *prev_tx)
{
	uint64_t d_xdp[MAX_QUEUES], d_rx[MAX_QUEUES], d_tx[MAX_QUEUES];
	uint64_t t_xdp = 0, t_rx = 0, t_tx = 0;

	for (int i = 0; i < n; i++) {
		/* libbpf: read this queue's counters out of the eBPF map. */
		struct qstat st = { 0 };
		__u32 key = ws[i].queue_id;
		if (bpf_map_lookup_elem(qstats_fd, &key, &st))
			st.pkts = 0;

		uint64_t rx = __atomic_load_n(&ws[i].rx_pkts, __ATOMIC_RELAXED);
		uint64_t tx = __atomic_load_n(&ws[i].tx_pkts, __ATOMIC_RELAXED);

		d_xdp[i] = st.pkts - prev_xdp[i];  prev_xdp[i] = st.pkts;
		d_rx[i]  = rx - prev_rx[i];        prev_rx[i]  = rx;
		d_tx[i]  = tx - prev_tx[i];        prev_tx[i]  = tx;
		t_xdp += d_xdp[i]; t_rx += d_rx[i]; t_tx += d_tx[i];
	}

	if (!t_xdp && !t_rx && !t_tx)         /* stay quiet while idle */
		return;

	printf("\nqueue |  xdp seen/s |  AF_XDP rx/s |  tx/s\n");
	printf("------+-------------+--------------+----------\n");
	for (int i = 0; i < n; i++)
		printf("%5u | %11" PRIu64 " | %12" PRIu64 " | %8" PRIu64 "\n",
		       ws[i].queue_id, d_xdp[i], d_rx[i], d_tx[i]);
	printf("total | %11" PRIu64 " | %12" PRIu64 " | %8" PRIu64 "\n",
	       t_xdp, t_rx, t_tx);
}

static void usage(const char *prog)
{
	fprintf(stderr,
		"Usage: %s -i <iface> [-n <queues>] [-a <first_cpu>] [-o <xdp_kern.o>] [-z|-c] [-v]\n"
		"  -i  network interface (e.g. enp1s0f0np0)\n"
		"  -n  number of queues == worker threads, queues 0..n-1 (default 4)\n"
		"  -a  pin worker i to CPU (first_cpu + i); default: no pinning\n"
		"  -o  path to the compiled XDP object (default ./xdp_kern.o)\n"
		"  -z  force zero-copy   -c force copy mode\n"
		"  -v  verbose libbpf output\n", prog);
}

/* ------------------------------------------------------------------------ */
/* main                                                                     */
/* ------------------------------------------------------------------------ */
int main(int argc, char **argv)
{
	const char *obj_path = "xdp_kern.o";
	int opt, ret = 1;

	while ((opt = getopt(argc, argv, "i:n:a:o:zcvh")) != -1) {
		switch (opt) {
		case 'i': g_ifname = optarg;            break;
		case 'n': g_nqueues = atoi(optarg);     break;
		case 'a': g_first_cpu = atoi(optarg);   break;
		case 'o': obj_path = optarg;            break;
		case 'z': g_mode_flag = XDP_ZEROCOPY;   break;
		case 'c': g_mode_flag = XDP_COPY;       break;
		case 'v': g_verbose = 1;                break;
		default:  usage(argv[0]); return 1;
		}
	}
	if (!g_ifname || g_nqueues < 1 || g_nqueues > MAX_QUEUES) {
		usage(argv[0]);
		return 1;
	}

	int ifindex = if_nametoindex(g_ifname);
	if (!ifindex) {
		fprintf(stderr, "unknown interface %s\n", g_ifname);
		return 1;
	}

	libbpf_set_print(libbpf_print);       /* capture libbpf/verifier messages */
	check_nic_channels(g_ifname, g_nqueues);

	/* Clean shutdown on Ctrl-C (no SA_RESTART so sleeps/polls are interrupted). */
	struct sigaction sa = { .sa_handler = on_signal };
	sigaction(SIGINT, &sa, NULL);
	sigaction(SIGTERM, &sa, NULL);

	struct bpf_object *obj = NULL;
	int xsks_map_fd = -1, qstats_fd = -1, attached = 0;
	struct worker *workers = NULL;
	uint64_t prev_xdp[MAX_QUEUES] = { 0 }, prev_rx[MAX_QUEUES] = { 0 },
		 prev_tx[MAX_QUEUES] = { 0 };

	/* Step 1 (libbpf): load the object and attach XDP. Attach BEFORE creating
	 * sockets: the mlx5 driver wants XDP enabled when XSK queues are activated. */
	if (load_and_attach_xdp(obj_path, ifindex, &obj, &xsks_map_fd, &qstats_fd))
		goto out;
	attached = 1;

	/* Step 2: allocate the workers (cache-line aligned, zeroed). */
	if (posix_memalign((void **)&workers, 64, sizeof(*workers) * g_nqueues)) {
		fprintf(stderr, "out of memory\n");
		goto out;
	}
	memset(workers, 0, sizeof(*workers) * g_nqueues);

	/* Step 3 (libxdp): create UMEM + XSK + rings for every queue, sequentially
	 * in the main thread (setup is not performance critical, and doing it
	 * here keeps error handling simple). */
	for (int i = 0; i < g_nqueues; i++) {
		workers[i].queue_id = i;
		workers[i].cpu = g_first_cpu >= 0 ? g_first_cpu + i : -1;
		if (worker_setup(&workers[i], xsks_map_fd))
			goto out;
	}

	/* Step 4: start one thread per worker. */
	for (int i = 0; i < g_nqueues; i++) {
		int e = pthread_create(&workers[i].thread, NULL, worker_main, &workers[i]);
		if (e) {
			fprintf(stderr, "pthread_create: %s\n", strerror(e));
			running = 0;
			goto out;
		}
		workers[i].started = 1;
	}
	printf("Reflecting UDP port %d on %s with %d queue(s)/thread(s). Ctrl-C to stop.\n",
	       ECHO_UDP_PORT, g_ifname, g_nqueues);

	/* Step 5: main thread only prints statistics once per second. */
	while (running) {
		struct timespec ts = { .tv_sec = 1 };
		nanosleep(&ts, NULL);             /* returns early on a signal */
		print_stats(workers, g_nqueues, qstats_fd, prev_xdp, prev_rx, prev_tx);
	}
	ret = 0;

out:
	/* Shutdown order: stop workers, detach XDP (no new redirects), then free
	 * sockets/UMEMs, and finally close the BPF object. */
	printf("\nshutting down\n");
	running = 0;
	if (workers)
		for (int i = 0; i < g_nqueues; i++)
			if (workers[i].started)
				pthread_join(workers[i].thread, NULL);
	if (attached)
		bpf_xdp_detach(ifindex, XDP_FLAGS_DRV_MODE, NULL);
	if (workers) {
		for (int i = 0; i < g_nqueues; i++)
			worker_destroy(&workers[i]);
		free(workers);
	}
	if (obj)
		bpf_object__close(obj);
	return ret;
}
