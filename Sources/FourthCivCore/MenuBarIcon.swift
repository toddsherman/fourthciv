import Foundation

/// Pixel geometry from the approved capped-I, three-pixel-tip menu bar design.
/// Coordinates include its drawing offset and can be rendered directly at 1×.
public enum MenuBarIcon {
    public static let width = 42
    public static let height = 18

    public struct Pixel: Equatable, Sendable {
        public let x: Int
        public let y: Int
        public let opacity: Double

        public init(x: Int, y: Int, opacity: Double) {
            self.x = x; self.y = y; self.opacity = opacity
        }
    }

    public enum Badge: Equatable, Sendable { case none, attention, paused, update }

    public static func badge(needsAttention: Bool, paused: Bool, updateAvailable: Bool) -> Badge {
        if needsAttention { return .attention }
        if paused { return .paused }
        return updateAvailable ? .update : .none
    }

    public static func pixels(elapsed: TimeInterval? = nil, remaining: TimeInterval = 0,
                              burst: Bool = false, reducedMotion: Bool = false,
                              badge: Badge = .none) -> [Pixel] {
        var result = letters.filter(\.edge).map { Pixel(x: $0.point.x + 2, y: $0.point.y + 1, opacity: 0.66) }
        if let elapsed, elapsed.isFinite, remaining.isFinite, remaining > 0,
           badge != .attention, badge != .paused {
            let milliseconds = max(0, elapsed) * 1_000
            if milliseconds.isFinite {
                let envelope = min(1, min(milliseconds / 100, remaining / 0.26))
                let phase = Int(floor(milliseconds / 360).truncatingRemainder(dividingBy: 37))
                let blend = milliseconds.truncatingRemainder(dividingBy: 360) / 360
                for (index, letter) in letters.filter({ !$0.edge }).enumerated() {
                    let strength: Double
                    if reducedMotion {
                        // Keep one sparse pattern throughout a burst; new arrivals
                        // extend its life without changing density or moving pixels.
                        strength = (index * 7 + 3) % 11 < 4 ? 1 : 0
                    } else {
                        func sample(_ phase: Int) -> Double {
                            (index * 13 + phase * 17 + (index / 3) * 5) % 37 < (burst ? 14 : 9) ? 1 : 0
                        }
                        strength = (sample(phase) * (1 - blend) + sample(phase + 1) * blend) * envelope
                    }
                    if strength > 0 {
                        result.append(Pixel(x: letter.point.x + 2, y: letter.point.y + 1, opacity: strength))
                    }
                }
            }
        }
        func rectangle(_ x: Int, _ y: Int, _ width: Int, _ height: Int) {
            for row in y..<(y + height) {
                for column in x..<(x + width) { result.append(Pixel(x: column, y: row, opacity: 0.95)) }
            }
        }
        switch badge {
        case .none: break
        case .paused:
            rectangle(34, 9, 2, 7); rectangle(38, 9, 2, 7)
        case .attention:
            rectangle(36, 8, 2, 5); rectangle(36, 15, 2, 2)
        case .update:
            rectangle(36, 8, 1, 6)
            rectangle(34, 11, 1, 1); rectangle(35, 12, 1, 1)
            rectangle(37, 12, 1, 1); rectangle(38, 11, 1, 1)
            rectangle(34, 16, 5, 1)
        }
        return result
    }

    private struct Point: Hashable, Sendable { let x: Int; let y: Int }
    private struct LetterPixel: Sendable { let point: Point; let edge: Bool }

    private static let letters: [LetterPixel] = {
        var mask = Set<Point>()
        var ordered: [Point] = []
        func put(_ x: Int, _ y: Int) {
            let point = Point(x: x, y: y)
            if mask.insert(point).inserted { ordered.append(point) }
        }
        for y in 0..<15 {
            for x in 0..<9 where y < 4 || y > 10 || (2...6).contains(x) { put(x, y) }
            let left = min(7, Int((8 * Double(y) / 14).rounded()))
            let right = 16 - left
            for x in left...right where x < left + 5 || x > right - 5 { put(8 + x, y) }
        }
        // Outline the union, not each letter: their joined cap has no seam.
        return ordered.map { point in
            let edge = [(1, 0), (-1, 0), (0, 1), (0, -1)].contains { dx, dy in
                !mask.contains(Point(x: point.x + dx, y: point.y + dy))
            }
            return LetterPixel(point: point, edge: edge)
        }
    }()
}

/// One continuous activity period, ending 1.2 seconds after its last message.
/// Callers supply monotonic time so clock changes cannot restart the animation.
public struct MenuBarIconActivity: Sendable {
    private static let linger: TimeInterval = 1.2
    private var firstMessage: TimeInterval?
    private var lastMessage: TimeInterval?
    public private(set) var burst = false

    public init() {}

    public mutating func record(at time: TimeInterval) {
        guard time.isFinite else { return }
        if let lastMessage, time < lastMessage { return }
        if let lastMessage, time - lastMessage < Self.linger {
            burst = true
        } else {
            firstMessage = time
            burst = false
        }
        lastMessage = time
    }

    public mutating func reset() {
        firstMessage = nil; lastMessage = nil; burst = false
    }

    public func elapsed(at time: TimeInterval) -> TimeInterval? {
        guard let firstMessage, remaining(at: time) > 0 else { return nil }
        return time - firstMessage
    }

    public func remaining(at time: TimeInterval) -> TimeInterval {
        guard time.isFinite, let firstMessage, let lastMessage, time >= firstMessage else { return 0 }
        return max(0, min(Self.linger, Self.linger - (time - lastMessage)))
    }
}
