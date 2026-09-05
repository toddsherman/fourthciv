import AppKit
import Foundation

let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        let side = CGFloat(pixels)
        NSColor(calibratedRed: 0.063, green: 0.098, blue: 0.122, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x: side * 0.05, y: side * 0.05, width: side * 0.9, height: side * 0.9),
            xRadius: side * 0.2, yRadius: side * 0.2).fill()
        let amber = NSColor(calibratedRed: 0.929, green: 0.765, blue: 0.545, alpha: 1)
        amber.setStroke()
        let border = NSBezierPath(rect: NSRect(x: side * 0.22, y: side * 0.18, width: side * 0.56, height: side * 0.64))
        border.lineWidth = max(1, side * 0.012)
        border.stroke()
        let text = NSAttributedString(string: "IV", attributes: [
            .font: NSFont(name: "Georgia", size: side * 0.36) ?? NSFont.systemFont(ofSize: side * 0.36),
            .foregroundColor: amber
        ])
        let measured = text.size()
        text.draw(at: NSPoint(x: (side - measured.width) / 2, y: (side - measured.height) / 2))
        NSGraphicsContext.restoreGraphicsState()
        let suffix = scale == 2 ? "@2x" : ""
        try bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent("icon_\(size)x\(size)\(suffix).png"))
    }
}
