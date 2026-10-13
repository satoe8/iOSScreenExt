// Discovery.swift
// Finds the Windows host on the local network WITHOUT typing an IP.
//
// iOS cannot send or receive UDP broadcast/multicast unless the app has Apple's restricted
// "com.apple.developer.networking.multicast" entitlement (not obtainable for a sideloaded free-account
// app), but UDP *unicast* needs nothing beyond the Local Network permission. So we send a tiny unicast
// probe to every address of our own subnet (capped at a /22) and the host answers the probe.
//
//   probe (to host UDP 5001): u32 "IDDQ" 0x51444449, u8 version 1, 3 reserved bytes   (little-endian)
//   reply (from host)       : u32 "IDDR" 0x52444449, u8 version, u8 mode (0 TCP / 1 UDP),
//                             u16 streamPort, u8 nameLen, name (UTF-8)

import Foundation
import Darwin

struct DiscoveredHost: Equatable {
    let address: String
    let port: UInt16
    let isUDP: Bool
    let name: String
}

enum HostDiscovery {
    static let probePort: UInt16 = 5001

    /// Blocking: call from a background thread. Returns every host that answered within `timeout`.
    static func discover(timeout: TimeInterval = 1.5) -> [DiscoveredHost] {
        let targets = subnetTargets()
        guard !targets.isEmpty else { return [] }

        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { return [] }
        defer { close(fd) }

        var bufSize: Int32 = 1 << 20
        setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &bufSize, socklen_t(MemoryLayout<Int32>.size))

        // "IDDQ" little-endian, version 1
        let probe: [UInt8] = [0x49, 0x44, 0x44, 0x51, 1, 0, 0, 0]

        for (i, ip) in targets.enumerated() {
            var addr = sockaddr_in()
            addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = probePort.bigEndian
            addr.sin_addr = in_addr(s_addr: ip.bigEndian)
            let sent = withUnsafePointer(to: &addr) { ptr -> Int in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(fd, probe, probe.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            if sent < 0 && errno == ENOBUFS { usleep(2000) }
            if i % 64 == 63 { usleep(1000) }          // don't flood the Wi-Fi in one burst
        }

        var found: [DiscoveredHost] = []
        var buf = [UInt8](repeating: 0, count: 128)
        let deadline = Date().addingTimeInterval(timeout)

        while true {
            let remainingMs = Int32(max(0, deadline.timeIntervalSinceNow * 1000))
            if remainingMs == 0 { break }
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            if poll(&pfd, 1, remainingMs) <= 0 { break }

            var from = sockaddr_in()
            var fromLen = socklen_t(MemoryLayout<sockaddr_in>.size)
            let n = withUnsafeMutablePointer(to: &from) { ptr -> Int in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    recvfrom(fd, &buf, buf.count, 0, $0, &fromLen)
                }
            }
            guard n >= 9, buf[0] == 0x49, buf[1] == 0x44, buf[2] == 0x44, buf[3] == 0x52, buf[4] == 1 else { continue }

            let port = UInt16(buf[6]) | (UInt16(buf[7]) << 8)
            let nameLen = min(Int(buf[8]), max(0, n - 9))
            let name = String(decoding: buf[9..<(9 + nameLen)], as: UTF8.self)
            var ipBuf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            inet_ntop(AF_INET, &from.sin_addr, &ipBuf, socklen_t(ipBuf.count))
            let host = DiscoveredHost(address: String(cString: ipBuf), port: port, isUDP: buf[5] == 1, name: name)
            if !found.contains(host) { found.append(host) }
        }
        return found
    }

    /// Every other address on our Wi-Fi/Ethernet subnet(s), as host-order integers.
    private static func subnetTargets() -> [UInt32] {
        var result: [UInt32] = []
        var ifap: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifap) == 0, let first = ifap else { return [] }
        defer { freeifaddrs(ifap) }

        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let cur = cursor {
            let ifa = cur.pointee
            cursor = ifa.ifa_next

            guard let sa = ifa.ifa_addr, sa.pointee.sa_family == sa_family_t(AF_INET),
                  let nm = ifa.ifa_netmask else { continue }
            let flags = ifa.ifa_flags
            guard flags & UInt32(IFF_UP) != 0, flags & UInt32(IFF_RUNNING) != 0,
                  flags & UInt32(IFF_LOOPBACK) == 0 else { continue }
            guard String(cString: ifa.ifa_name).hasPrefix("en") else { continue }   // Wi-Fi / Ethernet only

            let ip = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
            var mask = nm.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
            if mask < 0xFFFF_FC00 { mask = 0xFFFF_FC00 }          // cap the sweep at a /22 (1022 hosts)
            let network = ip & mask
            let hostMax = ~mask
            guard hostMax >= 2 else { continue }

            var h: UInt32 = 1
            while h < hostMax {
                let candidate = network | h
                if candidate != ip, !result.contains(candidate) { result.append(candidate) }
                h += 1
            }
        }
        return result
    }
}
