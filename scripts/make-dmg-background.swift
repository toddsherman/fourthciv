import AppKit
import Foundation

// Render the installer artwork without controlling Finder. Keep icon placement
// in the shared layout file so the mounted volume and artwork agree.
struct InstallerLayout: Decodable {
    let width: Int
    let height: Int
    let iconSize: Int
    let iconLocations: [String: [Int]]
}

guard CommandLine.arguments.count == 2 else {
    fputs("Usage: swift scripts/make-dmg-background.swift OUTPUT_DIRECTORY\n", stderr)
    exit(1)
}
let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let layout = try JSONDecoder().decode(InstallerLayout.self,
    from: Data(contentsOf: root.appendingPathComponent("Resources/DMG/layout.json")))
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
let width = CGFloat(layout.width), height = CGFloat(layout.height)
let paper = NSColor(srgbRed: 0.949, green: 0.937, blue: 0.910, alpha: 1)
let ink = NSColor(srgbRed: 0.125, green: 0.173, blue: 0.180, alpha: 1)
let muted = NSColor(srgbRed: 0.337, green: 0.361, blue: 0.345, alpha: 1)
let bronze = NSColor(srgbRed: 0.545, green: 0.365, blue: 0.184, alpha: 1)

var representations: [NSBitmapImageRep] = []
for scale in [1, 2] {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: layout.width * scale,
        pixelsHigh: layout.height * scale, bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    bitmap.size = NSSize(width: width, height: height)
    NSGraphicsContext.saveGraphicsState()
    let context = NSGraphicsContext(bitmapImageRep: bitmap)!
    NSGraphicsContext.current = context
    // NSGraphicsContext already scales from bitmap.size to the pixel dimensions.
    paper.setFill()
    NSRect(x: 0, y: 0, width: width, height: height).fill()

    func rect(_ x: CGFloat, _ top: CGFloat, _ w: CGFloat, _ h: CGFloat) -> NSRect {
        NSRect(x: x, y: height - top - h, width: w, height: h)
    }
    func text(_ string: String, x: CGFloat, top: CGFloat, font: NSFont, color: NSColor) {
        let text = NSAttributedString(string: string, attributes: [.font: font, .foregroundColor: color])
        let size = text.size()
        text.draw(at: NSPoint(x: x, y: height - top - size.height))
    }
    func step(_ number: String, top: CGFloat) {
        bronze.setFill()
        NSBezierPath(ovalIn: rect(40, top, 25, 25)).fill()
        let numeral = NSAttributedString(string: number, attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold), .foregroundColor: NSColor.white])
        let size = numeral.size()
        numeral.draw(at: NSPoint(x: 52.5 - size.width / 2, y: height - top - 12.5 - size.height / 2))
    }

    text("Install Fourth Civ", x: 40, top: 37,
         font: NSFont(name: "Georgia", size: 32) ?? .systemFont(ofSize: 32), color: ink)
    text("A little space for the commons.", x: 41, top: 82,
         font: .systemFont(ofSize: 14), color: muted)

    step("1", top: 126)
    text("Drag Fourth Civ into Applications.", x: 78, top: 127,
         font: .systemFont(ofSize: 19, weight: .medium), color: ink)

    // The real app and Applications icons occupy the space on either side.
    let app = layout.iconLocations["Fourth Civ.app"]!
    let applications = layout.iconLocations["Applications"]!
    let arrowY = height - CGFloat(app[1])
    let arrowLeft = CGFloat(app[0]) + 116
    let arrowRight = CGFloat(applications[0]) - 116
    bronze.setStroke()
    let arrow = NSBezierPath()
    arrow.lineWidth = 3
    arrow.lineCapStyle = .round
    arrow.lineJoinStyle = .round
    arrow.move(to: NSPoint(x: arrowLeft, y: arrowY))
    arrow.line(to: NSPoint(x: arrowRight, y: arrowY))
    arrow.move(to: NSPoint(x: arrowRight - 13, y: arrowY + 11))
    arrow.line(to: NSPoint(x: arrowRight, y: arrowY))
    arrow.line(to: NSPoint(x: arrowRight - 13, y: arrowY - 11))
    arrow.stroke()

    ink.withAlphaComponent(0.14).setFill()
    rect(40, 329, width - 80, 1).fill()
    step("2", top: 357)
    text("Open Fourth Civ from Applications.", x: 78, top: 359,
         font: .systemFont(ofSize: 17, weight: .medium), color: ink)
    text("Look for IV in your menu bar.", x: 78, top: 390,
         font: .systemFont(ofSize: 14), color: muted)
    text("After installing, eject this disk.", x: 78, top: 447,
         font: .systemFont(ofSize: 12), color: muted)

    NSGraphicsContext.restoreGraphicsState()
    let suffix = scale == 2 ? "@2x" : ""
    try bitmap.representation(using: .png, properties: [:])!
        .write(to: output.appendingPathComponent("background\(suffix).png"))
    representations.append(bitmap)
}
try NSBitmapImageRep.representationOfImageReps(in: representations, using: .tiff, properties: [:])!
    .write(to: output.appendingPathComponent("background.tiff"))
