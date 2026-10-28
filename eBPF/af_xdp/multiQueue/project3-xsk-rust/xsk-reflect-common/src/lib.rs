//! Definitions shared by the eBPF (kernel) crate and the user-space crate.
//!
//! Anything both sides must agree on lives here, so they cannot drift apart.
//! The crate is `no_std` so it can be compiled for the `bpfel-unknown-none`
//! target as well as for the host.
#![no_std]

/// Only UDP packets with this destination port are redirected to AF_XDP.
/// Everything else (ARP, ICMP, ssh, ...) continues to the kernel stack.
pub const ECHO_UDP_PORT: u16 = 7777;

/// Size of the XSKMAP and of the per-queue statistics array: the maximum
/// number of RX queues this program can serve.
pub const MAX_QUEUES: u32 = 64;

/// Per-queue counters written by the XDP program (kernel side) and read by
/// user space through the `QSTATS` array map.
///
/// `#[repr(C)]` fixes the layout (two u64) so both sides, and the C version of
/// the program from Project 2, see identical bytes.
#[repr(C)]
#[derive(Clone, Copy, Default)]
pub struct QStat {
    /// Packets matched (and redirected) by XDP on this queue.
    pub pkts: u64,
    /// Bytes of those packets.
    pub bytes: u64,
}

/// `aya::Pod` marks a type as "plain old data": safe to copy to/from the raw
/// bytes of a BPF map value. Needed by `aya::maps::Array<_, QStat>`.
///
/// # Safety
/// `QStat` is `repr(C)`, has no padding and no pointers.
#[cfg(feature = "user")]
unsafe impl aya::Pod for QStat {}
