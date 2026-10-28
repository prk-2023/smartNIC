//! Packet rewriting: turn a received UDP "request" into its own "reply".
//!
//! Pure functions on byte slices, no AF_XDP types involved, so they can be unit
//! tested without root or a NIC (`cargo test`).

/// Ethernet header: dst MAC (6) + src MAC (6) + EtherType (2).
const ETH_HLEN: usize = 14;
/// IPv4 header without options.
const IPV4_MIN_HLEN: usize = 20;
/// UDP header: sport (2) + dport (2) + length (2) + checksum (2).
const UDP_HLEN: usize = 8;
const IPPROTO_UDP: u8 = 17;

/// Swap Ethernet MACs, IPv4 addresses and UDP ports of an IPv4/UDP frame,
/// IN PLACE. Returns `false` (leaving the frame untouched) if the frame is not
/// a well-formed IPv4/UDP packet.
///
/// Why no checksum update? The IPv4 header checksum and the UDP checksum are
/// one's-complement SUMS over 16-bit words. Addition is commutative, so
/// exchanging two summed fields (saddr <-> daddr, sport <-> dport) leaves both
/// sums, and therefore both checksum fields, unchanged. See the unit tests.
pub fn reflect_udp(pkt: &mut [u8]) -> bool {
    // ---- validate before touching anything ----
    if pkt.len() < ETH_HLEN + IPV4_MIN_HLEN + UDP_HLEN {
        return false;
    }
    if pkt[12..14] != [0x08, 0x00] {
        return false; // EtherType is not IPv4
    }
    let ip = ETH_HLEN;
    // Low nibble of the first IPv4 byte is the header length in 32-bit words.
    let ihl = usize::from(pkt[ip] & 0x0f) * 4;
    if ihl < IPV4_MIN_HLEN || pkt[ip + 9] != IPPROTO_UDP || pkt.len() < ETH_HLEN + ihl + UDP_HLEN {
        return false;
    }
    let udp = ip + ihl; // UDP header starts right after the (variable) IP header

    // ---- Ethernet: swap src/dst MAC (bytes 0..6 <-> 6..12) ----
    for i in 0..6 {
        pkt.swap(i, 6 + i);
    }
    // ---- IPv4: swap src/dst address (bytes 12..16 <-> 16..20 of the IP header) ----
    for i in 0..4 {
        pkt.swap(ip + 12 + i, ip + 16 + i);
    }
    // ---- UDP: swap src/dst port (bytes 0..2 <-> 2..4 of the UDP header) ----
    pkt.swap(udp, udp + 2);
    pkt.swap(udp + 1, udp + 3);
    true
}

#[cfg(test)]
mod tests {
    use super::*;

    const DST_MAC: [u8; 6] = [0xaa, 0xaa, 0xaa, 0xaa, 0xaa, 0x01];
    const SRC_MAC: [u8; 6] = [0xbb, 0xbb, 0xbb, 0xbb, 0xbb, 0x02];

    /// Standard Internet checksum over `data` (RFC 1071).
    fn inet_checksum(data: &[u8]) -> u16 {
        let mut sum: u32 = 0;
        for c in data.chunks(2) {
            let w = if c.len() == 2 { u16::from_be_bytes([c[0], c[1]]) } else { u16::from_be_bytes([c[0], 0]) };
            sum += u32::from(w);
        }
        while sum >> 16 != 0 {
            sum = (sum & 0xffff) + (sum >> 16);
        }
        !(sum as u16)
    }

    /// Build 10.10.0.2:5000 -> 10.10.0.1:7777 with `ip_opt` extra option words.
    fn build(ip_opt_words: usize, payload: &[u8]) -> Vec<u8> {
        let ihl_words = 5 + ip_opt_words;
        let ip_len = ihl_words * 4 + UDP_HLEN + payload.len();
        let mut p = Vec::new();
        p.extend_from_slice(&DST_MAC);
        p.extend_from_slice(&SRC_MAC);
        p.extend_from_slice(&[0x08, 0x00]);
        // IPv4 header
        p.push(0x40 | ihl_words as u8);
        p.push(0);
        p.extend_from_slice(&(ip_len as u16).to_be_bytes());
        p.extend_from_slice(&[0, 0, 0x40, 0, 64, IPPROTO_UDP, 0, 0]); // id, flags, ttl, proto, csum=0
        p.extend_from_slice(&[10, 10, 0, 2]); // saddr
        p.extend_from_slice(&[10, 10, 0, 1]); // daddr
        p.extend(std::iter::repeat(0u8).take(ip_opt_words * 4)); // options (NOPs)
        let csum = inet_checksum(&p[ETH_HLEN..ETH_HLEN + ihl_words * 4]);
        p[ETH_HLEN + 10..ETH_HLEN + 12].copy_from_slice(&csum.to_be_bytes());
        // UDP header
        p.extend_from_slice(&5000u16.to_be_bytes());
        p.extend_from_slice(&7777u16.to_be_bytes());
        p.extend_from_slice(&((UDP_HLEN + payload.len()) as u16).to_be_bytes());
        p.extend_from_slice(&[0x12, 0x34]); // arbitrary UDP checksum: must stay unchanged
        p.extend_from_slice(payload);
        p
    }

    #[test]
    fn swaps_macs_ips_and_ports() {
        let mut p = build(0, b"hello");
        assert!(reflect_udp(&mut p));
        assert_eq!(p[0..6], SRC_MAC); // dst is now the old src
        assert_eq!(p[6..12], DST_MAC);
        assert_eq!(p[ETH_HLEN + 12..ETH_HLEN + 16], [10, 10, 0, 1]); // saddr
        assert_eq!(p[ETH_HLEN + 16..ETH_HLEN + 20], [10, 10, 0, 2]); // daddr
        let udp = ETH_HLEN + 20;
        assert_eq!(u16::from_be_bytes([p[udp], p[udp + 1]]), 7777); // sport
        assert_eq!(u16::from_be_bytes([p[udp + 2], p[udp + 3]]), 5000); // dport
        assert_eq!(&p[udp + 8..], b"hello"); // payload untouched
    }

    #[test]
    fn ip_header_checksum_stays_valid() {
        // A header including its checksum sums to 0 (checksum of it is 0).
        let mut p = build(0, b"x");
        assert!(reflect_udp(&mut p));
        assert_eq!(inet_checksum(&p[ETH_HLEN..ETH_HLEN + 20]), 0);
    }

    #[test]
    fn handles_ip_options() {
        let mut p = build(2, b"opt"); // IHL = 7 words = 28 bytes
        assert!(reflect_udp(&mut p));
        let udp = ETH_HLEN + 28;
        assert_eq!(u16::from_be_bytes([p[udp], p[udp + 1]]), 7777);
        assert_eq!(inet_checksum(&p[ETH_HLEN..ETH_HLEN + 28]), 0);
    }

    #[test]
    fn reflecting_twice_is_identity() {
        let orig = build(0, b"round trip");
        let mut p = orig.clone();
        assert!(reflect_udp(&mut p));
        assert_ne!(p, orig);
        assert!(reflect_udp(&mut p));
        assert_eq!(p, orig);
    }

    #[test]
    fn rejects_non_udp_non_ip_and_truncated() {
        let mut tcp = build(0, b"x");
        tcp[ETH_HLEN + 9] = 6; // TCP
        let before = tcp.clone();
        assert!(!reflect_udp(&mut tcp));
        assert_eq!(tcp, before); // untouched on rejection

        let mut arp = build(0, b"x");
        arp[12] = 0x08;
        arp[13] = 0x06; // ARP
        assert!(!reflect_udp(&mut arp));

        let mut short = build(0, b"x");
        short.truncate(ETH_HLEN + 20 + 4); // cut inside the UDP header
        assert!(!reflect_udp(&mut short));
    }
}
