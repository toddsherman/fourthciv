import Foundation
import Darwin

public enum LocalNetwork {
    /// Only canonical dotted-decimal loopback, RFC1918, and IPv4 link-local addresses.
    /// Hostnames are deliberately excluded so DNS cannot redirect a peer to the internet.
    public static func permits(_ host: String, allowLAN: Bool) -> Bool {
        let fields = host.split(separator: ".", omittingEmptySubsequences: false)
        guard fields.count == 4 else { return false }
        let octets = fields.compactMap { UInt8($0) }
        guard octets.count == 4, zip(fields, octets).allSatisfy({ String($0.1) == $0.0 }) else { return false }
        if host == "127.0.0.1" { return true }
        guard allowLAN else { return false }
        return octets[0] == 10 ||
            (octets[0] == 172 && (16...31).contains(octets[1])) ||
            (octets[0] == 192 && octets[1] == 168) ||
            (octets[0] == 169 && octets[1] == 254)
    }

    public static func addresses() -> [String] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0 else { return [] }
        defer { freeifaddrs(head) }
        var result = Set<String>()
        var current = head
        while let entry = current {
            defer { current = entry.pointee.ifa_next }
            guard let address = entry.pointee.ifa_addr,
                  address.pointee.sa_family == UInt8(AF_INET),
                  entry.pointee.ifa_flags & UInt32(IFF_UP) != 0 else { continue }
            var name = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(address, socklen_t(address.pointee.sa_len), &name, socklen_t(name.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let host = String(cString: name)
            if host != "127.0.0.1" && permits(host, allowLAN: true) { result.insert(host) }
        }
        return result.sorted()
    }
}
