#!/usr/bin/env swift
import AppKit

// Huaci's icon: a selected Latin letter and a Chinese translation bubble.
// All artwork uses vector paths; no fonts or external tools are needed to redraw it.
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let resources = root.appendingPathComponent("Resources", isDirectory: true)
let fileManager = FileManager.default
let canvasSize = 1024

enum IconError: Error {
    case renderingFailed
    case encodingFailed
    case conversionFailed(Int32)
}

func color(_ hex: UInt32, alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255,
            green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255, alpha: alpha)
}

func gradient(_ context: CGContext, path: CGPath, colors: [CGColor], from: CGPoint, to: CGPoint) {
    context.saveGState()
    context.addPath(path)
    context.clip()
    let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                              colors: colors as CFArray, locations: nil)!
    context.drawLinearGradient(gradient, start: from, end: to,
                               options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    context.restoreGState()
}

func bubble(_ rect: CGRect, radius: CGFloat, tailOnRight: Bool) -> CGPath {
    let path = CGMutablePath()
    let x = rect.minX, y = rect.minY, right = rect.maxX, bottom = rect.maxY
    path.move(to: CGPoint(x: x + radius, y: y))
    path.addLine(to: CGPoint(x: right - radius, y: y))
    path.addQuadCurve(to: CGPoint(x: right, y: y + radius), control: CGPoint(x: right, y: y))
    path.addLine(to: CGPoint(x: right, y: bottom - radius))
    path.addQuadCurve(to: CGPoint(x: right - radius, y: bottom), control: CGPoint(x: right, y: bottom))
    if tailOnRight {
        path.addLine(to: CGPoint(x: right - 46, y: bottom + 40))
        path.addQuadCurve(to: CGPoint(x: right - 55, y: bottom + 44),
                          control: CGPoint(x: right - 44, y: bottom + 49))
        path.addLine(to: CGPoint(x: right - 128, y: bottom))
    }
    path.addLine(to: CGPoint(x: x + (tailOnRight ? radius : 128), y: bottom))
    if !tailOnRight {
        path.addLine(to: CGPoint(x: x + 55, y: bottom + 44))
        path.addQuadCurve(to: CGPoint(x: x + 46, y: bottom + 40),
                          control: CGPoint(x: x + 44, y: bottom + 49))
        path.addLine(to: CGPoint(x: x + radius, y: bottom))
    }
    path.addQuadCurve(to: CGPoint(x: x, y: bottom - radius), control: CGPoint(x: x, y: bottom))
    path.addLine(to: CGPoint(x: x, y: y + radius))
    path.addQuadCurve(to: CGPoint(x: x + radius, y: y), control: CGPoint(x: x, y: y))
    path.closeSubpath()
    return path
}

func stroke(_ context: CGContext, path: CGPath, color: CGColor, width: CGFloat) {
    context.addPath(path)
    context.setStrokeColor(color)
    context.setLineWidth(width)
    context.setLineCap(.round)
    context.setLineJoin(.round)
    context.strokePath()
}

func artwork() throws -> CGImage {
    guard let context = CGContext(data: nil, width: canvasSize, height: canvasSize,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        throw IconError.renderingFailed
    }
    context.translateBy(x: 0, y: CGFloat(canvasSize))
    context.scaleBy(x: 1, y: -1)
    context.setAllowsAntialiasing(true)

    // Leave a transparent margin so the tile aligns with native macOS icons.
    let tile = CGPath(roundedRect: CGRect(x: 80, y: 80, width: 864, height: 864),
                      cornerWidth: 190, cornerHeight: 190, transform: nil)
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -14), blur: 26, color: color(0x15264D, alpha: 0.27))
    context.addPath(tile)
    context.setFillColor(color(0x354BC1))
    context.fillPath()
    context.restoreGState()
    gradient(context, path: tile, colors: [color(0x6887F5), color(0x455CD5), color(0x293E9F)],
             from: CGPoint(x: 130, y: 90), to: CGPoint(x: 900, y: 950))

    // Soft reflected light and a fine rim give the tile a little depth.
    context.saveGState()
    context.addPath(tile)
    context.clip()
    let glow = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                          colors: [color(0xB4EDE8, alpha: 0.24), color(0xB4EDE8, alpha: 0)] as CFArray,
                          locations: [0, 1])!
    context.drawRadialGradient(glow, startCenter: CGPoint(x: 150, y: 100), startRadius: 0,
                               endCenter: CGPoint(x: 150, y: 100), endRadius: 760, options: [])
    context.restoreGState()
    stroke(context, path: tile, color: color(0xFFFFFF, alpha: 0.22), width: 2)

    let source = bubble(CGRect(x: 204, y: 234, width: 410, height: 358), radius: 68, tailOnRight: false)
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -12), blur: 24, color: color(0x142653, alpha: 0.22))
    context.addPath(source)
    context.setFillColor(color(0xB4EEE0))
    context.fillPath()
    context.restoreGState()
    gradient(context, path: source, colors: [color(0xD1F8EC), color(0x92DFCD)],
             from: CGPoint(x: 270, y: 234), to: CGPoint(x: 560, y: 620))
    stroke(context, path: source, color: color(0xFFFFFF, alpha: 0.42), width: 2)

    let selection = CGPath(roundedRect: CGRect(x: 270, y: 279, width: 250, height: 237),
                           cornerWidth: 28, cornerHeight: 28, transform: nil)
    context.addPath(selection)
    context.setFillColor(color(0x1D736F, alpha: 0.08))
    context.fillPath()

    let letter = CGMutablePath()
    letter.move(to: CGPoint(x: 303, y: 453))
    letter.addLine(to: CGPoint(x: 391, y: 304))
    letter.addLine(to: CGPoint(x: 479, y: 453))
    letter.move(to: CGPoint(x: 331, y: 408))
    letter.addLine(to: CGPoint(x: 451, y: 408))
    stroke(context, path: letter, color: color(0x244D65), width: 27)

    // The selection underline is the distinctive detail behind “划词”.
    let underline = CGMutablePath()
    underline.move(to: CGPoint(x: 291, y: 490))
    underline.addLine(to: CGPoint(x: 491, y: 490))
    stroke(context, path: underline, color: color(0x308C83), width: 8)
    for x: CGFloat in [291, 491] {
        context.addEllipse(in: CGRect(x: x - 7, y: 483, width: 14, height: 14))
        context.setFillColor(color(0x308C83))
        context.fillPath()
    }

    let translation = bubble(CGRect(x: 421, y: 498, width: 404, height: 298), radius: 65, tailOnRight: true)
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -14), blur: 26, color: color(0x102357, alpha: 0.28))
    context.addPath(translation)
    context.setFillColor(color(0xFFFFFF))
    context.fillPath()
    context.restoreGState()
    gradient(context, path: translation, colors: [color(0xFFFFFF), color(0xEEF3FF)],
             from: CGPoint(x: 520, y: 498), to: CGPoint(x: 760, y: 840))
    stroke(context, path: translation, color: color(0xFFFFFF, alpha: 0.65), width: 2)

    // “文”, drawn geometrically so the mark is independent of installed fonts.
    let chinese = CGMutablePath()
    chinese.move(to: CGPoint(x: 611, y: 541))
    chinese.addLine(to: CGPoint(x: 636, y: 563))
    chinese.move(to: CGPoint(x: 536, y: 590))
    chinese.addLine(to: CGPoint(x: 710, y: 590))
    chinese.move(to: CGPoint(x: 572, y: 615))
    chinese.addCurve(to: CGPoint(x: 713, y: 740),
                     control1: CGPoint(x: 594, y: 679), control2: CGPoint(x: 648, y: 718))
    chinese.move(to: CGPoint(x: 673, y: 615))
    chinese.addCurve(to: CGPoint(x: 534, y: 740),
                     control1: CGPoint(x: 651, y: 679), control2: CGPoint(x: 599, y: 718))
    stroke(context, path: chinese, color: color(0x354DB3), width: 25)

    guard let image = context.makeImage() else { throw IconError.renderingFailed }
    return image
}

func writePNG(_ image: CGImage, size: Int, to url: URL) throws {
    guard let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
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
