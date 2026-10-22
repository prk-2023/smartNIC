// xdp-tx/src/main.rs
use std::{
    borrow::Borrow,
    time::{Duration, Instant},
};

use aya::{
    maps::{MapData, PerCpuArray},
    programs::{xdp::XdpMode, Xdp},
    Ebpf,
};
use clap::{Parser, ValueEnum};
use log::{debug, info, warn};
use tokio::signal;

/// Which XDP attach mode(s) to try.
#[derive(Debug, Clone, Copy, ValueEnum)]
enum ModeOpt {
    /// Probe HW offload, then native driver, then generic (SKB)
    Auto,
    /// Hardware offload only
    Hw,
    /// Native driver mode only
    Drv,
    /// Generic (SKB) mode only
    Skb, 
}

impl ModeOpt {
    fn candidates(self) -> Vec<XdpMode> {
        match self {
            ModeOpt::Auto => vec![XdpMode::Hardware, XdpMode::Driver, XdpMode::Skb],
            ModeOpt::Hw => vec![XdpMode::Hardware],
            ModeOpt::Drv => vec![XdpMode::Driver],
            ModeOpt::Skb => vec![XdpMode::Skb],
        }
    }
}

/// Probe which XDP modes a NIC driver supports and (optionally) watch
/// packet rates broken down per CPU and per RX queue.
#[derive(Debug, Parser)]
#[command(version, about, long_about = None)]
struct Opt {
    /// Network interface to attach to
    #[arg(short, long, default_value = "eth0")]
    iface: String,

    /// XDP attach mode to try
    #[arg(short, long, value_enum, default_value_t = ModeOpt::Auto)]
    mode: ModeOpt,

    /// Watch mode: stay attached and keep printing packet-count updates
    #[arg(short, long)]
    watch: bool,

    /// Sampling interval in seconds (watch mode)
    #[arg(short = 'n', long, default_value_t = 1,
          value_parser = clap::value_parser!(u64).range(1..), requires = "watch")]
    interval: u64,

    /// Stop automatically after this many seconds and print a summary
    #[arg(short, long, value_parser = clap::value_parser!(u64).range(1..), requires = "watch")]
    duration: Option<u64>,

    /// Show a per-CPU breakdown (which cores are actually servicing XDP)
    #[arg(short = 'c', long, requires = "watch")]
    per_cpu: bool,

    /// Show a per-RX-queue breakdown (needs DRV/HW mode to be meaningful)
    #[arg(short = 'q', long, requires = "watch")]
    per_queue: bool,
}

/// Counters summed along both axes of the [queue][cpu] matrix.
struct Snapshot {
    per_cpu: Vec<u64>,
    per_queue: Vec<u64>,
}

impl Snapshot {
    fn total(&self) -> u64 {
        self.per_cpu.iter().sum()
    }
}

/// Read the whole PerCpuArray: each queue slot returns one value per possible CPU.
fn snapshot<T: Borrow<MapData>>(map: &PerCpuArray<T, u64>) -> anyhow::Result<Snapshot> {
    let nqueues = map.len();
    let mut per_cpu: Vec<u64> = Vec::new();
    let mut per_queue = vec![0u64; nqueues as usize];

    for q in 0..nqueues {
        let values = map.get(&q, 0)?;
        if per_cpu.is_empty() {
            per_cpu = vec![0u64; values.len()];
        }
        for (cpu, v) in values.iter().enumerate() {
            per_cpu[cpu] = per_cpu[cpu].wrapping_add(*v);
            per_queue[q as usize] = per_queue[q as usize].wrapping_add(*v);
        }
    }
    Ok(Snapshot { per_cpu, per_queue })
}

/// "cpu3=1200.0 cpu5=800.0" for entries with any traffic; `label` is "cpu" or "q".
fn fmt_rates(label: &str, cur: &[u64], prev: &[u64], secs: f64) -> String {
    let parts: Vec<String> = cur
        .iter()
        .zip(prev.iter())
        .enumerate()
        .filter(|(_, (c, p))| **c > **p)
        .map(|(i, (c, p))| format!("{label}{i}={:.1}", c.saturating_sub(*p) as f64 / secs))
        .collect();
    if parts.is_empty() {
        "-".to_string()
    } else {
        parts.join(" ")
    }
}

fn active(v: &[u64]) -> Vec<usize> {
    v.iter().enumerate().filter(|(_, c)| **c > 0).map(|(i, _)| i).collect()
}

fn print_summary(s: &Snapshot, elapsed: Duration) {
    let secs = elapsed.as_secs_f64().max(f64::EPSILON);
    let total = s.total();
    let cpus = active(&s.per_cpu);
    let queues = active(&s.per_queue);

    println!("\n------------- Summary -------------");
    println!("Total packets   : {total}  ({:.2} p/s avg over {:.1}s)", total as f64 / secs, secs);
    println!("Active CPUs     : {:?}  (of {} possible)", cpus, s.per_cpu.len());
    println!("Active RX queues: {:?}", queues);

    if total > 0 && cpus.len() == 1 && s.per_cpu.len() > 1 {
        println!(
            "Note: all traffic landed on one CPU. Typical for a single flow \
             (RSS hashes per-flow) or when RSS/queues are not configured - \
             check `ethtool -l <if>` and `ethtool -x <if>`."
        );
    }
    if total > 0 && queues == [0] && cpus.len() > 1 {
        println!("Note: only queue 0 seen but several CPUs active - likely generic (SKB) mode.");
    }
}

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    let opt = Opt::parse();

    // Default to `info` so the probing messages are visible without RUST_LOG.
    env_logger::Builder::from_env(env_logger::Env::default().default_filter_or("info")).init();
    bump_memlock_rlimit();

    let mut ebpf = Ebpf::load(aya::include_bytes_aligned!(concat!(
        env!("OUT_DIR"),
        "/xdp-tx"
    )))?;

    let program: &mut Xdp = ebpf.program_mut("xdp_tx").unwrap().try_into()?;
    program.load()?;

    let mut attached_mode = None;
    for mode in opt.mode.candidates() {
        info!("Probing XDP mode: {:?}", mode);
        match program.attach(&opt.iface, mode) {
            Ok(_link_id) => {
                info!("Successfully attached in {:?} mode", mode);
                attached_mode = Some(mode);
                break;
            }
            Err(e) => warn!("Failed to attach in {:?} mode: {}", mode, e),
        }
    }

    let Some(active_mode) = attached_mode else {
        anyhow::bail!(
            "Failed to attach XDP program to {} in any requested mode ({:?}).",
            opt.iface,
            opt.mode
        );
    };

    println!("\n==========================================");
    println!("Interface      : {}", opt.iface);
    println!("Strongest Mode : {:?}", active_mode);
    println!("==========================================\n");

    if !opt.watch {
        println!("Probe complete. Exiting (program detaches automatically).");
        return Ok(());
    }

    let packet_count: PerCpuArray<_, u64> = PerCpuArray::try_from(ebpf.map("PACKET_COUNT").unwrap())?;
    println!("Watch mode enabled (Ctrl+C to exit)...\n");

    let start = Instant::now();
    let mut prev = snapshot(&packet_count)?;
    let mut prev_time = start;

    let mut ticker = tokio::time::interval(Duration::from_secs(opt.interval));
    ticker.tick().await; // first tick fires immediately

    loop {
        tokio::select! {
            _ = ticker.tick() => {
                let now = Instant::now();
                let cur = snapshot(&packet_count)?;
                let secs = now.duration_since(prev_time).as_secs_f64();
                let pps = cur.total().saturating_sub(prev.total()) as f64 / secs;

                println!(
                    "[{}] Total Packets: {:<12} | Live Rate: {:>10.2} p/s",
                    opt.iface, cur.total(), pps
                );
                if opt.per_cpu {
                    println!("    per-cpu  : {}", fmt_rates("cpu", &cur.per_cpu, &prev.per_cpu, secs));
                }
                if opt.per_queue {
                    println!("    per-queue: {}", fmt_rates("q", &cur.per_queue, &prev.per_queue, secs));
                }

                prev = cur;
                prev_time = now;

                if opt.duration.is_some_and(|d| start.elapsed() >= Duration::from_secs(d)) {
                    break;
                }
            }
            _ = signal::ctrl_c() => {
                println!("\nCtrl+C received. Detaching XDP program and exiting...");
                break;
            }
        }
    }

    print_summary(&prev, start.elapsed());
    Ok(())
}

fn bump_memlock_rlimit() {
    let rlim = libc::rlimit {
        rlim_cur: libc::RLIM_INFINITY,
        rlim_max: libc::RLIM_INFINITY,
    };
    let ret = unsafe { libc::setrlimit(libc::RLIMIT_MEMLOCK, &rlim) };
    if ret != 0 {
        debug!("remove limit on locked memory failed, ret is: {ret}");
    }
}
