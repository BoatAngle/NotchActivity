#!/usr/bin/env swift
// Draws the app icon and writes Resources/AppIcon.icns.
//   swift Scripts/make-icon.swift            (or: make icon)
// The .icns is checked in, so this only needs to run when the design changes.

import AppKit

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let output = root.appendingPathComponent("Resources/AppIcon.icns")
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("NotchActivity-\(getpid()).iconset")
try? FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

/// Everything is laid out on a 1024-point canvas and scaled to the requested pixel size.
func render(pixels: Int) -> Data {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                        space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)

    // macOS icon grid: an 824pt rounded square centered on the canvas, with a soft drop shadow.
    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    let tilePath = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: color(0x000000, 0.35))
    ctx.addPath(tilePath)
    ctx.setFillColor(color(0x1A1033))
    ctx.fillPath()
    ctx.restoreGState()

    // Wallpaper: a dusk gradient with two soft glows.
    ctx.saveGState()
    ctx.addPath(tilePath)
    ctx.clip()
    let dusk = CGGradient(colorsSpace: space, colors: [color(0x140B2E), color(0x3B1C6B), color(0xB2386B), color(0xFF8A4C)] as CFArray,
                          locations: [0, 0.38, 0.74, 1])!
    ctx.drawLinearGradient(dusk, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
    let glow = CGGradient(colorsSpace: space, colors: [color(0xFFB36B, 0.75), color(0xFFB36B, 0)] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(glow, startCenter: CGPoint(x: 512, y: 150), startRadius: 0,
                           endCenter: CGPoint(x: 512, y: 150), endRadius: 430, options: [])
    let haze = CGGradient(colorsSpace: space, colors: [color(0x7C5CFF, 0.45), color(0x7C5CFF, 0)] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(haze, startCenter: CGPoint(x: 250, y: 760), startRadius: 0,
                           endCenter: CGPoint(x: 250, y: 760), endRadius: 420, options: [])

    // The island: hangs from the top edge, shoulders flaring into it.
    let islandWidth: CGFloat = 400, islandHeight: CGFloat = 150, shoulder: CGFloat = 28, radius: CGFloat = 62
    let left = 512 - islandWidth / 2, right = 512 + islandWidth / 2
    let top = tile.maxY, bottom = tile.maxY - islandHeight
    let island = CGMutablePath()
    island.move(to: CGPoint(x: left - shoulder, y: top))
    island.addArc(tangent1End: CGPoint(x: left, y: top), tangent2End: CGPoint(x: left, y: top - shoulder), radius: shoulder)
    island.addLine(to: CGPoint(x: left, y: bottom + radius))
    island.addArc(tangent1End: CGPoint(x: left, y: bottom), tangent2End: CGPoint(x: left + radius, y: bottom), radius: radius)
    island.addLine(to: CGPoint(x: right - radius, y: bottom))
    island.addArc(tangent1End: CGPoint(x: right, y: bottom), tangent2End: CGPoint(x: right, y: bottom + radius), radius: radius)
    island.addLine(to: CGPoint(x: right, y: top - shoulder))
    island.addArc(tangent1End: CGPoint(x: right, y: top), tangent2End: CGPoint(x: right + shoulder, y: top), radius: shoulder)
    island.closeSubpath()
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 36, color: color(0x000000, 0.5))
    ctx.addPath(island)
    ctx.setFillColor(color(0x000000))
    ctx.fillPath()
    ctx.restoreGState()

    // Inside it: a tiny album cover and a waveform, like the compact music activity.
    let midY = bottom + islandHeight / 2 - 2
    let cover = CGRect(x: left + 40, y: midY - 36, width: 72, height: 72)
    ctx.saveGState()
    ctx.addPath(CGPath(roundedRect: cover, cornerWidth: 19, cornerHeight: 19, transform: nil))
    ctx.clip()
    let art = CGGradient(colorsSpace: space, colors: [color(0xFF9F45), color(0xF0437A)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(art, start: CGPoint(x: cover.minX, y: cover.maxY), end: CGPoint(x: cover.maxX, y: cover.minY), options: [])
    ctx.restoreGState()

    let heights: [CGFloat] = [26, 60, 40, 74, 34]
    let barWidth: CGFloat = 13, gap: CGFloat = 10
    var x = right - 40 - (CGFloat(heights.count) * barWidth + CGFloat(heights.count - 1) * gap)
    for h in heights {
        let bar = CGRect(x: x, y: midY - h / 2, width: barWidth, height: h)
        ctx.saveGState()
        ctx.addPath(CGPath(roundedRect: bar, cornerWidth: barWidth / 2, cornerHeight: barWidth / 2, transform: nil))
        ctx.clip()
        ctx.drawLinearGradient(art, start: CGPoint(x: bar.minX, y: midY + 37), end: CGPoint(x: bar.minX, y: midY - 37), options: [])
        ctx.restoreGState()
        x += barWidth + gap
    }
    ctx.restoreGState()

    // A faint rim so the tile holds its edge on dark backgrounds.
    ctx.addPath(CGPath(roundedRect: tile.insetBy(dx: 2, dy: 2), cornerWidth: 183, cornerHeight: 183, transform: nil))
    ctx.setStrokeColor(color(0xFFFFFF, 0.14))
    ctx.setLineWidth(4)
    ctx.strokePath()

    let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    return rep.representation(using: .png, properties: [:])!
}

for (points, scale) in [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)] {
    let name = scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
    try render(pixels: points * scale).write(to: iconset.appendingPathComponent(name))
}

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", output.path]
try iconutil.run()
iconutil.waitUntilExit()
try? FileManager.default.removeItem(at: iconset)
print(iconutil.terminationStatus == 0 ? "Wrote \(output.path)" : "iconutil failed")
exit(iconutil.terminationStatus)
