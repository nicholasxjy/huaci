#!/usr/bin/env swift
import AppKit

// Huaci's icon: a white serif 文 crossed by a highlighter stroke (划 = marking
// text) on the app's indigo. The glyph outline comes from Songti SC, which
// ships with macOS; the committed PNG and icns do not need it at build time.
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let resources = root.appendingPathComponent("Resources", isDirectory: true)
let fileManager = FileManager.default
let canvasSize = 1024

enum IconError: Error {
    case renderingFailed
    case encodingFailed
    case conversionFailed(Int32)
}

let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

func color(_ hex: UInt32, alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255,
            green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255, alpha: alpha)
}

func fill(_ context: CGContext, _ path: CGPath, _ fillColor: CGColor,
          shadow: (offset: CGFloat, blur: CGFloat, color: CGColor)? = nil) {
    context.saveGState()
    if let shadow {
        context.setShadow(offset: CGSize(width: 0, height: shadow.offset), blur: shadow.blur, color: shadow.color)
    }
    context.addPath(path)
    context.setFillColor(fillColor)
    context.fillPath()
    context.restoreGState()
}

/// Outline of one character from the named font, its bounding box centered on `center`.
func glyph(_ character: Character, fontName: String, size: CGFloat, center: CGPoint) throws -> CGPath {
    let font = CTFontCreateWithName(fontName as CFString, size, nil)
    var characters = Array(String(character).utf16)
    var glyphs = [CGGlyph](repeating: 0, count: characters.count)
    guard CTFontGetGlyphsForCharacters(font, &characters, &glyphs, characters.count),
          let path = CTFontCreatePathForGlyph(font, glyphs[0], nil) else { throw IconError.renderingFailed }
    let box = path.boundingBoxOfPath
    var move = CGAffineTransform(translationX: center.x - box.midX, y: center.y - box.midY)
    guard let centered = path.copy(using: &move) else { throw IconError.renderingFailed }
    return centered
}

/// Drawn in Core Graphics' y-up coordinates.
func artwork() throws -> CGImage {
    guard let context = CGContext(data: nil, width: canvasSize, height: canvasSize,
                                  bitsPerComponent: 8, bytesPerRow: 0, space: sRGB,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        throw IconError.renderingFailed
    }
    context.setAllowsAntialiasing(true)

    // macOS icon grid: an 824-point tile with a transparent margin.
    let tile = CGPath(roundedRect: CGRect(x: 100, y: 100, width: 824, height: 824),
                      cornerWidth: 185, cornerHeight: 185, transform: nil)
    fill(context, tile, color(0x3A4BC6), shadow: (-12, 28, color(0x1A2050, alpha: 0.30)))
    context.saveGState()
    context.addPath(tile)
    context.clip()
    let indigo = CGGradient(colorsSpace: sRGB, colors: [color(0x6474F4), color(0x4153D6), color(0x2E3DAE)] as CFArray,
                            locations: nil)!
    context.drawLinearGradient(indigo, start: CGPoint(x: 300, y: 924), end: CGPoint(x: 700, y: 100),
                               options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    context.restoreGState()
    context.addPath(tile)
    context.setStrokeColor(color(0xFFFFFF, alpha: 0.18))
    context.setLineWidth(3)
    context.strokePath()

    // The highlighter stroke, slightly tilted like a hand-drawn mark.
    context.saveGState()
    context.translateBy(x: 512, y: 380)
    context.rotate(by: 0.06)
    fill(context, CGPath(roundedRect: CGRect(x: -300, y: -88, width: 600, height: 176),
                         cornerWidth: 40, cornerHeight: 40, transform: nil), color(0x8EE7CF))
    context.restoreGState()

    let character = try glyph("文", fontName: "STSongti-SC-Black", size: 560, center: CGPoint(x: 512, y: 528))
    fill(context, character, color(0xFFFFFF), shadow: (-10, 24, color(0x141A4A, alpha: 0.30)))

    guard let image = context.makeImage() else { throw IconError.renderingFailed }
    return image
}

func writePNG(_ image: CGImage, size: Int, to url: URL) throws {
    guard let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: sRGB,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        throw IconError.renderingFailed
    }
    context.interpolationQuality = .high
    context.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
    guard let resized = context.makeImage(),
          let data = NSBitmapImageRep(cgImage: resized).representation(using: .png, properties: [:]) else {
        throw IconError.encodingFailed
    }
    try data.write(to: url)
}

try fileManager.createDirectory(at: resources, withIntermediateDirectories: true)
let image = try artwork()
try writePNG(image, size: canvasSize, to: resources.appendingPathComponent("AppIcon.png"))
let temporary = fileManager.temporaryDirectory.appendingPathComponent("Huaci-icons-\(UUID().uuidString)")
let iconset = temporary.appendingPathComponent("AppIcon.iconset", isDirectory: true)
try fileManager.createDirectory(at: iconset, withIntermediateDirectories: true)
defer { try? fileManager.removeItem(at: temporary) }
for size in [16, 32, 128, 256, 512] {
    try writePNG(image, size: size, to: iconset.appendingPathComponent("icon_\(size)x\(size).png"))
    try writePNG(image, size: size * 2, to: iconset.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
}
let converter = Process()
converter.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
converter.arguments = ["-c", "icns", iconset.path, "-o", resources.appendingPathComponent("AppIcon.icns").path]
try converter.run()
converter.waitUntilExit()
guard converter.terminationStatus == 0 else { throw IconError.conversionFailed(converter.terminationStatus) }
print("Generated Resources/AppIcon.png and Resources/AppIcon.icns")
