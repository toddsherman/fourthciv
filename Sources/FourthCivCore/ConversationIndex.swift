import Foundation

/// A local reading index over the complete saved message collection. It does not
/// infer whether a participant is online or whether a message was recently received.
public struct ConversationIndex {
    private let eventsByID: [String: Event]
    private let rootsByID: [String: String]
    private let conversationsByRoot: [String: [Event]]
    private let participantsByRoot: [String: Int]

    public init(messages: [Event]) {
        var events: [String: Event] = [:]
        for event in messages where event.kind == .message && events[event.id] == nil {
            events[event.id] = event
        }
        let ordered = events.values.sorted(by: Self.precedes)

        // Store validation normally guarantees these relationships. Keeping the
        // index defensive also makes incomplete local snapshots safe to browse.
        var parents: [String: String] = [:]
        for event in ordered {
            if let parent = events[event.parent], parent.community == event.community, parent.id != event.id {
                parents[event.id] = parent.id
            }
        }
        var roots: [String: String] = [:]
        for event in ordered where roots[event.id] == nil {
            var path: [String] = []
            var positions: [String: Int] = [:]
            var current = event.id
            let root: String
            while true {
                if let known = roots[current] {
                    root = known
                    break
                }
                if let cycleStart = positions[current] {
                    // Pick the same local root regardless of input order and cut
                    // only its parent edge; valid descendants remain together.
                    root = path[cycleStart...].min { Self.precedes(events[$0]!, events[$1]!) }!
                    parents.removeValue(forKey: root)
                    break
                }
                positions[current] = path.count
                path.append(current)
                guard let parent = parents[current] else {
                    root = current
                    break
                }
                current = parent
            }
            for id in path { roots[id] = root }
        }

        var children: [String: [Event]] = [:]
        for event in ordered {
            if let parent = parents[event.id] { children[parent, default: []].append(event) }
        }
        var conversations: [String: [Event]] = [:]
        var participantCounts: [String: Int] = [:]
        for event in ordered where roots[event.id] == event.id {
            var available = MessageHeap()
            available.insert(event)
            var conversation: [Event] = []
            var authors = Set<String>()
            while let next = available.removeFirst() {
                conversation.append(next)
                authors.insert(next.author)
                for child in children[next.id, default: []] { available.insert(child) }
            }
            conversations[event.id] = conversation
            participantCounts[event.id] = authors.count
        }
        eventsByID = events
        rootsByID = roots
        conversationsByRoot = conversations
        participantsByRoot = participantCounts
    }

    public func event(id: String) -> Event? { eventsByID[id] }

    public func rootID(for id: String) -> String? { rootsByID[id] }

    /// Parents precede their replies. Among messages whose parents have already
    /// appeared, author-declared time and then event ID provide a stable order.
    public func conversation(containing id: String) -> [Event] {
        guard let root = rootsByID[id] else { return [] }
        return conversationsByRoot[root] ?? []
    }

    /// Public names can change or be shared; signing keys distinguish participants.
    public func participantCount(containing id: String) -> Int {
        guard let root = rootsByID[id] else { return 0 }
        return participantsByRoot[root] ?? 0
    }

    fileprivate static func precedes(_ lhs: Event, _ rhs: Event) -> Bool {
        lhs.createdAt == rhs.createdAt ? lhs.id < rhs.id : lhs.createdAt < rhs.createdAt
    }
}

/// Keeps parent-first ordering O(n log n) even when one message has many replies.
private struct MessageHeap {
    private var values: [Event] = []

    mutating func insert(_ event: Event) {
        values.append(event)
        var child = values.count - 1
        while child > 0 {
            let parent = (child - 1) / 2
            guard ConversationIndex.precedes(values[child], values[parent]) else { break }
            values.swapAt(child, parent)
            child = parent
        }
    }

    mutating func removeFirst() -> Event? {
        guard let first = values.first else { return nil }
        let last = values.removeLast()
        guard !values.isEmpty else { return first }
        values[0] = last
        var parent = 0
        while parent * 2 + 1 < values.count {
            let left = parent * 2 + 1
            let right = left + 1
            let child = right < values.count && ConversationIndex.precedes(values[right], values[left]) ? right : left
            guard ConversationIndex.precedes(values[child], values[parent]) else { break }
            values.swapAt(parent, child)
            parent = child
        }
        return first
    }
}
