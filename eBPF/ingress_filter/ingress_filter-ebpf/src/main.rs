#![no_std]
#![no_main]

//se aya_log_ebpf::info;
use core::mem;

use aya_ebpf::{bindings::xdp_action, macros::xdp, programs::XdpContext};
use network_types::{
    eth::{EthHdr, EtherType},
    ip::{IpProto, Ipv4Hdr},
    tcp::TcpHdr,
    udp::UdpHdr,
};

#[xdp]
pub fn ingress_filter(ctx: XdpContext) -> u32 {
    match try_ingress_filter(ctx) {
        Ok(ret) => ret,
        Err(_) => xdp_action::XDP_PASS,
    }
}

//fn try_ingress_filter(ctx: XdpContext) -> Result<u32, u32> {
fn try_ingress_filter(ctx: XdpContext) -> Result<u32, ()> {
    // 1. Parse and bounds-check the Ethernet header
    let eth: *const EthHdr = ptr_at(&ctx, 0)?;
    if unsafe { (*eth).ether_type() } != Ok(EtherType::Ipv4) {
        return Ok(xdp_action::XDP_PASS);
    }

    // 2. Parse and bounds-check the IPv4 header
    let ip: *const Ipv4Hdr = ptr_at(&ctx, mem::size_of::<EthHdr>())?;

    // 3. Match the IP protocol safely using a match statement
    let proto = unsafe { (*ip).proto() };
    match proto {
        Ok(IpProto::Udp) => {
            // Ensure UDP header exists
            let _udp: *const UdpHdr =
                ptr_at(&ctx, mem::size_of::<EthHdr>() + mem::size_of::<Ipv4Hdr>())?;

            // Drop UDP packets exceeding 512 bytes
            let tot_len = u16::from_be_bytes(unsafe { (*ip).tot_len });
            if tot_len > 512 {
                return Ok(xdp_action::XDP_DROP);
            }
        }
        Ok(IpProto::Tcp) => {
            let ihl = unsafe { (*ip).ihl() } as usize; // this returns 20 bytes  
            //let ip_header_len = ihl * 4;               // Evaluates to 80 bytes ! ( 20*4 ) 
            //Since network-types `ihl()` returns the length in bytes directly:
            // get correct IP header length in bytes directly 
            let ip_header_len = unsafe { (*ip).ihl() } as usize;


            let tcp: *const TcpHdr = ptr_at(&ctx, mem::size_of::<EthHdr>() + ip_header_len)?;

            // Drop malformed SYN packets with zero window size
            let is_syn = unsafe { (*tcp).syn() } != 0;
            let window = u16::from_be_bytes(unsafe { (*tcp).window });

            if is_syn && window == 0 {
                return Ok(xdp_action::XDP_DROP);
            }
        }
        _ => {}
    }

    Ok(xdp_action::XDP_PASS)
}

#[cfg(not(test))]
#[panic_handler]
fn panic(_info: &core::panic::PanicInfo) -> ! {
    loop {}
}


// GPL License declaration required by the Linux kernel verifier
#[unsafe(link_section = "license")]
#[used]
pub static _LICENSE: [u8; 4] = *b"GPL\0";

/// Helper function to safely read and bound-check headers against packet data bounds.
#[inline(always)]
fn ptr_at<T>(ctx: &XdpContext, offset: usize) -> Result<*const T, ()> {
    let start = ctx.data();
    let end = ctx.data_end();
    let len = mem::size_of::<T>();

    if start + offset + len > end {
        return Err(());
    }

    Ok((start + offset) as *const T)
}
