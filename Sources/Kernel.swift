import Darwin
import Foundation

// MARK: - Per-interface traffic counters

struct IfCounters {
    var inBytes: UInt64
    var outBytes: UInt64
    var flags: Int32
    var type: UInt8
    var baudrate: UInt64

    var isUp: Bool { flags & IFF_UP != 0 }
    var isRunning: Bool { flags & IFF_RUNNING != 0 }
    var isLoopback: Bool { flags & IFF_LOOPBACK != 0 }
    var isPointToPoint: Bool { flags & IFF_POINTOPOINT != 0 }
}

enum Kernel {
    /// Byte counters for every interface in one sysctl call — what `netstat -ib`
    /// reports, without spawning a process.
    static func counters() -> [String: IfCounters] {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var len = 0
        guard sysctl(&mib, 6, nil, &len, nil, 0) == 0, len > 0 else { return [:] }
        var buf = [UInt8](repeating: 0, count: len)
        guard sysctl(&mib, 6, &buf, &len, nil, 0) == 0 else { return [:] }

        var out: [String: IfCounters] = [:]
        buf.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var off = 0
            while off + MemoryLayout<if_msghdr>.size <= len {
                let p = base.advanced(by: off)
                let msglen = Int(p.assumingMemoryBound(to: UInt16.self).pointee)
                guard msglen > 0 else { break }
                let type = Int32(p.advanced(by: 3).assumingMemoryBound(to: UInt8.self).pointee)
                if type == RTM_IFINFO2, off + MemoryLayout<if_msghdr2>.size + MemoryLayout<sockaddr_dl>.size <= len {
                    let m = p.assumingMemoryBound(to: if_msghdr2.self).pointee
                    let dl = p.advanced(by: MemoryLayout<if_msghdr2>.size).assumingMemoryBound(to: sockaddr_dl.self)
                    if let name = Self.linkName(dl) {
                        out[name] = IfCounters(inBytes: m.ifm_data.ifi_ibytes,
                                               outBytes: m.ifm_data.ifi_obytes,
                                               flags: m.ifm_flags,
                                               type: m.ifm_data.ifi_type,
                                               baudrate: m.ifm_data.ifi_baudrate)
                    }
                }
                off += msglen
            }
        }
        return out
    }

    private static func linkName(_ dl: UnsafePointer<sockaddr_dl>) -> String? {
        let n = Int(dl.pointee.sdl_nlen)
        guard n > 0, n <= 24 else { return nil }
        return withUnsafePointer(to: dl.pointee.sdl_data) { p -> String? in
            let chars = UnsafeRawPointer(p).assumingMemoryBound(to: UInt8.self)
            return String(bytes: UnsafeBufferPointer(start: chars, count: n), encoding: .utf8)
        }
    }

    /// The kernel reports ibytes truncated to 32 bits, so deltas are taken modulo
    /// 2^32; an implausibly large rollback is treated as an interface reset.
    static func delta(_ new: UInt64, _ old: UInt64) -> UInt64 {
        if new >= old { return new - old }
        let wrapped = (new &+ (1 << 32)) &- old
        return wrapped < (1 << 32) ? wrapped : 0
    }
}

// MARK: - Default routes

struct DefaultRoute {
    var interface: String
    var gateway: String?
}

extension Kernel {
    /// Every default route in the order the kernel returns them. With a VPN up
    /// there are several: the tunnel first, then the physical link.
    static func defaultRoutes() -> [DefaultRoute] {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, AF_INET, NET_RT_DUMP, 0]
        var len = 0
        guard sysctl(&mib, 6, nil, &len, nil, 0) == 0, len > 0 else { return [] }
        var buf = [UInt8](repeating: 0, count: len)
        guard sysctl(&mib, 6, &buf, &len, nil, 0) == 0 else { return [] }

        var routes: [DefaultRoute] = []
        buf.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var off = 0
            while off + MemoryLayout<rt_msghdr>.size <= len {
                let p = base.advanced(by: off)
                let hdr = p.assumingMemoryBound(to: rt_msghdr.self).pointee
                let msglen = Int(hdr.rtm_msglen)
                guard msglen > 0 else { break }
                defer { off += msglen }

                guard hdr.rtm_flags & RTF_UP != 0 else { continue }
                var cursor = p.advanced(by: MemoryLayout<rt_msghdr>.size)
                var dst: sockaddr_in?
                var gw: UnsafeRawPointer?
                var isDefault = false

                for slot in 0..<RTAX_MAX {
                    guard hdr.rtm_addrs & (1 << slot) != 0 else { continue }
                    guard cursor < p.advanced(by: msglen) else { break }
                    let sa = cursor.assumingMemoryBound(to: sockaddr.self).pointee
                    if slot == RTAX_DST, sa.sa_family == UInt8(AF_INET) {
                        dst = cursor.assumingMemoryBound(to: sockaddr_in.self).pointee
                    } else if slot == RTAX_GATEWAY {
                        gw = cursor
                    } else if slot == RTAX_NETMASK, sa.sa_len == 0 || Self.maskIsZero(cursor) {
                        isDefault = true
                    }
                    cursor = cursor.advanced(by: Self.saSize(sa.sa_len))
                }

                guard let d = dst, d.sin_addr.s_addr == 0, isDefault || hdr.rtm_flags & RTF_GATEWAY != 0 else { continue }
                var nameBuf = [CChar](repeating: 0, count: Int(IFNAMSIZ) + 1)
                guard if_indextoname(UInt32(hdr.rtm_index), &nameBuf) != nil else { continue }
                let name = String(cString: nameBuf)
                var gateway: String?
                if let g = gw {
                    let sa = g.assumingMemoryBound(to: sockaddr.self).pointee
                    if sa.sa_family == UInt8(AF_INET) {
                        var addr = g.assumingMemoryBound(to: sockaddr_in.self).pointee.sin_addr
                        var s = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                        if inet_ntop(AF_INET, &addr, &s, socklen_t(INET_ADDRSTRLEN)) != nil {
                            gateway = String(cString: s)
                        }
                    }
                }
                if !routes.contains(where: { $0.interface == name }) {
                    routes.append(DefaultRoute(interface: name, gateway: gateway))
                }
            }
        }
        return routes
    }

    private static func maskIsZero(_ p: UnsafeRawPointer) -> Bool {
        let sa = p.assumingMemoryBound(to: sockaddr.self).pointee
        let bytes = p.assumingMemoryBound(to: UInt8.self)
        // Only the bytes past the sockaddr header matter; an all-zero mask means the default route.
        guard sa.sa_len > 4 else { return true }
        for i in 4..<Int(sa.sa_len) where bytes[i] != 0 { return false }
        return true
    }

    private static func saSize(_ saLen: UInt8) -> Int {
        let l = Int(saLen)
        let align = MemoryLayout<UInt32>.size
        return l == 0 ? align : (l + align - 1) & ~(align - 1)
    }
}

// MARK: - Interface addresses

extension Kernel {
    static func addresses(of iface: String) -> (v4: [String], v6: [String]) {
        var v4: [String] = []
        var v6: [String] = []
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return ([], []) }
        defer { freeifaddrs(head) }
        for cur in sequence(first: first, next: { $0.pointee.ifa_next }) {
            guard let nm = cur.pointee.ifa_name, String(cString: nm) == iface,
                  let sa = cur.pointee.ifa_addr else { continue }
            let fam = Int32(sa.pointee.sa_family)
            guard fam == AF_INET || fam == AF_INET6 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(NI_MAXHOST),
                              nil, 0, NI_NUMERICHOST) == 0 else { continue }
            var s = String(cString: host)
            if let cut = s.firstIndex(of: "%") { s = String(s[s.startIndex..<cut]) }  // strip the fe80::%en0 zone
            if fam == AF_INET { v4.append(s) } else if !s.hasPrefix("fe80") { v6.append(s) }
        }
        return (v4, v6)
    }
}
