import AppKit
import Combine
import FourthCivCore
import SwiftUI

/// A template bitmap lets macOS supply the correct tint on light, dark, and selected menu bars.
enum MenuBarIconRenderer {
    static func image(pixels: [MenuBarIcon.Pixel]) -> NSImage {
        let size = NSSize(width: MenuBarIcon.width, height: MenuBarIcon.height)
        let image = NSImage(size: size)
        for scale in [1, 2] {
            let width = MenuBarIcon.width * scale
            let height = MenuBarIcon.height * scale
            guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width,
                pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: width * 4, bitsPerPixel: 32),
                let bytes = bitmap.bitmapData else { continue }
            bytes.initialize(repeating: 0, count: bitmap.bytesPerRow * height)
            for pixel in pixels {
                let alpha = UInt8((min(1, max(0, pixel.opacity)) * 255).rounded())
                for dy in 0..<scale {
                    for dx in 0..<scale {
                        let offset = (pixel.y * scale + dy) * bitmap.bytesPerRow + (pixel.x * scale + dx) * 4
                        bytes[offset + 3] = alpha
                    }
                }
            }
            bitmap.size = size
            image.addRepresentation(bitmap)
        }
        image.isTemplate = true
        return image
    }
}

/// Pixel frames are observed only by the menu label, keeping animation out of the reader's model.
@MainActor final class MenuBarIconModel: ObservableObject {
    struct Frame {
        let image: NSImage
        let accessibilityLabel: String
    }

    @Published private(set) var frame = Frame(image: MenuBarIconRenderer.image(pixels: MenuBarIcon.pixels()),
        accessibilityLabel: "Fourth Civ")
    private var activity = MenuBarIconActivity()
    private var observations = Set<AnyCancellable>()
    private var animation: Task<Void, Never>?
    private var paused = false
    private var needsAttention = false
    private var updateAvailable = false
    private var reducedMotion: Bool

    init(reducedMotion: Bool = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion) {
        self.reducedMotion = reducedMotion
        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.reducedMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
                self.animation?.cancel()
                self.animation = nil
                self.refresh()
                self.animateIfNeeded()
            }.store(in: &observations)
        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.willSleepNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.stopActivity() }.store(in: &observations)
    }

    deinit { animation?.cancel() }

    func observe(_ node: CivNode) {
        // Published values arrive before the property changes; use the emitted value directly.
        node.$settings.map(\.paused).removeDuplicates().sink { [weak self] in
            self?.setPaused($0)
        }.store(in: &observations)
        node.$serverError.map { $0 != nil }.removeDuplicates().sink { [weak self] in
            self?.setNeedsAttention($0)
        }.store(in: &observations)
        node.$messageActivityCount.dropFirst().removeDuplicates().sink { [weak self] _ in
            self?.messageMoved()
        }.store(in: &observations)
    }

    func setNeedsAttention(_ value: Bool) {
        needsAttention = value
        if value { stopActivity() } else { refresh() }
    }

    private func setPaused(_ value: Bool) {
        paused = value
        if value { stopActivity() } else { refresh() }
    }

    func setUpdateAvailable(_ value: Bool) {
        guard updateAvailable != value else { return }
        updateAvailable = value
        refresh()
    }

    private func messageMoved() {
        guard !paused, !needsAttention else { return }
        activity.record(at: ProcessInfo.processInfo.systemUptime)
        refresh()
        animateIfNeeded()
    }

    private func stopActivity() {
        animation?.cancel()
        animation = nil
        activity.reset()
        refresh()
    }

    private func animateIfNeeded() {
        guard animation == nil, activity.remaining(at: ProcessInfo.processInfo.systemUptime) > 0 else { return }
        animation = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let remaining = self.activity.remaining(at: ProcessInfo.processInfo.systemUptime)
                if remaining <= 0 {
                    self.activity.reset()
                    self.animation = nil
                    self.refresh()
                    return
                }
                // Reduced Motion keeps one fixed frame; there is no timer while idle.
                let interval = self.reducedMotion ? remaining : min(0.05, remaining)
                do { try await Task.sleep(for: .seconds(interval)) }
                catch { return }
                guard !Task.isCancelled else { return }
                self.refresh()
            }
        }
    }

    private func refresh() {
        let now = ProcessInfo.processInfo.systemUptime
        let elapsed = activity.elapsed(at: now)
        let badge = MenuBarIcon.badge(needsAttention: needsAttention, paused: paused, updateAvailable: updateAvailable)
        let pixels = MenuBarIcon.pixels(elapsed: elapsed, remaining: activity.remaining(at: now),
            burst: activity.burst, reducedMotion: reducedMotion, badge: badge)
        let status: String
        switch badge {
        case .attention: status = " — needs attention"
        case .paused: status = " — paused"
        case .update: status = " — update available"
        case .none: status = ""
        }
        let moving = elapsed != nil && !paused && !needsAttention ? " — message activity" : ""
        frame = Frame(image: MenuBarIconRenderer.image(pixels: pixels), accessibilityLabel: "Fourth Civ" + status + moving)
    }
}

struct MenuBarIconLabel: View {
    @ObservedObject var model: MenuBarIconModel
    @ObservedObject var updates: AppUpdates

    var body: some View {
        Image(nsImage: model.frame.image)
            .renderingMode(.template)
            .interpolation(.none)
            .accessibilityLabel(model.frame.accessibilityLabel)
            .onReceive(updates.$availableVersion.map { $0 != nil }.removeDuplicates()) {
                model.setUpdateAvailable($0)
            }
    }
}
