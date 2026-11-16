#!/usr/bin/env swift
// Draws the app icon and writes every size into AppIcon.appiconset.
// Usage: swift scripts/make-icon.swift   (from the repo root)

import AppKit

let outDir = "IBKR Swift/Assets.xcassets/AppIcon.appiconset"
let canvas: CGFloat = 1024

func draw(_ ctx: CGContext) {
    let s = canvas
    // macOS icon grid: 824pt body centred in the 1024 canvas.
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let shape = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)

    // Drop shadow under the body.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28,
                  color: CGColor(gray: 0, alpha: 0.35))
    ctx.addPath(shape)
    ctx.setFillColor(CGColor(red: 0.05, green: 0.09, blue: 0.20, alpha: 1))
    ctx.fillPath()
    ctx.restoreGState()

    // Background gradient, clipped to the body.
    ctx.saveGState()
    ctx.addPath(shape)
    ctx.clip()
    let bg = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [
        CGColor(red: 0.10, green: 0.17, blue: 0.36, alpha: 1),
        CGColor(red: 0.03, green: 0.06, blue: 0.15, alpha: 1),
    ] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(bg, start: CGPoint(x: 0, y: body.maxY),
                           end: CGPoint(x: 0, y: body.minY), options: [])

    // Faint chart grid.
    ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.07))
    ctx.setLineWidth(4)
    for i in 1...4 {
        let y = body.minY + body.height * CGFloat(i) / 5
        ctx.move(to: CGPoint(x: body.minX, y: y))
        ctx.addLine(to: CGPoint(x: body.maxX, y: y))
    }
    ctx.strokePath()

    // Candlesticks trending up: (x, low, open, close, high) in body-relative 0...1.
    let green = CGColor(red: 0.20, green: 0.84, blue: 0.49, alpha: 1)
    let red = CGColor(red: 0.96, green: 0.33, blue: 0.36, alpha: 1)
    let candles: [(CGFloat, CGFloat, CGFloat, CGFloat, CGFloat)] = [
        (0.20, 0.18, 0.24, 0.38, 0.44),
        (0.35, 0.28, 0.40, 0.32, 0.46),
        (0.50, 0.30, 0.34, 0.54, 0.60),
        (0.65, 0.44, 0.52, 0.68, 0.74),
        (0.80, 0.60, 0.66, 0.84, 0.88),
    ]
    func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
        CGPoint(x: body.minX + body.width * x, y: body.minY + body.height * y)
    }
    let w = body.width * 0.085
    for (x, low, open, close, high) in candles {
        let color = close >= open ? green : red
        ctx.setStrokeColor(color)
        ctx.setFillColor(color)
        ctx.setLineWidth(12)
        ctx.setLineCap(.round)
        ctx.move(to: pt(x, low))
        ctx.addLine(to: pt(x, high))
        ctx.strokePath()
        let top = pt(x, max(open, close)), bottom = pt(x, min(open, close))
        let r = CGRect(x: top.x - w / 2, y: bottom.y, width: w, height: top.y - bottom.y)
        ctx.addPath(CGPath(roundedRect: r, cornerWidth: 10, cornerHeight: 10, transform: nil))
        ctx.fillPath()
    }

    // Trend line with a glow, ending in a dot.
    let line = [pt(0.12, 0.26), pt(0.35, 0.40), pt(0.50, 0.46), pt(0.65, 0.62), pt(0.88, 0.80)]
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: 24, color: CGColor(red: 0.45, green: 0.75, blue: 1, alpha: 0.9))
    ctx.setStrokeColor(CGColor(red: 0.62, green: 0.84, blue: 1, alpha: 1))
    ctx.setLineWidth(16)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    ctx.addLines(between: line)
    ctx.strokePath()
    let end = line.last!
    ctx.setFillColor(CGColor(gray: 1, alpha: 1))
    ctx.fillEllipse(in: CGRect(x: end.x - 22, y: end.y - 22, width: 44, height: 44))
    ctx.restoreGState()

    // Top sheen.
    let sheen = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [
        CGColor(gray: 1, alpha: 0.10), CGColor(gray: 1, alpha: 0),
    ] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(sheen, start: CGPoint(x: 0, y: body.maxY),
                           end: CGPoint(x: 0, y: body.midY), options: [])
    ctx.restoreGState()

    // Hairline edge.
    ctx.addPath(shape)
    ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.12))
    ctx.setLineWidth(3)
    ctx.strokePath()
    _ = s
}

func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let g = NSGraphicsContext(bitmapImageRep: rep)!
    let ctx = g.cgContext
    ctx.interpolationQuality = .high
    ctx.scaleBy(x: CGFloat(px) / canvas, y: CGFloat(px) / canvas)
    draw(ctx)
    return rep.representation(using: .png, properties: [:])!
}

var images: [[String: String]] = []
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = "icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png"
        try! render(size * scale).write(to: URL(fileURLWithPath: "\(outDir)/\(name)"))
        images.append(["idiom": "mac", "scale": "\(scale)x", "size": "\(size)x\(size)", "filename": name])
    }
}
let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
let json = try! JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
try! json.write(to: URL(fileURLWithPath: "\(outDir)/Contents.json"))
print("Wrote \(images.count) icons to \(outDir)")
