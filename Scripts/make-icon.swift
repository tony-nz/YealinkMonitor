#!/usr/bin/env swift
//
// Renders build/AppIcon.icns.
//
// The artwork is drawn from paths at every size rather than downscaled from one
// bitmap, so the 16pt and 32pt variants stay crisp instead of turning to mush.
// Shapes are hand-drawn: SF Symbols are licensed for UI use, not app icons.
//
// Usage: swift Scripts/make-icon.swift

import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// MARK: - Palette

/// Teal, matching Yealink's brand accent, deepening towards the bottom so the
/// icon reads as a solid object rather than a flat swatch.
let topColor = CGColor(red: 0.24, green: 0.82, blue: 0.71, alpha: 1)
let bottomColor = CGColor(red: 0.02, green: 0.44, blue: 0.51, alpha: 1)
let handsetColor = CGColor(red: 1, green: 1, blue: 1, alpha: 1)

// MARK: - Drawing

/// A rounded rectangle with the corner radius macOS app icons use.
func squirclePath(in rect: CGRect) -> CGPath {
    CGPath(
        roundedRect: rect,
        cornerWidth: rect.width * 0.2237,
        cornerHeight: rect.height * 0.2237,
        transform: nil
    )
}

/// A telephone handset.
///
/// A swept arc: chunky through the handle, flaring modestly at the ends, with
/// the end faces rounded off. Getting this right is a matter of proportion --
/// too thin a handle and it reads as a crescent, too straight and it reads as a
/// dumbbell.
func handsetPath(size s: CGFloat) -> CGPath {
    let centre = CGPoint(x: 0.5 * s, y: 0.5 * s)
    let radius = 0.255 * s
    let startAngle = 192.0 * .pi / 180
    let endAngle = 348.0 * .pi / 180
    let midHalfWidth = 0.088 * s
    let endHalfWidth = 0.128 * s
    let steps = 96

    func halfWidth(at t: CGFloat) -> CGFloat {
        let toward = pow(abs(2 * t - 1), 2.0)
        return midHalfWidth + (endHalfWidth - midHalfWidth) * toward
    }

    func centreLine(_ t: CGFloat) -> CGPoint {
        let angle = startAngle + (endAngle - startAngle) * t
        return CGPoint(x: centre.x + cos(angle) * radius, y: centre.y + sin(angle) * radius)
    }

    func point(_ t: CGFloat, offset: CGFloat) -> CGPoint {
        let angle = startAngle + (endAngle - startAngle) * t
        let r = radius + offset
        return CGPoint(x: centre.x + cos(angle) * r, y: centre.y + sin(angle) * r)
    }

    let path = CGMutablePath()
    for step in 0...steps {
        let t = CGFloat(step) / CGFloat(steps)
        let p = point(t, offset: halfWidth(at: t))
        if step == 0 { path.move(to: p) } else { path.addLine(to: p) }
    }
    for step in stride(from: steps, through: 0, by: -1) {
        let t = CGFloat(step) / CGFloat(steps)
        path.addLine(to: point(t, offset: -halfWidth(at: t)))
    }
    path.closeSubpath()

    // Round the earpiece and mouthpiece faces; a flat radial cut looks like the
    // shape was sliced rather than finished.
    for t in [CGFloat(0), CGFloat(1)] {
        let end = centreLine(t)
        let capRadius = halfWidth(at: t)
        path.addEllipse(in: CGRect(
            x: end.x - capRadius, y: end.y - capRadius,
            width: capRadius * 2, height: capRadius * 2
        ))
    }

    // Rotate, and pull in from the edges so the glyph sits within the plate
    // rather than crowding its corners.
    let scale: CGFloat = 0.88
    var transform = CGAffineTransform(translationX: centre.x, y: centre.y)
        .rotated(by: .pi * 40 / 180)
        .scaledBy(x: scale, y: scale)
        .translatedBy(x: -centre.x, y: -centre.y)
    return path.copy(using: &transform) ?? path
}

func renderIcon(size: Int) -> CGImage? {
    let s = CGFloat(size)
    guard let context = CGContext(
        data: nil,
        width: size,
        height: size,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }

    context.setShouldAntialias(true)
    context.interpolationQuality = .high

    // macOS icons sit inset within their canvas rather than bleeding to the edge.
    let inset = s * 0.055
    let plate = CGRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)

    context.saveGState()
    context.addPath(squirclePath(in: plate))
    context.clip()
    if let gradient = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [topColor, bottomColor] as CFArray,
        locations: [0, 1]
    ) {
        context.drawLinearGradient(
            gradient,
            start: CGPoint(x: 0, y: plate.maxY),
            end: CGPoint(x: 0, y: plate.minY),
            options: []
        )
    }
    // A soft highlight across the top third, so the surface reads as curved.
    context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.13))
    context.fillEllipse(in: CGRect(
        x: -s * 0.25, y: s * 0.58, width: s * 1.5, height: s * 0.75
    ))
    context.restoreGState()

    // The handset, with a drop shadow to lift it off the plate. Omitted at the
    // smallest sizes, where it only muddies the silhouette.
    context.saveGState()
    if size >= 64 {
        context.setShadow(
            offset: CGSize(width: 0, height: -s * 0.012),
            blur: s * 0.03,
            color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.30)
        )
    }
    context.setFillColor(handsetColor)
    context.addPath(handsetPath(size: s))
    context.fillPath()
    context.restoreGState()

    return context.makeImage()
}

func write(_ image: CGImage, to url: URL) throws {
    guard let destination = CGImageDestinationCreateWithURL(
        url as CFURL, UTType.png.identifier as CFString, 1, nil
    ) else {
        throw NSError(domain: "make-icon", code: 1)
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
        throw NSError(domain: "make-icon", code: 2)
    }
}

// MARK: - Main

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let iconset = root.appending(path: "build/AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

// The exact set `iconutil` expects.
let variants: [(name: String, size: Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]

for variant in variants {
    guard let image = renderIcon(size: variant.size) else {
        FileHandle.standardError.write(Data("failed to render \(variant.name)\n".utf8))
        exit(1)
    }
    try write(image, to: iconset.appending(path: "\(variant.name).png"))
}

print("wrote \(variants.count) sizes to \(iconset.path)")
