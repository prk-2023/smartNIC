//! xsk-reflect-ebpf - the XDP half of Project 3, written in Rust (aya-ebpf).
//!
//! This is the Rust twin of `xdp_kern.c` from Project 2. It runs inside the NIC
//! driver (mlx5) for every received frame, before an skb is allocated, on the
//! CPU that services that RX queue. With N queues, N copies run in parallel.
//!
//!   * IPv4/UDP to ECHO_UDP_PORT -> count it (per-CPU counters), then redirect it to the AF_XDP
//!     socket registered for the SAME queue index in XSKS_MAP.
//!   * anything else             -> XDP_PASS (normal kernel stack).
//!
//! Data path:  NIC RX queue N --> this program --> XSKS_MAP[N] --> XSK N's RX ring
#![no_std]
#![no_main]

use aya_ebpf::{
    bindings::xdp_action,
    macros::{map, xdp},
    maps::{PerCpuArray, XskMap},
    programs::XdpContext,
};
use xsk_reflect_common::{QStat, ECHO_UDP_PORT, MAX_QUEUES};

/// XSKMAP: "RX queue index -> AF_XDP socket". User space inserts one socket
/// per queue (aya: `XskMap::set(queue, fd, 0)`), keyed by queue id.
#[map]
static XSKS_MAP: XskMap = XskMap::with_max_entries(MAX_QUEUES, 0);

/// Per-queue {pkts, bytes} counters, as a PER-CPU array: every CPU gets its
/// own private copy of each slot. User space reads one value per CPU with
/// `aya::maps::PerCpuArray::get()` and sums them.
///
/// Why per-CPU instead of one shared slot? The eBPF target has no atomic
/// read-modify-write in Rust (only atomic load/store), so a shared counter
/// could not be incremented safely from several CPUs. With a per-CPU map each
/// CPU only ever touches its own copy (XDP runs to completion in the NAPI
/// softirq of the CPU that owns the queue), so plain `+=` is race-free, and it
/// is also faster because no cache line is shared between CPUs.
#[map]
static QSTATS: PerCpuArray<QStat> = PerCpuArray::with_max_entries(MAX_QUEUES, 0);

// Header geometry. We read raw bytes instead of casting to header structs:
// a [u8; N] has alignment 1, so it is always valid to read no matter where
// the driver placed the frame, and the byte offsets are explicit.
const ETH_HLEN: usize = 14; // dst MAC (6) + src MAC (6) + EtherType (2)
const ETH_P_IP: u16 = 0x0800; // IPv4
const IPPROTO_UDP: u8 = 17;

/// Bounds-checked pointer to a `T` at `offset` bytes into the frame.
///
/// The eBPF verifier REJECTS any packet access it cannot prove lies inside
/// [data, data_end). This helper performs exactly that proof, so every read
/// below goes through it.
#[inline(always)]
fn ptr_at<T>(ctx: &XdpContext, offset: usize) -> Result<*const T, ()> {
    let start = ctx.data();
    let end = ctx.data_end();
    let len = core::mem::size_of::<T>();

    if start + offset + len > end {
        return Err(());
    }
    Ok((start + offset) as *const T)
}

#[xdp]
pub fn xsk_redirect(ctx: XdpContext) -> u32 {
    match try_xsk_redirect(&ctx) {
        Ok(action) => action,
        // Anything we could not parse safely is handed to the kernel stack.
        Err(()) => xdp_action::XDP_PASS,
    }
}

fn try_xsk_redirect(ctx: &XdpContext) -> Result<u32, ()> {
    // ---- Ethernet: only IPv4 (ARP etc. go to the kernel) ----
    // Compare as an integer, not as a byte array: array equality can compile
    // to a memcmp/bcmp CALL, which eBPF cannot link.
    let ethertype = u16::from_be_bytes(unsafe { *ptr_at::<[u8; 2]>(ctx, 12)? });
    if ethertype != ETH_P_IP {
        return Ok(xdp_action::XDP_PASS);
    }

    // ---- IPv4: first byte = version (high nibble) | IHL (low nibble) ----
    let ver_ihl = unsafe { *ptr_at::<u8>(ctx, ETH_HLEN)? };
    let proto = unsafe { *ptr_at::<u8>(ctx, ETH_HLEN + 9)? };
    if proto != IPPROTO_UDP {
        return Ok(xdp_action::XDP_PASS);
    }

    // IPv4 header length is variable (options!): IHL counts 32-bit words.
    let ihl = ((ver_ihl & 0x0f) as usize) * 4;
    if ihl < 20 {
        return Ok(xdp_action::XDP_PASS);
    }

    // ---- UDP: destination port is bytes 2..4 of the UDP header ----
    // `ptr_at` proves bytes [udp+2, udp+4) lie inside the frame, which is all
    // we read. (The offset depends on the variable IPv4 header length; the
    // verifier accepts it because `ihl` is provably within 20..=60.)
    let udp = ETH_HLEN + ihl;
    let dport = u16::from_be_bytes(unsafe { *ptr_at::<[u8; 2]>(ctx, udp + 2)? });
    if dport != ECHO_UDP_PORT {
        return Ok(xdp_action::XDP_PASS);
    }

    // ---- Per-queue accounting ----
    // SAFETY: rx_queue_index is a plain field of the xdp_md context.
    let queue = unsafe { (*ctx.ctx).rx_queue_index };
    if let Some(stat) = QSTATS.get_ptr_mut(queue) {
        let frame_len = (ctx.data_end() - ctx.data()) as u64;
        // SAFETY: `stat` points at THIS CPU's copy of the slot (per-CPU map),
        // so nobody else can modify it while we do. `wrapping_add` avoids any
        // overflow-panic path, which the verifier would not accept.
        unsafe {
            (*stat).pkts = (*stat).pkts.wrapping_add(1);
            (*stat).bytes = (*stat).bytes.wrapping_add(frame_len);
        }
    }

    // ---- Steer to the socket bound to THIS queue ----
    // The second argument is the fallback action used when no socket is
    // registered for the queue (e.g. the NIC has more queues than we serve):
    // XDP_PASS hands the packet to the kernel instead of dropping it.
    Ok(XSKS_MAP
        .redirect(queue, xdp_action::XDP_PASS as u64)
        .unwrap_or(xdp_action::XDP_PASS))
}

/// no_std programs must define what happens on panic. The verifier would
/// reject any real panic path, so this just spins; it is never reached.
#[panic_handler]
fn panic(_info: &core::panic::PanicInfo) -> ! {
    loop {}
}
