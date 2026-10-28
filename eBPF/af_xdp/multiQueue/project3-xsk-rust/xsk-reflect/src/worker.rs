//! One worker = one hardware queue = one thread = one AF_XDP socket.
//!
//! "Share nothing": every worker owns its UMEM, its four rings and its free
//! frame list. Rings are single-producer/single-consumer, so as long as exactly
//! one thread touches a given socket, no locks or atomics are needed on the
//! packet path. Only the statistics counters are shared (with the main thread).
//!
//! Ownership of a frame (a UMEM chunk) is always exactly one of:
//!
//!   free list --refill--> FILL ring --> kernel/NIC RX (DMA into the frame)
//!       ^                                          |
//!       |                                          v
//!   COMPLETION ring <-- kernel/NIC TX <-- TX ring <-- [we edit] <-- RX ring
//!
//! `xsk-rs` expresses each hand-over as an `unsafe` call, because the compiler
//! cannot know which side owns a frame; our `free` list is the bookkeeping that
//! makes those calls sound: a `FrameDesc` is in `free`, or in exactly one ring.

use std::{
    io,
    sync::{
        atomic::{AtomicBool, AtomicU64, Ordering},
        Arc,
    },
    thread::{self, JoinHandle},
};

use anyhow::{Context, Result};
use xsk_rs::{
    config::{BindFlags, Interface, LibxdpFlags, SocketConfig, UmemConfig},
    socket::Fd,
    CompQueue, FillQueue, FrameDesc, RxQueue, Socket, TxQueue, Umem,
};

use crate::packet;

/// Descriptors handled per loop pass.
const BATCH_SIZE: usize = 64;
/// How long `poll()` may sleep, so Ctrl-C is noticed quickly (milliseconds).
const POLL_TIMEOUT_MS: i32 = 100;
/// How many frames to preload into the FILL ring at start (= default ring size).
const FILL_PRIME: usize = 2048;

/// Counters written by the worker, read by the main thread.
/// 64-byte aligned so two workers' counters never share a cache line.
#[repr(align(64))]
#[derive(Default)]
pub struct WorkerStats {
    /// Frames taken from the RX ring.
    pub rx: AtomicU64,
    /// Frames the NIC confirmed as transmitted (seen on the COMPLETION ring).
    pub tx: AtomicU64,
    /// Frames received but not reflected (not IPv4/UDP).
    pub dropped: AtomicU64,
}

pub struct Worker {
    pub queue_id: u32,
    stats: Arc<WorkerStats>,

    // The four rings. FILL/COMPLETION belong to the UMEM, RX/TX to the socket.
    fq: FillQueue, // we produce: empty frames for the NIC to receive into
    cq: CompQueue, // we consume: frames the NIC finished sending
    rx_q: RxQueue, // we consume: received packets
    tx_q: TxQueue, // we produce: packets to send

    /// Frames we currently own that are not in any ring.
    free: Vec<FrameDesc>,

    // Declared LAST on purpose: struct fields are dropped in declaration
    // order, so the queues/socket above are released before the UMEM.
    umem: Umem,
}

impl Worker {
    /// Create the UMEM and the AF_XDP socket for `queue_id`, and give the NIC its
    /// first batch of empty frames. Runs on the main thread (setup is not
    /// performance critical, and keeps error handling simple).
    pub fn new(
        iface: &Interface,
        queue_id: u32,
        frames: u32,
        bind_mode: BindFlags,
    ) -> Result<(Self, Arc<WorkerStats>)> {
        // 1. UMEM: `frames` fixed-size chunks of page-aligned memory, registered
        //    with the kernel. Returns the Umem plus one FrameDesc per chunk.
        let (umem, free) = Umem::new(
            UmemConfig::default(),
            frames.try_into().context("frame count must be > 0")?,
            false, // no hugepages
        )
        .context("creating UMEM")?;

        // 2. Socket bound to (interface, queue_id). This creates the RX/TX rings
        //    and (first socket on a UMEM) the FILL/COMPLETION rings.
        let config = SocketConfig::builder()
            // We load our own XDP program with aya: tell libxdp NOT to load its
            // default one. We fill the XSKMAP ourselves (aya).
            .libxdp_flags(LibxdpFlags::XSK_LIBXDP_FLAGS_INHIBIT_PROG_LOAD)
            // NEED_WAKEUP: the kernel signals when a syscall kick is required.
            .bind_flags(BindFlags::XDP_USE_NEED_WAKEUP | bind_mode)
            .build();

        // SAFETY: this socket is the first and only one on this UMEM, and
        // INHIBIT_PROG_LOAD is set, so libxdp will not touch XDP programs.
        let (tx_q, rx_q, fq_and_cq) = unsafe { Socket::new(config, &umem, iface, queue_id) }
            .with_context(|| format!("creating AF_XDP socket on queue {queue_id} (does the NIC have that many queues?)"))?;
        let (fq, cq) = fq_and_cq.context("expected a fill/completion queue pair")?;

        let stats = Arc::new(WorkerStats::default());
        let mut w = Worker { queue_id, stats: stats.clone(), fq, cq, rx_q, tx_q, free, umem };

        // 3. All frames start out free; preload the FILL ring so the NIC has
        //    buffers to DMA into from the very first packet.
        w.refill(FILL_PRIME);
        Ok((w, stats))
    }

    /// The socket's file descriptor: inserted into the XSKMAP by `main`.
    pub fn fd(&self) -> &Fd {
        self.rx_q.fd()
    }

    /// Start the packet loop on its own thread, optionally pinned to a CPU.
    pub fn spawn(self, running: Arc<AtomicBool>, cpu: Option<usize>) -> JoinHandle<()> {
        thread::Builder::new()
            .name(format!("xsk-q{}", self.queue_id))
            .spawn(move || self.run(&running, cpu))
            .expect("failed to spawn worker thread")
    }

    // ------------------------------------------------------------------
    // The packet loop
    // ------------------------------------------------------------------
    fn run(mut self, running: &AtomicBool, cpu: Option<usize>) {
        // Pinning keeps this queue's rings/UMEM hot in one core's cache and
        // stops the scheduler from migrating the thread.
        if let Some(cpu) = cpu {
            if let Err(e) = pin_to_cpu(cpu) {
                eprintln!("queue {}: cannot pin to CPU {cpu}: {e}", self.queue_id);
            }
        }

        // Scratch buffers, reused for every batch (no allocation in the loop).
        // They only carry descriptors between ring calls; they do not own frames.
        let mut rx_descs = [FrameDesc::default(); BATCH_SIZE];
        let mut cq_descs = [FrameDesc::default(); BATCH_SIZE];
        let mut tx_descs: Vec<FrameDesc> = Vec::with_capacity(BATCH_SIZE);

        while running.load(Ordering::Relaxed) {
            // Keep the NIC supplied with RX buffers.
            self.refill(BATCH_SIZE);

            // Sleep until packets arrive (capped, so shutdown is prompt). With
            // NEED_WAKEUP, poll() is also what nudges the driver when the FILL
            // ring ran dry.
            // SAFETY: descriptors come from this worker's own RX ring/UMEM.
            let n = match unsafe { self.rx_q.poll_and_consume(&mut rx_descs, POLL_TIMEOUT_MS) } {
                Ok(n) => n,
                Err(e) => {
                    eprintln!("queue {}: poll/consume failed: {e}", self.queue_id);
                    break;
                }
            };

            if n > 0 {
                self.process_batch(&mut rx_descs[..n], &mut tx_descs, &mut cq_descs, running);
            }
            self.reap_completions(&mut cq_descs); // COMPLETION ring -> free list
        }
    }

    /// RX -> edit in place -> TX.
    fn process_batch(
        &mut self,
        rx: &mut [FrameDesc],
        tx: &mut Vec<FrameDesc>,
        cq_scratch: &mut [FrameDesc],
        running: &AtomicBool,
    ) {
        self.stats.rx.fetch_add(rx.len() as u64, Ordering::Relaxed);
        tx.clear();

        // 1) Edit each packet IN PLACE inside the UMEM. A FrameDesc is just
        //    {addr, lengths}: `data_mut` is where an offset becomes a slice.
        for desc in rx.iter_mut() {
            // SAFETY: `desc` was just handed to us by the kernel via our RX
            // ring, so we exclusively own this frame until we resubmit it.
            let reflected = {
                let mut data = unsafe { self.umem.data_mut(desc) };
                packet::reflect_udp(data.contents_mut())
            };
            if reflected {
                tx.push(*desc); // same frame goes to TX: ownership moves on
            } else {
                self.free.push(*desc); // not ours to answer: recycle the frame
                self.stats.dropped.fetch_add(1, Ordering::Relaxed);
            }
        }

        // 2) Submit to the TX ring. `produce_and_wakeup` also kicks the kernel
        //    (sendto) when the ring's NEED_WAKEUP flag is set. If the ring is
        //    full it returns 0: reap completions to make room, then retry.
        let mut sent = 0;
        while sent < tx.len() {
            // SAFETY: frames in `tx` are owned by us and not in any other ring.
            match unsafe { self.tx_q.produce_and_wakeup(&tx[sent..]) } {
                Ok(0) => {
                    if !running.load(Ordering::Relaxed) {
                        break; // shutting down: stop retrying
                    }
                    self.reap_completions(cq_scratch);
                }
                Ok(n) => sent += n,
                Err(e) => {
                    eprintln!("queue {}: tx wakeup failed: {e}", self.queue_id);
                    break;
                }
            }
        }
        // Anything not submitted is still ours: put it back on the free list.
        self.free.extend_from_slice(&tx[sent..]);
    }

    /// FILL ring: hand up to `max` empty frames to the kernel.
    fn refill(&mut self, max: usize) {
        let mut n = self.free.len().min(max);
        // `produce` is all-or-nothing: if the ring has less room than `n` it
        // returns 0. Retry with smaller batches instead of starving.
        while n > 0 {
            let start = self.free.len() - n;
            // SAFETY: frames in `free` are owned by us and in no ring.
            let produced = unsafe { self.fq.produce(&self.free[start..]) };
            if produced > 0 {
                self.free.truncate(self.free.len() - produced);
                return;
            }
            n /= 2;
        }
    }

    /// COMPLETION ring: reclaim frames the NIC has finished transmitting.
    fn reap_completions(&mut self, scratch: &mut [FrameDesc]) {
        // SAFETY: descriptors come from this worker's own COMPLETION ring.
        let n = unsafe { self.cq.consume(scratch) };
        if n > 0 {
            self.free.extend_from_slice(&scratch[..n]);
            self.stats.tx.fetch_add(n as u64, Ordering::Relaxed);
        }
    }
}

/// Pin the CALLING thread to one CPU.
fn pin_to_cpu(cpu: usize) -> io::Result<()> {
    if cpu >= libc::CPU_SETSIZE as usize {
        return Err(io::Error::new(io::ErrorKind::InvalidInput, "cpu index too large"));
    }
    // SAFETY: `set` is a plain bitmask structure owned by this stack frame.
    unsafe {
        let mut set: libc::cpu_set_t = std::mem::zeroed();
        libc::CPU_ZERO(&mut set);
        libc::CPU_SET(cpu, &mut set);
        // pid 0 = the calling thread.
        if libc::sched_setaffinity(0, std::mem::size_of::<libc::cpu_set_t>(), &set) != 0 {
            return Err(io::Error::last_os_error());
        }
    }
    Ok(())
}
