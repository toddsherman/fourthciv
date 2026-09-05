import Foundation

public enum RelayEndpoint {
    public static let pilot = "https://fourthciv-pilot.vercel.app"
    public static func validate(_ text: String) throws -> URL {
        guard text.utf8.count <= 2_048, let parts = URLComponents(string: text),
              parts.scheme == "https", let host = parts.host?.lowercased(),
              parts.port == nil || parts.port == 443,
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              parts.path.isEmpty || parts.path == "/",
              host.contains("."), ![".local", ".localhost", ".internal", ".test", ".invalid"].contains(where: host.hasSuffix),
              host.split(separator: ".", omittingEmptySubsequences: false).allSatisfy({ label in
                  !label.isEmpty && label.count <= 63 && label.first != "-" && label.last != "-" &&
                  label.utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }
              }), host.split(separator: ".").last?.contains(where: { $0.isLetter }) == true,
              let url = parts.url else { throw CivError("Use an HTTPS relay hostname with no path, credentials, or custom port") }
        return url
    }
}

public struct RelayDiscovery: Decodable {
    public let name: String
    public let `protocol`: String
    public let visibility: String
    public let capabilities: [String]
    public let epoch: String
    public func validate() throws {
        guard `protocol` == "fourthciv/1", visibility == "public", capabilities.contains("relay-sync-v1"),
              UUID(uuidString: epoch) != nil else { throw CivError("Endpoint is not a compatible public Fourth Civ relay") }
    }
}

public struct RelayPage: Decodable {
    public let events: [Event]
    public let next: Int?
    public let cursor: Int
    public let epoch: String
}

public struct RelayProgress: Codable {
    public var epoch = ""
    public var offset = 0
    public var acknowledged: Set<String> = []
    public init() {}
}

/// Persistent accounting reserves capacity before a transfer, including across crashes.
/// The budget measures application request/response bodies, not TCP/TLS overhead.
@MainActor public final class SyncLedger {
    private struct State: Codable {
        var day: Int
        var bytes = 0
        var relays: [String: RelayProgress] = [:]
    }
    private var state: State
    private let file: URL
    public init(directory: URL, now: Date = Date()) throws {
        file = directory.appendingPathComponent("internet-sync.json")
        if FileManager.default.fileExists(atPath: file.path) {
            let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= 2 * 1_024 * 1_024 else { throw CivError("Sync ledger is too large") }
            state = try JSONDecoder().decode(State.self, from: Data(contentsOf: file))
            guard state.bytes >= 0, state.relays.count <= 8,
                  state.relays.values.allSatisfy({ (0...2_000).contains($0.offset) && $0.acknowledged.count <= 2_000 }) else {
                throw CivError("Invalid sync ledger")
            }
        } else { state = State(day: Self.day(now)) }
    }
    private static func day(_ date: Date) -> Int { Int(date.timeIntervalSince1970 / 86_400) }
    public func used(now: Date = Date()) -> Int { state.day == Self.day(now) ? state.bytes : 0 }
    public func remaining(limit: Int, now: Date = Date()) -> Int { max(0, limit - used(now: now)) }
    private func save(_ updated: State) throws {
        try JSONEncoder().encode(updated).write(to: file, options: .atomic)
        state = updated
    }
    public struct Reservation { fileprivate let day: Int; fileprivate let bytes: Int }
    public func reserve(_ bytes: Int, limit: Int, now: Date = Date()) throws -> Reservation {
        guard bytes >= 0, bytes <= remaining(limit: limit, now: now) else { throw CivError("Daily sync-data budget reached; it resets at midnight UTC") }
        var updated = state
        if updated.day != Self.day(now) { updated.day = Self.day(now); updated.bytes = 0 }
        updated.bytes += bytes
        try save(updated)
        return Reservation(day: updated.day, bytes: bytes)
    }
    public func settle(_ reservation: Reservation, actual: Int) throws {
        // A cancelled response can deliver an in-flight chunk beyond its reservation.
        // Record it so the next request cannot spend that capacity again.
        guard actual >= 0, actual <= 64 * 1_024 * 1_024 else { throw CivError("Invalid transfer accounting") }
        guard state.day == reservation.day else { return }
        var updated = state; updated.bytes -= reservation.bytes - actual
        try save(updated)
    }
    public func progress(for relay: String) -> RelayProgress { state.relays[relay] ?? RelayProgress() }
    public func setProgress(_ value: RelayProgress, for relay: String) throws {
        var updated = state; updated.relays[relay] = value; try save(updated)
    }
    public func retain(_ relays: [String]) throws {
        var updated = state; updated.relays = updated.relays.filter { relays.contains($0.key) }; try save(updated)
    }
}
