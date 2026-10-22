// xdp-tx-ebpf/src/main.rs
#![no_std]
#![no_main]

use aya_ebpf::{
    bindings::xdp_action,
    macros::{map, xdp},
    maps::PerCpuArray,
    programs::XdpContext,
};
use network_types::eth::EthHdr; // Import the idiomatic Rust Ethernet header

const MAX_QUEUES: u32 = 64;

#[map]
static PACKET_COUNT: PerCpuArray<u64> = PerCpuArray::with_max_entries(MAX_QUEUES, 0);

#[xdp]
pub fn xdp_tx(ctx: XdpContext) -> u32 {
    let q = unsafe { (*ctx.ctx).rx_queue_index };
    let idx = if q < MAX_QUEUES { q } else { MAX_QUEUES - 1 };

    if let Some(count) = PACKET_COUNT.get_ptr_mut(idx) {
        unsafe { *count += 1 };
    }

    // --- XDP_TX MAC Swap Logic using network-types ---
    let data = ctx.data();
    let data_end = ctx.data_end();

    // Verifier bound check: Ensure the packet accommodates an Ethernet header
    if data + EthHdr::LEN > data_end {
        return xdp_action::XDP_ABORTED;
    }

    // Get a mutable reference to the Ethernet header (requires unsafe for pointer cast)
    let eth = unsafe { &mut *(data as *mut EthHdr) };

    // Swap the MAC addresses cleanly using Rust's built-in core::mem::swap
    core::mem::swap(&mut eth.src_addr, &mut eth.dst_addr);

    // Transmit the packet back out of the same interface
    xdp_action::XDP_TX
}

#[cfg(not(test))]
#[panic_handler]
fn panic(_info: &core::panic::PanicInfo) -> ! {
    loop {}
}

#[unsafe(link_section = "license")]
#[unsafe(no_mangle)]
static LICENSE: [u8; 13] = *b"Dual MIT/GPL\0";


// ---------------------------------------
// #![no_std]
// #![no_main]
//
// use aya_ebpf::{bindings::xdp_action, macros::xdp, programs::XdpContext};
// use aya_log_ebpf::info;
//
// #[xdp]
// pub fn xdp_tx(ctx: XdpContext) -> u32 {
//     match try_xdp_tx(ctx) {
//         Ok(ret) => ret,
//         Err(_) => xdp_action::XDP_ABORTED,
//     }
// }
//
// fn try_xdp_tx(ctx: XdpContext) -> Result<u32, u32> {
//     info!(&ctx, "received a packet");
//     Ok(xdp_action::XDP_PASS)
// }
//
// #[cfg(not(test))]
// #[panic_handler]
// fn panic(_info: &core::panic::PanicInfo) -> ! {
//     loop {}
// }
//
// #[unsafe(link_section = "license")]
// #[unsafe(no_mangle)]
// static LICENSE: [u8; 13] = *b"Dual MIT/GPL\0";
//
//
