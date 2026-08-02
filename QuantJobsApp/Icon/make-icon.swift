// Draws QuantJobs.icns from scratch — no image assets to keep in sync.
//
//   swift make-icon.swift <output-dir>
//
// Each size is drawn natively rather than downscaled from one master, so the
// 16pt icon stays legible instead of turning to mush.

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let outputDir = CommandLine.arguments.count > 1
    ? URL(fileURLWithPath: CommandLine.arguments[1])
    : URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent("QuantJobs.iconset")

try? FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

let space = CGColorSpaceCreateDeviceRGB()

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: space, components: [
        CGFloat((hex >> 16) & 0xFF) / 255,
        CGFloat((hex >> 8) & 0xFF) / 255,
        CGFloat(hex & 0xFF) / 255,
        alpha,
    ])!
}

/// The macOS icon grid: an 824pt rounded square centred in a 1024pt canvas.
let bodyInset: CGFloat = 100.0 / 1024.0
let cornerRatio: CGFloat = 185.0 / 824.0

func draw(size: Int) -> CGImage {
    let s = CGFloat(size)
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                        bytesPerRow: 0, space: space,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setAllowsAntialiasing(true)
    ctx.interpolationQuality = .high

    let inset = (s * bodyInset).rounded()
    let body = CGRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let radius = body.width * cornerRatio
    let shape = CGPath(roundedRect: body, cornerWidth: radius, cornerHeight: radius,
                       transform: nil)

    // Drop shadow, so the icon sits on the dock rather than floating.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.012),
                  blur: s * 0.03, color: color(0x000000, 0.35))
    ctx.addPath(shape)
    ctx.setFillColor(color(0x0F172A))
    ctx.fillPath()
    ctx.restoreGState()

    // Body gradient: slate at the top falling to near-black.
    ctx.saveGState()
    ctx.addPath(shape)
    ctx.clip()
    let bg = CGGradient(colorsSpace: space,
                        colors: [color(0x243B55), color(0x0B1220)] as CFArray,
                        locations: [0, 1])!
    ctx.drawLinearGradient(bg, start: CGPoint(x: body.minX, y: body.maxY),
                           end: CGPoint(x: body.maxX, y: body.minY), options: [])

    // Point in body-relative coordinates, y measured upward.
    func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
        CGPoint(x: body.minX + body.width * x, y: body.minY + body.height * y)
    }

    let fine = size >= 64      // detail that would only muddy the small sizes

    // Baseline grid.
    if fine {
        ctx.setStrokeColor(color(0xFFFFFF, 0.06))
        ctx.setLineWidth(max(1, s * 0.005))
        for y in [CGFloat(0.30), 0.50, 0.70] {
            ctx.move(to: p(0.10, y))
            ctx.addLine(to: p(0.90, y))
        }
        ctx.strokePath()
    }

    // The trend line — the one thing that has to read at 16pt.
    let points = [p(0.16, 0.30), p(0.37, 0.50), p(0.53, 0.395),
                  p(0.72, 0.66), p(0.855, 0.775)]

    // Soft fill under the line.
    ctx.saveGState()
    let area = CGMutablePath()
    area.move(to: p(0.16, 0.20))
    area.addLine(to: points[0])
    for pt in points.dropFirst() { area.addLine(to: pt) }
    area.addLine(to: p(0.855, 0.20))
    area.closeSubpath()
    ctx.addPath(area)
    ctx.clip()
    let fill = CGGradient(colorsSpace: space,
                          colors: [color(0x34D399, 0.42), color(0x34D399, 0.0)] as CFArray,
                          locations: [0, 1])!
    ctx.drawLinearGradient(fill, start: p(0.5, 0.78), end: p(0.5, 0.20), options: [])
    ctx.restoreGState()

    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    ctx.setLineWidth(body.width * 0.072)
    ctx.setStrokeColor(color(0x34D399))
    ctx.move(to: points[0])
    for pt in points.dropFirst() { ctx.addLine(to: pt) }
    if fine {
        ctx.setShadow(offset: .zero, blur: s * 0.02, color: color(0x34D399, 0.55))
    }
    ctx.strokePath()
    ctx.setShadow(offset: .zero, blur: 0, color: nil)

    // Nodes at each turn, and a brighter cap on the leading point.
    if fine {
        for (i, pt) in points.enumerated() {
            let r = body.width * (i == points.count - 1 ? 0.052 : 0.038)
            ctx.setFillColor(color(0x0B1220))
            ctx.fillEllipse(in: CGRect(x: pt.x - r, y: pt.y - r, width: r * 2, height: r * 2))
            ctx.setStrokeColor(color(i == points.count - 1 ? 0xA7F3D0 : 0x34D399))
            ctx.setLineWidth(body.width * 0.026)
            ctx.strokeEllipse(in: CGRect(x: pt.x - r, y: pt.y - r,
                                         width: r * 2, height: r * 2))
        }
    }

    // Top edge highlight, the usual macOS glass cue.
    ctx.addPath(shape)
    ctx.setStrokeColor(color(0xFFFFFF, 0.14))
    ctx.setLineWidth(max(1, s * 0.006))
    ctx.strokePath()
    ctx.restoreGState()

    return ctx.makeImage()!
}

func write(_ image: CGImage, to url: URL) {
    guard let dest = CGImageDestinationCreateWithURL(
        url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
    CGImageDestinationAddImage(dest, image, nil)
    CGImageDestinationFinalize(dest)
}

// name, pixel size
let variants: [(String, Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]

for (name, px) in variants {
    write(draw(size: px), to: outputDir.appendingPathComponent("\(name).png"))
}
print("wrote \(variants.count) sizes to \(outputDir.path)")
