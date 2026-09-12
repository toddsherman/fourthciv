import Foundation
import Testing
@testable import FourthCivCore

struct MenuBarIconTests {
    private func coordinates(_ pixels: [MenuBarIcon.Pixel]) -> Set<String> {
        Set(pixels.map { "\($0.x),\($0.y)" })
    }

    @Test func idleMatchesTheApprovedJoinedHollowOutline() {
        // Snapshot of the approved prototype before its +2,+1 drawing offset.
        // Dots are hollow interior pixels; spaces are outside the joined letters.
        let rows = [
            "#############       #####",
            "#............#     #...# ",
            "#........#...#     #...# ",
            "##.....## #...#   #...#  ",
            "  #...#   #...#   #...#  ",
            "  #...#    #...# #...#   ",
            "  #...#    #...# #...#   ",
            "  #...#     #...#...#    ",
            "  #...#      #.....#     ",
            "  #...#      #.....#     ",
            "  #...#       #...#      ",
            "##.....##     #...#      ",
            "#.......#      #.#       ",
            "#.......#      #.#       ",
            "#########      ###       "
        ]
        var expected = Set<String>()
        for (y, row) in rows.enumerated() {
            for (x, cell) in row.enumerated() where cell == "#" { expected.insert("\(x + 2),\(y + 1)") }
        }
        let idle = MenuBarIcon.pixels()
        #expect(idle.count == 96)
        #expect(coordinates(idle) == expected)
        #expect(idle.allSatisfy { $0.opacity == 0.66 })
        // The shared I/V cap must stay hollow instead of acquiring a letter seam.
        #expect(!coordinates(idle).contains("10,2"))
        #expect(idle.filter { $0.y == 15 && $0.x > 10 }.map(\.x) == [17, 18, 19])
        #expect(!coordinates(idle).contains("18,14"))
    }

    @Test func inactivityIsStillAndActivePixelsStayInsideTheHollowLetters() {
        let idle = MenuBarIcon.pixels()
        #expect(MenuBarIcon.pixels(remaining: 1.2, burst: true) == idle)
        #expect(MenuBarIcon.pixels(elapsed: 0.5) == idle)
        #expect(MenuBarIcon.pixels(elapsed: 20, remaining: -1, reducedMotion: true) == idle)
        #expect(MenuBarIcon.pixels(elapsed: 0, remaining: 1.2) == idle)
        let active = MenuBarIcon.pixels(elapsed: 0.36, remaining: 0.84)
        let interior = active.filter { $0.opacity != 0.66 }
        // This frame is one complete sample from the approved scattered pattern.
        #expect(interior.count == 31)
        #expect(interior.allSatisfy { $0.opacity == 1 })
        #expect(coordinates(interior).contains("10,2"))
        #expect(!coordinates(active).contains("18,2"))
        #expect(coordinates(active).count == active.count)
        let fading = MenuBarIcon.pixels(elapsed: 0.36, remaining: 0.13).filter { $0.opacity != 0.66 }
        #expect(coordinates(fading) == coordinates(interior))
        #expect(fading.allSatisfy { abs($0.opacity - 0.5) < 0.000_001 })
    }

    @Test func badgesHaveApprovedGeometryAndPriority() {
        #expect(MenuBarIcon.badge(needsAttention: true, paused: true, updateAvailable: true) == .attention)
        #expect(MenuBarIcon.badge(needsAttention: false, paused: true, updateAvailable: true) == .paused)
        #expect(MenuBarIcon.badge(needsAttention: false, paused: false, updateAvailable: true) == .update)
        #expect(MenuBarIcon.badge(needsAttention: false, paused: false, updateAvailable: false) == .none)
        let pause = MenuBarIcon.pixels(badge: .paused).filter { $0.x >= 34 }
        #expect(pause.count == 28)
        #expect(pause.allSatisfy { [34, 35, 38, 39].contains($0.x) && (9...15).contains($0.y) })
        let attention = MenuBarIcon.pixels(badge: .attention).filter { $0.x >= 34 }
        #expect(attention.count == 14)
        #expect(attention.allSatisfy { (36...37).contains($0.x) && ((8...12).contains($0.y) || (15...16).contains($0.y)) })
        let update = MenuBarIcon.pixels(badge: .update).filter { $0.x >= 34 }
        #expect(coordinates(update) == Set([
            "36,8", "36,9", "36,10", "36,11", "36,12", "36,13",
            "34,11", "35,12", "37,12", "38,11",
            "34,16", "35,16", "36,16", "37,16", "38,16"
        ]))
        #expect((pause + attention + update).allSatisfy { $0.opacity == 0.95 })
        let suppressingBadges: [MenuBarIcon.Badge] = [.attention, .paused]
        for badge in suppressingBadges {
            #expect(MenuBarIcon.pixels(elapsed: 0.36, remaining: 1.2, burst: true, badge: badge) == MenuBarIcon.pixels(badge: badge))
        }
        #expect(MenuBarIcon.pixels(elapsed: 0.36, remaining: 1.2, badge: .update).count > MenuBarIcon.pixels(badge: .update).count)
    }

    @Test func everyPixelFitsTheMenuBarCanvas() {
        #expect(MenuBarIcon.width == 42)
        #expect(MenuBarIcon.height == 18)
        let badges: [MenuBarIcon.Badge] = [.none, .attention, .paused, .update]
        for badge in badges {
            for frame in 0..<75 {
                let pixels = MenuBarIcon.pixels(elapsed: Double(frame) / 25, remaining: 1.2, burst: true, badge: badge)
                #expect(pixels.allSatisfy {
                    (0..<MenuBarIcon.width).contains($0.x) && (0..<MenuBarIcon.height).contains($0.y) &&
                    $0.opacity > 0 && $0.opacity <= 1
                })
                #expect(coordinates(pixels).count == pixels.count)
            }
        }
    }

    @Test func reducedMotionKeepsTheSameSparsePixelsUntilIdle() {
        let fixed = MenuBarIcon.pixels(elapsed: 0, remaining: 1.2, reducedMotion: true)
        #expect(fixed.count == 96 + 45)
        #expect(MenuBarIcon.pixels(elapsed: 0.6, remaining: 0.6, reducedMotion: true) == fixed)
        #expect(MenuBarIcon.pixels(elapsed: 2.5, remaining: 0.001, burst: true, reducedMotion: true) == fixed)
        #expect(MenuBarIcon.pixels(elapsed: 2.6, remaining: 0, burst: true, reducedMotion: true) == MenuBarIcon.pixels())
    }

    @Test func newMessagesExtendOnePhaseWithoutQueuingReplays() {
        var activity = MenuBarIconActivity()
        #expect(activity.elapsed(at: 0) == nil)
        #expect(activity.remaining(at: 0) == 0)
        #expect(!activity.burst)
        activity.record(at: 10)
        #expect(activity.elapsed(at: 10) == 0)
        #expect(activity.remaining(at: 10) == 1.2)
        #expect(!activity.burst)
        activity.record(at: 10.5)
        activity.record(at: 11)
        #expect(activity.burst)
        #expect(activity.elapsed(at: 11.25) == 1.25)
        #expect(abs(activity.remaining(at: 11.25) - 0.95) < 0.000_001)
        #expect(activity.elapsed(at: 12.21) == nil)
        #expect(activity.remaining(at: 20) == 0)
        // A later arrival starts once at zero; the old burst does not replay.
        activity.record(at: 20)
        #expect(activity.elapsed(at: 20) == 0)
        #expect(!activity.burst)
        activity.reset()
        #expect(activity.elapsed(at: 20) == nil)
        #expect(activity.remaining(at: 20) == 0)
        #expect(!activity.burst)
    }

    @Test func anArrivalAtTheLingerBoundaryStartsANewPeriod() {
        var activity = MenuBarIconActivity()
        activity.record(at: 0)
        #expect(activity.elapsed(at: 1.2) == nil)
        activity.record(at: 1.2)
        #expect(activity.elapsed(at: 1.2) == 0)
        #expect(!activity.burst)
        activity.record(at: 1.2)
        #expect(activity.burst)
        // Ignore out-of-order samples rather than moving the current phase back.
        activity.record(at: 1)
        #expect(abs((activity.elapsed(at: 1.3) ?? -1) - 0.1) < 0.000_001)
        activity.record(at: .infinity)
        #expect(activity.remaining(at: .nan) == 0)
        #expect(activity.elapsed(at: 10) == nil)
    }
}
