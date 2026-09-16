#!/usr/bin/env swift
import AppKit
import Foundation

let arguments = CommandLine.arguments
let outputDirectory = arguments.count > 1 ? arguments[1] : "app/App/Assets.xcassets/AppIcon.appiconset"
let fileManager = FileManager.default
try fileManager.createDirectory(atPath: outputDirectory, withIntermediateDirectories: true)

struct IconSpec {
    let filename: String
    let pixels: Int
}

let specs: [IconSpec] = [
    .init(filename: "AppIcon-20@2x.png", pixels: 40),
    .init(filename: "AppIcon-20@3x.png", pixels: 60),
    .init(filename: "AppIcon-29@2x.png", pixels: 58),
    .init(filename: "AppIcon-29@3x.png", pixels: 87),
    .init(filename: "AppIcon-40@2x.png", pixels: 80),
    .init(filename: "AppIcon-40@3x.png", pixels: 120),
    .init(filename: "AppIcon-60@2x.png", pixels: 120),
    .init(filename: "AppIcon-60@3x.png", pixels: 180),
    .init(filename: "AppIcon-20@1x-ipad.png", pixels: 20),
    .init(filename: "AppIcon-20@2x-ipad.png", pixels: 40),
    .init(filename: "AppIcon-29@1x-ipad.png", pixels: 29),
    .init(filename: "AppIcon-29@2x-ipad.png", pixels: 58),
    .init(filename: "AppIcon-40@1x-ipad.png", pixels: 40),
    .init(filename: "AppIcon-40@2x-ipad.png", pixels: 80),
    .init(filename: "AppIcon-76@1x.png", pixels: 76),
    .init(filename: "AppIcon-76@2x.png", pixels: 152),
    .init(filename: "AppIcon-83.5@2x.png", pixels: 167),
    .init(filename: "AppIcon-1024.png", pixels: 1024),
]

func point(_ x: CGFloat, _ y: CGFloat, _ s: CGFloat) -> NSPoint {
    NSPoint(x: x * s, y: y * s)
}

func renderIcon(size: Int, path: String) throws {
    let width = size
    let height = size
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: width,
        pixelsHigh: height,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: false,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else {
        throw NSError(domain: "PlaceDriftIcon", code: 1)
    }

    rep.size = NSSize(width: width, height: height)
    guard let context = NSGraphicsContext(bitmapImageRep: rep) else {
        throw NSError(domain: "PlaceDriftIcon", code: 2)
    }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    context.shouldAntialias = true

    let s = CGFloat(size) / 1024.0
    let rect = NSRect(x: 0, y: 0, width: CGFloat(size), height: CGFloat(size))

    let background = NSGradient(colors: [
        NSColor(calibratedRed: 0.035, green: 0.055, blue: 0.105, alpha: 1),
        NSColor(calibratedRed: 0.035, green: 0.22, blue: 0.31, alpha: 1)
    ])!
    background.draw(in: rect, angle: -35)

    // Soft orbital glow behind the pin.
    let glowRect = NSRect(x: 180*s, y: 190*s, width: 664*s, height: 664*s)
    let glow = NSGradient(colors: [
        NSColor(calibratedRed: 0.11, green: 0.84, blue: 0.92, alpha: 0.30),
        NSColor(calibratedRed: 0.10, green: 0.45, blue: 0.95, alpha: 0.0)
    ])!
    glow.draw(in: NSBezierPath(ovalIn: glowRect), relativeCenterPosition: NSPoint(x: 0, y: 0))

    // Drift trails.
    let trailColor = NSColor(calibratedRed: 0.20, green: 0.86, blue: 0.96, alpha: 0.95)
    for (y, widthScale) in [(620.0, 1.0), (500.0, 0.82), (380.0, 0.62)] {
        let trail = NSBezierPath()
        trail.move(to: point(170, CGFloat(y), s))
        trail.curve(
            to: point(455 * CGFloat(widthScale) + 80, CGFloat(y) + 5, s),
            controlPoint1: point(250, CGFloat(y) + 42, s),
            controlPoint2: point(350, CGFloat(y) - 36, s)
        )
        trail.lineWidth = 34 * s
        trail.lineCapStyle = .round
        trailColor.setStroke()
        trail.stroke()
    }

    // Main map pin with a slight forward lean to imply motion.
    let pin = NSBezierPath()
    pin.move(to: point(650, 180, s))
    pin.curve(to: point(805, 565, s), controlPoint1: point(720, 315, s), controlPoint2: point(805, 420, s))
    pin.curve(to: point(620, 790, s), controlPoint1: point(805, 690, s), controlPoint2: point(725, 790, s))
    pin.curve(to: point(435, 565, s), controlPoint1: point(515, 790, s), controlPoint2: point(435, 690, s))
    pin.curve(to: point(650, 180, s), controlPoint1: point(435, 425, s), controlPoint2: point(555, 300, s))
    pin.close()

    let pinGradient = NSGradient(colors: [
        NSColor(calibratedRed: 0.92, green: 1.0, blue: 1.0, alpha: 1),
        NSColor(calibratedRed: 0.50, green: 0.94, blue: 1.0, alpha: 1)
    ])!
    pinGradient.draw(in: pin, angle: -30)

    let center = NSBezierPath(ovalIn: NSRect(x: 535*s, y: 535*s, width: 170*s, height: 170*s))
    NSColor(calibratedRed: 0.035, green: 0.16, blue: 0.24, alpha: 1).setFill()
    center.fill()

    // Small direction marker inside the pin.
    let arrow = NSBezierPath()
    arrow.move(to: point(600, 620, s))
    arrow.line(to: point(685, 660, s))
    arrow.line(to: point(642, 575, s))
    arrow.close()
    NSColor(calibratedRed: 0.20, green: 0.86, blue: 0.96, alpha: 1).setFill()
    arrow.fill()

    NSGraphicsContext.restoreGraphicsState()

    guard let data = rep.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "PlaceDriftIcon", code: 3)
    }
    try data.write(to: URL(fileURLWithPath: path))
}

for spec in specs {
    let destination = (outputDirectory as NSString).appendingPathComponent(spec.filename)
    try renderIcon(size: spec.pixels, path: destination)
}

print("Generated PlaceDrift app icons in \(outputDirectory)")
