// xdp-mode-ebpf/src/main.rs
#![no_std]
#![no_main]

use aya_ebpf::{
    bindings::xdp_action,
    macros::{map, xdp},
    maps::PerCpuArray,
    programs::XdpContext,
};

/// Number of RX-queue slots. Queues >= MAX_QUEUES-1 share the last
/// ("overflow") slot. Userspace reads this back from the map's max_entries.
const MAX_QUEUES: u32 = 64;

/// Layout: index = RX queue, value = one u64 *per CPU* (kernel allocates a
/// private copy per possible CPU). XDP runs concurrently on every RX queue's
/// CPU, so no atomics or locks are required: each CPU only touches its copy.
#[map]
static PACKET_COUNT: PerCpuArray<u64> = PerCpuArray::with_max_entries(MAX_QUEUES, 0);

#[xdp]
pub fn xdp_mode(ctx: XdpContext) -> u32 {
    // rx_queue_index is a verifier-approved read-only field of xdp_md.
    // Note: in generic (SKB) mode it comes from the skb queue mapping and
    // is frequently 0, so per-queue numbers are only meaningful in DRV/HW mode.
    let q = unsafe { (*ctx.ctx).rx_queue_index };
    let idx = if q < MAX_QUEUES { q } else { MAX_QUEUES - 1 };

    if let Some(count) = PACKET_COUNT.get_ptr_mut(idx) {
        unsafe { *count += 1 };
    }
    xdp_action::XDP_PASS
}

#[cfg(not(test))]
#[panic_handler]
fn panic(_info: &core::panic::PanicInfo) -> ! {
    loop {}
}

#[unsafe(link_section = "license")]
#[unsafe(no_mangle)]
static LICENSE: [u8; 13] = *b"Dual MIT/GPL\0";
