//! Small NIC / socket queries done with raw libc calls.
//!
//! * `channel_count`   - how many RX/TX queues the NIC currently has (ethtool ioctl)
//! * `is_zero_copy`    - did the kernel bind our AF_XDP socket in zero-copy mode?

use std::{mem, os::unix::io::RawFd};

/// `struct ethtool_channels` from <linux/ethtool.h>, used with ETHTOOL_GCHANNELS.
/// (`ethtool -l IFACE` shows the same data.)
#[repr(C)]
#[derive(Default)]
struct EthtoolChannels {
    cmd: u32,
    max_rx: u32,
    max_tx: u32,
    max_other: u32,
    max_combined: u32,
    rx_count: u32,
    tx_count: u32,
    other_count: u32,
    combined_count: u32,
}

const SIOCETHTOOL: u64 = 0x8946;
const ETHTOOL_GCHANNELS: u32 = 0x0000_003c;

/// Number of queues the NIC is currently configured with (mlx5 reports them as
/// "combined" channels). `None` if the query is not supported.
pub fn channel_count(iface: &str) -> Option<u32> {
    let mut ch = EthtoolChannels { cmd: ETHTOOL_GCHANNELS, ..Default::default() };

    // SAFETY: plain libc calls on locally owned, correctly sized structures.
    unsafe {
        // Any socket works as the target of a SIOCETHTOOL ioctl.
        let fd = libc::socket(libc::AF_INET, libc::SOCK_DGRAM, 0);
        if fd < 0 {
            return None;
        }

        let mut ifr: libc::ifreq = mem::zeroed();
        for (dst, src) in ifr.ifr_name.iter_mut().zip(iface.bytes().take(libc::IFNAMSIZ - 1)) {
            *dst = src as libc::c_char;
        }
        // ifr_data points at the ethtool command structure.
        ifr.ifr_ifru.ifru_data = &mut ch as *mut EthtoolChannels as *mut libc::c_char;

        let rc = libc::ioctl(fd, SIOCETHTOOL as _, &mut ifr);
        libc::close(fd);
        if rc != 0 {
            return None;
        }
    }
    Some(if ch.combined_count != 0 { ch.combined_count } else { ch.rx_count })
}

/// `getsockopt(SOL_XDP, XDP_OPTIONS)` tells whether the socket is zero-copy.
pub fn is_zero_copy(fd: RawFd) -> Option<bool> {
    const XDP_OPTIONS: libc::c_int = 8; // from <linux/if_xdp.h>
    const XDP_OPTIONS_ZEROCOPY: u32 = 1;

    #[repr(C)]
    #[derive(Default)]
    struct XdpOptions {
        flags: u32,
    }

    let mut opts = XdpOptions::default();
    let mut len = mem::size_of::<XdpOptions>() as libc::socklen_t;
    // SAFETY: `opts`/`len` are valid for writes of the sizes passed.
    let rc = unsafe {
        libc::getsockopt(
            fd,
            libc::SOL_XDP,
            XDP_OPTIONS,
            &mut opts as *mut XdpOptions as *mut libc::c_void,
            &mut len,
        )
    };
    (rc == 0).then_some(opts.flags & XDP_OPTIONS_ZEROCOPY != 0)
}
