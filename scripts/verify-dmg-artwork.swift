import AppKit
import ImageIO

// Compare logical image content, not just bitmap dimensions. Averaging 8×8-point
// tiles tolerates font antialiasing while catching a second accidental 2× scale.
struct ArtworkFailure: Error, CustomStringConvertible {
    let description: String
}

struct Raster {
    let width: Int
    let height: Int
    let rgba: [UInt8]

    init(_ url: URL) throws {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw ArtworkFailure(description: "Cannot decode \(url.lastPathComponent)")
        }
        let width = image.width, height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let rendered = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let context = CGContext(data: buffer.baseAddress, width: width, height: height,
                      bitsPerComponent: 8, bytesPerRow: width * 4, space: space,
                      bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard rendered else { throw ArtworkFailure(description: "Cannot read artwork pixels") }
        self.width = width
        self.height = height
        rgba = bytes
    }

    func meanLuminance(x: Int, y: Int, width tileWidth: Int, height tileHeight: Int, scale: Int) -> Double {
        var total = 0.0
        for row in (y * scale)..<((y + tileHeight) * scale) {
            for column in (x * scale)..<((x + tileWidth) * scale) {
                let offset = (row * width + column) * 4
                total += 0.2126 * Double(rgba[offset]) + 0.7152 * Double(rgba[offset + 1]) + 0.0722 * Double(rgba[offset + 2])
            }
        }
        return total / Double(tileWidth * tileHeight * scale * scale) / 255
    }
}

do {
    guard CommandLine.arguments.count == 2 else {
        throw ArtworkFailure(description: "Usage: swift scripts/verify-dmg-artwork.swift ARTWORK_DIRECTORY")
    }
    let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
    let normal = try Raster(directory.appendingPathComponent("background.png"))
    let retina = try Raster(directory.appendingPathComponent("background@2x.png"))
    guard retina.width == normal.width * 2, retina.height == normal.height * 2 else {
        throw ArtworkFailure(description: "Retina artwork must have exactly twice the pixel width and height")
    }
    var differences: [Double] = []
    for y in stride(from: 0, to: normal.height, by: 8) {
        for x in stride(from: 0, to: normal.width, by: 8) {
            let width = min(8, normal.width - x), height = min(8, normal.height - y)
            differences.append(abs(
                normal.meanLuminance(x: x, y: y, width: width, height: height, scale: 1) -
                retina.meanLuminance(x: x, y: y, width: width, height: height, scale: 2)))
        }
    }
    let mean = differences.reduce(0, +) / Double(differences.count)
    let maximum = differences.max() ?? 0
    let metrics = String(format: "mean tile difference %.5f; maximum %.5f", mean, maximum)
    guard mean <= 0.01, maximum <= 0.15 else {
        throw ArtworkFailure(description: "1× and 2× artwork content differs: \(metrics)")
    }
    print("Artwork resolution check passed: \(metrics)")
} catch {
    fputs("\(error)\n", stderr)
    exit(1)
}
