//! xsk-reflect - Project 3: multi-queue AF_XDP UDP reflector in Rust.
//!
//! Libraries
//! ---------
//!   aya     : loads the eBPF object, attaches XDP, owns the XSKS_MAP / QSTATS maps.
//!   xsk-rs  : UMEM, AF_XDP socket and the four rings (wraps libxdp).
//!
//! Architecture (same "share nothing" design as Project 2)
//! --------------------------------------------------------
//!
//!   NIC RSS hash (UDP 4-tuple) spreads flows over N hardware queues
//!
//!      queue 0         queue 1        ...       queue N-1
//!         |               |                        |
//!    XDP redirect    XDP redirect             XDP redirect    XSKS_MAP[queue]
//!         |               |                        |
//!       XSK 0           XSK 1                    XSK N-1
//!    [UMEM+4 rings]  [UMEM+4 rings]           [UMEM+4 rings]
//!         |               |                        |
//!      thread 0        thread 1                thread N-1     (optionally pinned)
//!
//! The main thread loads/attaches the eBPF program, creates the workers, and
//! then only prints statistics once per second.

mod nic;
mod packet;
mod worker;

use std::{
    os::unix::io::{AsRawFd, RawFd},
    path::PathBuf,
    sync::{
        atomic::{AtomicBool, Ordering},
        mpsc, Arc,
    },
    time::Duration,
};

use anyhow::{bail, Context, Result};
use aya::{
    maps::{Array, Map, MapData, PerCpuArray, XskMap},
    programs::{Xdp, XdpFlags},
    Ebpf,
};
use clap::Parser;
use xsk_reflect_common::{QStat, ECHO_UDP_PORT, MAX_QUEUES};
use xsk_rs::config::{BindFlags, Interface};

use worker::{Worker, WorkerStats};

/// Multi-queue AF_XDP UDP reflector (aya + xsk-rs).
#[derive(Parser, Debug)]
#[command(version, about)]
struct Args {
    /// Network interface to attach to (e.g. enp1s0f0np0)
    #[arg(short, long)]
    iface: String,

    /// Number of queues == worker threads; binds queues 0..N-1
    #[arg(short = 'n', long, default_value_t = 4)]
    queues: u32,

    /// Pin worker i to CPU (first_cpu + i). Default: no pinning
    #[arg(short = 'a', long)]
    first_cpu: Option<usize>,

    /// Compiled eBPF object (build it with `make ebpf`)
    #[arg(
        short = 'o',
        long,
        default_value = "xsk-reflect-ebpf/target/bpfel-unknown-none/release/xsk-reflect-ebpf"
    )]
    bpf_obj: PathBuf,

    /// XDP program name inside the object. Defaults match the Rust eBPF crate;
    /// for Project 2's C object use: --prog xsk_redirect_prog
    #[arg(long, default_value = "xsk_redirect")]
    prog: String,

    /// XSKMAP name (C object: xsks_map)
    #[arg(long, default_value = "XSKS_MAP")]
    xsks_map: String,

    /// Per-queue stats map name (C object: qstats; ARRAY and PERCPU_ARRAY both work)
    #[arg(long, default_value = "QSTATS")]
    qstats_map: String,

    /// Force zero-copy (fail if the driver cannot do it)
    #[arg(short = 'z', long, conflicts_with = "copy")]
    zero_copy: bool,

    /// Force copy mode
    #[arg(short = 'c', long)]
    copy: bool,

    /// UMEM frames per queue (each frame is 4 KiB)
    #[arg(long, default_value_t = 4096)]
    frames: u32,
}

fn main() -> Result<()> {
    env_logger::init(); // aya reports through `log`; see it with RUST_LOG=debug
    let args = Args::parse();

    if args.queues == 0 || args.queues > MAX_QUEUES {
        bail!("--queues must be between 1 and {MAX_QUEUES}");
    }

    // Warn early if the NIC queue count differs from what we will serve. With
    // MORE NIC queues than sockets, flows hashed to an unserved queue fall back
    // to XDP_PASS and are never reflected.
    match nic::channel_count(&args.iface) {
        Some(nic_q) if nic_q != args.queues => eprintln!(
            "WARNING: NIC has {nic_q} queues but --queues {} was requested.\n         \
             Run: sudo ethtool -L {} combined {}",
            args.queues, args.iface, args.queues
        ),
        _ => {}
    }

    // ------------------------------------------------------------------
    // Step 1 (aya): load the eBPF object and attach XDP in NATIVE mode.
    // Attach BEFORE creating sockets: the mlx5 driver wants XDP enabled when
    // XSK queues are activated.
    // ------------------------------------------------------------------
    let mut ebpf = Ebpf::load_file(&args.bpf_obj)
        .with_context(|| format!("loading eBPF object {} (did you run `make ebpf`?)", args.bpf_obj.display()))?;

    let link_id = {
        let prog: &mut Xdp = ebpf
            .program_mut(&args.prog)
            .with_context(|| format!("program '{}' not found in the eBPF object", args.prog))?
            .try_into()?;
        prog.load().context("loading XDP program (verifier error?)")?;
        // DRV_MODE = native XDP inside the mlx5 driver; needed for zero-copy.
        prog.attach(&args.iface, XdpFlags::DRV_MODE)
            .context("attaching XDP in native mode (MTU <= 1500? LRO off? another XDP program attached?)")?
    };

    // Take ownership of the two maps (so we do not keep `ebpf` borrowed).
    let mut xsks_map = XskMap::try_from(
        ebpf.take_map(&args.xsks_map)
            .with_context(|| format!("map '{}' not found", args.xsks_map))?,
    )
    .with_context(|| format!("map '{}' is not an XSKMAP", args.xsks_map))?;
    let qstats = QStats::from_map(
        ebpf.take_map(&args.qstats_map)
            .with_context(|| format!("map '{}' not found", args.qstats_map))?,
    )
    .with_context(|| format!("map '{}' has an unsupported type", args.qstats_map))?;

    // ------------------------------------------------------------------
    // Step 2 (xsk-rs + aya): one worker per queue.
    //   Worker::new -> UMEM + socket + rings (xsk-rs)
    //   xsks_map.set -> XSKS_MAP[queue] = socket fd (aya)
    // ------------------------------------------------------------------
    let iface: Interface = args.iface.parse().context("invalid interface name")?;
    let bind_mode = if args.zero_copy {
        BindFlags::XDP_ZEROCOPY
    } else if args.copy {
        BindFlags::XDP_COPY
    } else {
        BindFlags::empty() // let the kernel try zero-copy, then fall back
    };

    let mut workers = Vec::new();
    let mut all_stats: Vec<Arc<WorkerStats>> = Vec::new();
    for q in 0..args.queues {
        let (worker, stats) = Worker::new(&iface, q, args.frames, bind_mode)?;

        // From this point XDP can redirect packets from queue q to this socket.
        // (The kernel keeps its own reference to the socket, so the map entry
        // stays valid even though we only pass the fd number here.)
        xsks_map
            .set(q, SocketFd(worker.fd().as_raw_fd()), 0)
            .with_context(|| format!("inserting queue {q} socket into the XSKMAP"))?;

        let mode = match nic::is_zero_copy(worker.fd().as_raw_fd()) {
            Some(true) => "ZERO-COPY",
            Some(false) => "COPY",
            None => "unknown",
        };
        println!("queue {q:2}: {mode}");

        workers.push(worker);
        all_stats.push(stats);
    }

    // ------------------------------------------------------------------
    // Step 3: start the threads.
    // ------------------------------------------------------------------
    let running = Arc::new(AtomicBool::new(true));
    let handles: Vec<_> = workers
        .into_iter()
        .enumerate()
        .map(|(i, w)| w.spawn(running.clone(), args.first_cpu.map(|c| c + i)))
        .collect();

    // Ctrl-C wakes the main thread immediately through a channel.
    let (stop_tx, stop_rx) = mpsc::channel::<()>();
    ctrlc::set_handler(move || {
        let _ = stop_tx.send(());
    })
    .context("installing Ctrl-C handler")?;

    println!(
        "Reflecting UDP port {ECHO_UDP_PORT} on {} with {} queue(s)/thread(s). Ctrl-C to stop.",
        args.iface, args.queues
    );

    // ------------------------------------------------------------------
    // Step 4: statistics once per second until Ctrl-C.
    // ------------------------------------------------------------------
    let n = args.queues as usize;
    let mut prev = vec![Snapshot::default(); n];
    loop {
        match stop_rx.recv_timeout(Duration::from_secs(1)) {
            Err(mpsc::RecvTimeoutError::Timeout) => print_stats(&all_stats, &qstats, &mut prev),
            _ => break, // signal received (or handler dropped)
        }
    }

    // ------------------------------------------------------------------
    // Shutdown: stop workers, detach XDP (no new redirects), then everything
    // else (sockets/UMEMs were moved into the threads and drop with them).
    // ------------------------------------------------------------------
    println!("\nshutting down");
    running.store(false, Ordering::Relaxed);
    for h in handles {
        let _ = h.join();
    }
    if let Some(Ok(prog)) = ebpf.program_mut(&args.prog).map(<&mut Xdp>::try_from) {
        let _ = prog.detach(link_id);
    }
    Ok(())
}

/// The per-queue counters map, in either of the two flavours we support:
///
///  * `PerCpu` - the Rust eBPF program: a PER-CPU array. The kernel keeps one
///    {pkts, bytes} copy per CPU; we read all copies and sum them.
///  * `Plain`  - Project 2's C object: an ordinary ARRAY updated atomically,
///    one copy per queue (used with the `--prog/--xsks-map/--qstats-map` fallback).
enum QStats {
    PerCpu(PerCpuArray<MapData, QStat>),
    Plain(Array<MapData, QStat>),
}

impl QStats {
    /// Pick the wrapper that matches the map's actual type.
    fn from_map(map: Map) -> Result<Self> {
        match map {
            // `_` does not move the map, so it can still be converted below.
            Map::PerCpuArray(_) => Ok(Self::PerCpu(PerCpuArray::try_from(map)?)),
            Map::Array(_) => Ok(Self::Plain(Array::try_from(map)?)),
            _ => bail!("the stats map must be an ARRAY or PERCPU_ARRAY"),
        }
    }

    /// Packets the XDP program counted on `queue` so far.
    fn pkts(&self, queue: u32) -> u64 {
        match self {
            // One value per possible CPU: the queue's total is their sum.
            Self::PerCpu(m) => m
                .get(&queue, 0)
                .map(|per_cpu| per_cpu.iter().map(|s| s.pkts).fold(0u64, u64::wrapping_add))
                .unwrap_or(0),
            Self::Plain(m) => m.get(&queue, 0).map(|s| s.pkts).unwrap_or(0),
        }
    }
}

/// aya's `XskMap::set` takes `impl AsRawFd`, but std does not implement that
/// trait for `&Fd`. This adapter just carries the raw fd number.
struct SocketFd(RawFd);

impl AsRawFd for SocketFd {
    fn as_raw_fd(&self) -> RawFd {
        self.0
    }
}

/// Last-seen counter values for one queue, to compute per-second rates.
#[derive(Default, Clone, Copy)]
struct Snapshot {
    xdp: u64,
    rx: u64,
    tx: u64,
}

fn print_stats(stats: &[Arc<WorkerStats>], qstats: &QStats, prev: &mut [Snapshot]) {
    let mut rows = Vec::with_capacity(stats.len());
    let mut total = Snapshot::default();

    for (q, s) in stats.iter().enumerate() {
        // aya: read this queue's counters out of the eBPF map.
        let xdp = qstats.pkts(q as u32);
        let now = Snapshot {
            xdp,
            rx: s.rx.load(Ordering::Relaxed),
            tx: s.tx.load(Ordering::Relaxed),
        };
        let d = Snapshot {
            xdp: now.xdp.wrapping_sub(prev[q].xdp),
            rx: now.rx.wrapping_sub(prev[q].rx),
            tx: now.tx.wrapping_sub(prev[q].tx),
        };
        prev[q] = now;
        total.xdp += d.xdp;
        total.rx += d.rx;
        total.tx += d.tx;
        rows.push(d);
    }

    if total.xdp == 0 && total.rx == 0 && total.tx == 0 {
        return; // stay quiet while idle
    }

    println!("\nqueue |  xdp seen/s |  AF_XDP rx/s |  tx/s");
    println!("------+-------------+--------------+----------");
    for (q, d) in rows.iter().enumerate() {
        println!("{q:5} | {:11} | {:12} | {:8}", d.xdp, d.rx, d.tx);
    }
    println!("total | {:11} | {:12} | {:8}", total.xdp, total.rx, total.tx);
}
