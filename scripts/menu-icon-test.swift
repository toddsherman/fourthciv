import AppKit
import Combine
import CryptoKit
import FourthCivCore

// Compile alongside the production menu icon, updater, and theme sources.
// All messages use an injected transport and temporary store; no sockets are opened.
@main struct MenuIconTest {
    @MainActor static func main() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("fourthciv-icon-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let key = Curve25519.Signing.PrivateKey()
        let attribution = Attribution(name: "Icon fixture")
        let community = try Event.signed(kind: .community, key: key, attribution: attribution,
            title: "Icon fixture", body: "Local test only")
        var page = [community]
        let node = try CivNode(directory: directory, request: { _, _, _, _, _, _ in
            try JSONEncoder().encode(EventPage(events: page, next: nil))
        })
        var settings = node.settings
        settings.peers = ["http://127.0.0.1:1"]
        try node.updateSettings(settings)
        let reduced = MenuBarIconModel(reducedMotion: true)
        reduced.observe(node)
        let idle = bytes(reduced.frame.image)
        await node.sync()
        precondition(bytes(reduced.frame.image) == idle, "Community receipt must stay hollow")

        func message(_ body: String) throws -> Event {
            try Event.signed(kind: .message, key: key, attribution: attribution, community: community.id, body: body)
        }
        page.append(try message("First receipt"))
        await node.sync()
        let staticActivity = bytes(reduced.frame.image)
        precondition(staticActivity != idle && reduced.frame.accessibilityLabel.contains("message activity"))
        try await Task.sleep(for: .milliseconds(250))
        precondition(bytes(reduced.frame.image) == staticActivity, "Reduced Motion must not move pixels")
        page.append(try message("Burst extends the hold"))
        await node.sync()
        precondition(bytes(reduced.frame.image) == staticActivity, "Reduced Motion must keep its pattern during bursts")
        try await Task.sleep(for: .milliseconds(1_000))
        precondition(bytes(reduced.frame.image) == staticActivity, "A burst must extend the highlight")
        try await Task.sleep(for: .milliseconds(350))
        precondition(bytes(reduced.frame.image) == idle, "The highlight must expire without another node update")

        let animated = MenuBarIconModel(reducedMotion: false)
        animated.observe(node)
        precondition(bytes(animated.frame.image) == idle, "Attaching to saved activity must not replay it")
        await node.sync()
        precondition(bytes(animated.frame.image) == idle, "Duplicate downloads must stay hollow")
        // Observe actual publications before receipt. A hosted runner can resume
        // this test after a timer tick (or the whole short activity period), so a
        // single bitmap read after a fixed sleep does not reliably test animation.
        var activeFrames = Set<Data>()
        let frames = animated.$frame.sink { frame in
            let image = bytes(frame.image)
            if image != idle { activeFrames.insert(image) }
        }
        page.append(try message("Animated receipt"))
        await node.sync()
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while activeFrames.count < 2 && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        precondition(activeFrames.count >= 2,
            "Normal receipt must publish distinct non-idle frames; observed \(activeFrames.count), \(animated.frame.accessibilityLabel)")
        frames.cancel()
        settings.paused = true
        try node.updateSettings(settings)
        assertFrame(animated, badge: .paused)
        settings.paused = false
        try node.updateSettings(settings)
        precondition(bytes(animated.frame.image) == idle, "Resume must not replay canceled activity")
        animated.setUpdateAvailable(true)
        assertFrame(animated, badge: .update)
        settings.paused = true
        try node.updateSettings(settings)
        assertFrame(animated, badge: .paused)
        animated.setNeedsAttention(true)
        assertFrame(animated, badge: .attention)
        try await Task.sleep(for: .milliseconds(1_300))
        assertFrame(animated, badge: .attention)

        let image = MenuBarIconRenderer.image(pixels: MenuBarIcon.pixels())
        precondition(image.isTemplate && image.size == NSSize(width: 42, height: 18))
        precondition(image.representations.count == 2)
        for case let bitmap as NSBitmapImageRep in image.representations {
            let scale = bitmap.pixelsWide / 42
            precondition(bitmap.size == image.size && bitmap.pixelsHigh == 18 * scale)
            let data = bitmap.bitmapData!
            for y in 0..<bitmap.pixelsHigh {
                for x in 0..<bitmap.pixelsWide {
                    let expected = MenuBarIcon.pixels().contains { $0.x == x / scale && $0.y == y / scale } ? UInt8(168) : 0
                    precondition(data[y * bitmap.bytesPerRow + x * 4 + 3] == expected,
                        "Template bitmap must preserve exact square pixels and row orientation at each scale")
                }
            }
        }
        print("Native icon checks passed: templates at 1x/2x, receipt, duplicates, animation, reduced motion, burst expiry, pause/resume, badge priority.")
    }

    @MainActor private static func assertFrame(_ model: MenuBarIconModel, badge: MenuBarIcon.Badge) {
        precondition(bytes(model.frame.image) == bytes(MenuBarIconRenderer.image(pixels: MenuBarIcon.pixels(badge: badge))))
    }

    private static func bytes(_ image: NSImage) -> Data {
        let bitmap = image.representations[0] as! NSBitmapImageRep
        return Data(bytes: bitmap.bitmapData!, count: bitmap.bytesPerRow * bitmap.pixelsHigh)
    }
}
