import Foundation
import Darwin

/// Serialized by the main actor. The prototype uses an atomic JSON snapshot and a process lock.
@MainActor public final class EventStore {
    public private(set) var events: [Event] = []
    public private(set) var bytes = 0
    public var limitBytes: Int
    private var ids = Set<String>()
    private let file: URL
    private var lockFD: Int32 = -1

    public init(directory: URL, limitBytes: Int = 16 * 1_024 * 1_024) throws {
        self.limitBytes = limitBytes
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        file = directory.appendingPathComponent("events.json")
        lockFD = Darwin.open(directory.appendingPathComponent("node.lock").path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard lockFD >= 0 else { throw CivError("Cannot open node data lock") }
        guard flock(lockFD, LOCK_EX | LOCK_NB) == 0 else {
            Darwin.close(lockFD); lockFD = -1
            throw CivError("Another node is using this data directory")
        }
        do {
            if FileManager.default.fileExists(atPath: file.path) {
                let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard size <= 64 * 1_024 * 1_024 else { throw CivError("Stored data exceeds prototype maximum") }
                let data = try Data(contentsOf: file)
                let loaded = try JSONDecoder().decode([Event].self, from: data)
                guard loaded.count <= 2_000 else { throw CivError("Too many stored events") }
                for event in loaded {
                    try event.validate()
                    try validateReferences(event)
                    guard ids.insert(event.id).inserted else { throw CivError("Duplicate stored event") }
                    events.append(event)
                }
                bytes = data.count
            }
        } catch {
            Darwin.close(lockFD); lockFD = -1
            throw error
        }
    }

    deinit { if lockFD >= 0 { Darwin.close(lockFD) } }

    @discardableResult public func insert(_ event: Event) throws -> Bool {
        try event.validate()
        if ids.contains(event.id) { return false }
        try validateReferences(event)
        guard events.count < 2_000 else { throw CivError("Prototype event limit reached (2,000)") }
        let data = try JSONEncoder().encode(events + [event])
        guard data.count <= limitBytes else { throw CivError("Storage budget reached; increase it in host settings") }
        try data.write(to: file, options: .atomic)
        events.append(event); ids.insert(event.id); bytes = data.count
        return true
    }

    private func validateReferences(_ event: Event) throws {
        if event.kind == .message {
            guard events.contains(where: { $0.id == event.community && $0.kind == .community }) else {
                throw CivError("Unknown community; publish or synchronize it first")
            }
            if !event.parent.isEmpty {
                guard events.contains(where: { $0.id == event.parent && $0.kind == .message && $0.community == event.community }) else {
                    throw CivError("Reply must reference an existing message in this community")
                }
            }
        }
    }

    public func page(offset: Int, limit: Int = 64, kind: EventKind? = nil) -> EventPage {
        let selected = kind.map { kind in events.filter { $0.kind == kind } } ?? events
        let start = min(max(offset, 0), selected.count)
        var end = start; var pageBytes = 256
        for event in selected.dropFirst(start).prefix(min(max(limit, 1), 64)) {
            let size = ((try? JSONEncoder().encode(event).count) ?? 128 * 1_024) + 1
            if end > start && pageBytes + size > 256 * 1_024 { break }
            pageBytes += size; end += 1
        }
        return EventPage(events: Array(selected[start..<end]), next: end < selected.count ? end : nil)
    }
}
