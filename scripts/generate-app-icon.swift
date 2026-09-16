#!/usr/bin/env swift
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

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

func p(_ x: CGFloat, _ y: CGFloat, _ s: CGFloat) -> CGPoint {
    CGPoint(x: x * s, y: y * s)
}

func makeGradient(_ colors: [CGColor], space: CGColorSpace) -> CGGradient {
    CGGradient(colorsSpace: space, colors: colors as CFArray, locations: nil)!
}

func renderIcon(size: Int, path: String) throws {
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    guard let context = CGContext(
        data: nil,
        width: size,
        height: size,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
    ) else {
        throw NSError(domain: "PlaceDriftIcon", code: 1)
    }

    context.setAllowsAntialiasing(true)
    context.setShouldAntialias(true)

    let s = CGFloat(size) / 1024.0
    let rect = CGRect(x: 0, y: 0, width: CGFloat(size), height: CGFloat(size))

    // Deep navy/teal field that stays readable on both light and dark home screens.
    let background = makeGradient([
        CGColor(red: 0.035, green: 0.055, blue: 0.105, alpha: 1),
        CGColor(red: 0.035, green: 0.22, blue: 0.31, alpha: 1)
    ], space: colorSpace)
    context.saveGState()
    context.addRect(rect)
    context.clip()
    context.drawLinearGradient(
        background,
        start: p(90, 950, s),
        end: p(940, 90, s),
        options: []
    )
    context.restoreGState()

    // Soft cyan halo around the moving pin.
    let halo = makeGradient([
        CGColor(red: 0.11, green: 0.84, blue: 0.92, alpha: 0.28),
        CGColor(red: 0.10, green: 0.45, blue: 0.95, alpha: 0.0)
    ], space: colorSpace)
    let haloCenter = p(565, 510, s)
    context.drawRadialGradient(
        halo,
        startCenter: haloCenter,
        startRadius: 0,
        endCenter: haloCenter,
        endRadius: 380 * s,
        options: [.drawsAfterEndLocation]
    )

    // Three motion trails: the "drift" part of the mark.
    context.setStrokeColor(CGColor(red: 0.20, green: 0.86, blue: 0.96, alpha: 0.95))
    context.setLineCap(.round)
    context.setLineWidth(34 * s)
    for (y, endX) in [(620.0, 535.0), (500.0, 470.0), (380.0, 400.0)] {
        let path = CGMutablePath()
        path.move(to: p(155, CGFloat(y), s))
        path.addCurve(
            to: p(CGFloat(endX), CGFloat(y) + 5, s),
            control1: p(245, CGFloat(y) + 40, s),
            control2: p(350, CGFloat(y) - 34, s)
        )
        context.addPath(path)
        context.strokePath()
    }

    // Main map pin, intentionally leaning forward into the trails.
    let pin = CGMutablePath()
    pin.move(to: p(650, 175, s))
    pin.addCurve(to: p(815, 565, s), control1: p(725, 315, s), control2: p(815, 420, s))
    pin.addCurve(to: p(620, 800, s), control1: p(815, 695, s), control2: p(730, 800, s))
    pin.addCurve(to: p(425, 565, s), control1: p(510, 800, s), control2: p(425, 695, s))
    pin.addCurve(to: p(650, 175, s), control1: p(425, 420, s), control2: p(550, 295, s))
    pin.closeSubpath()

    let pinGradient = makeGradient([
        CGColor(red: 0.94, green: 1.0, blue: 1.0, alpha: 1),
        CGColor(red: 0.47, green: 0.94, blue: 1.0, alpha: 1)
    ], space: colorSpace)
    context.saveGState()
    context.addPath(pin)
    context.clip()
    context.drawLinearGradient(
        pinGradient,
        start: p(470, 760, s),
        end: p(760, 265, s),
        options: []
    )
    context.restoreGState()

    context.setFillColor(CGColor(red: 0.035, green: 0.16, blue: 0.24, alpha: 1))
    context.fillEllipse(in: CGRect(x: 535*s, y: 535*s, width: 170*s, height: 170*s))

    let arrow = CGMutablePath()
    arrow.move(to: p(592, 610, s))
    arrow.addLine(to: p(690, 665, s))
    arrow.addLine(to: p(642, 566, s))
    arrow.closeSubpath()
    context.addPath(arrow)
    context.setFillColor(CGColor(red: 0.20, green: 0.86, blue: 0.96, alpha: 1))
    context.fillPath()

    guard let image = context.makeImage() else {
        throw NSError(domain: "PlaceDriftIcon", code: 2)
    }

    let url = URL(fileURLWithPath: path) as CFURL
    guard let destination = CGImageDestinationCreateWithURL(
        url,
        UTType.png.identifier as CFString,
        1,
        nil
    ) else {
        throw NSError(domain: "PlaceDriftIcon", code: 3)
    }

    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
        throw NSError(domain: "PlaceDriftIcon", code: 4)
    }
}

for spec in specs {
    let destination = (outputDirectory as NSString).appendingPathComponent(spec.filename)
    try renderIcon(size: spec.pixels, path: destination)
}

print("Generated PlaceDrift app icons in \(outputDirectory)")
