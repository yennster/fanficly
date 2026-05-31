#!/usr/bin/env swift
// Generates a clean, monochrome open-book app icon in three variants:
//   icon-1024.png         — light: black book on white
//   icon-1024-dark.png    — dark:  white book on black
//   icon-1024-tinted.png  — tinted: light book on transparent (iOS tints it)
//
// Usage:
//   bin/make-icon.swift            -> writes all three into the asset catalog
//   bin/make-icon.swift <out.png>  -> writes only the light variant
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import AppKit

enum Variant { case light, dark, tinted }

let size = 1024
let width = CGFloat(size)
let height = CGFloat(size)
let colorSpace = CGColorSpaceCreateDeviceRGB()

func makeContext() -> CGContext {
    guard let ctx = CGContext(
        data: nil, width: size, height: size,
        bitsPerComponent: 8, bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        FileHandle.standardError.write("could not create CGContext\n".data(using: .utf8)!)
        exit(1)
    }
    return ctx
}

func colors(for variant: Variant) -> (bg: CGColor?, ink: CGColor) {
    switch variant {
    case .light:
        return (CGColor(gray: 1.0, alpha: 1.0), CGColor(gray: 0.06, alpha: 1.0))
    case .dark:
        return (CGColor(gray: 0.0, alpha: 1.0), CGColor(gray: 0.96, alpha: 1.0))
    case .tinted:
        // Transparent background; light ink so iOS tints by luminance.
        return (nil, CGColor(gray: 0.92, alpha: 1.0))
    }
}

/// A clean open book: two solid pages meeting at a spine, with thin
/// background-coloured text lines cut into each page.
func drawBook(_ ctx: CGContext, ink: CGColor, bg: CGColor?) {
    let bookW = width * 0.64
    let bookH = height * 0.46
    let cx = width / 2
    let cy = height / 2
    let halfW = bookW / 2
    let halfH = bookH / 2
    let lift: CGFloat = bookH * 0.16   // outer edges lift up
    let spineGap: CGFloat = width * 0.018

    // Left page outline.
    let left = CGMutablePath()
    left.move(to: CGPoint(x: cx - spineGap, y: cy - halfH + lift * 0.2))
    left.addCurve(to: CGPoint(x: cx - halfW, y: cy - halfH + lift),
                  control1: CGPoint(x: cx - halfW * 0.45, y: cy - halfH - lift * 0.35),
                  control2: CGPoint(x: cx - halfW * 0.8, y: cy - halfH + lift * 0.4))
    left.addLine(to: CGPoint(x: cx - halfW, y: cy + halfH - lift))
    left.addCurve(to: CGPoint(x: cx - spineGap, y: cy + halfH),
                  control1: CGPoint(x: cx - halfW * 0.8, y: cy + halfH - lift * 0.4),
                  control2: CGPoint(x: cx - halfW * 0.45, y: cy + halfH + lift * 0.2))
    left.closeSubpath()

    // Right page (mirror).
    let right = CGMutablePath()
    right.move(to: CGPoint(x: cx + spineGap, y: cy - halfH + lift * 0.2))
    right.addCurve(to: CGPoint(x: cx + halfW, y: cy - halfH + lift),
                   control1: CGPoint(x: cx + halfW * 0.45, y: cy - halfH - lift * 0.35),
                   control2: CGPoint(x: cx + halfW * 0.8, y: cy - halfH + lift * 0.4))
    right.addLine(to: CGPoint(x: cx + halfW, y: cy + halfH - lift))
    right.addCurve(to: CGPoint(x: cx + spineGap, y: cy + halfH),
                   control1: CGPoint(x: cx + halfW * 0.8, y: cy + halfH - lift * 0.4),
                   control2: CGPoint(x: cx + halfW * 0.45, y: cy + halfH + lift * 0.2))
    right.closeSubpath()

    ctx.setFillColor(ink)
    ctx.addPath(left)
    ctx.fillPath()
    ctx.addPath(right)
    ctx.fillPath()

    // Text lines, cut out in the background colour (or cleared for tinted).
    let lineColor = bg ?? CGColor(gray: 0, alpha: 1)
    let lineCount = 5
    let lineH: CGFloat = bookH * 0.045
    let gap = (bookH * 0.62) / CGFloat(lineCount)
    let inset: CGFloat = bookW * 0.10
    for i in 0..<lineCount {
        let y = cy - bookH * 0.27 + CGFloat(i) * gap
        let pageW = halfW - spineGap - inset - bookW * 0.06
        let leftW = pageW * (i == lineCount - 1 ? 0.6 : 0.95)
        let rightW = pageW * (i == lineCount - 1 ? 0.55 : 0.9)
        let leftRect = CGRect(x: cx - halfW + inset, y: y, width: leftW, height: lineH)
        let rightRect = CGRect(x: cx + spineGap + bookW * 0.06, y: y, width: rightW, height: lineH)
        if bg == nil {
            // tinted: clear the lines so they read as gaps
            ctx.setBlendMode(.clear)
            ctx.fill(leftRect); ctx.fill(rightRect)
            ctx.setBlendMode(.normal)
        } else {
            ctx.setFillColor(lineColor)
            ctx.fill(leftRect); ctx.fill(rightRect)
        }
    }

    // Spine gap.
    if bg == nil {
        ctx.setBlendMode(.clear)
        ctx.fill(CGRect(x: cx - spineGap, y: cy - halfH + 8, width: spineGap * 2, height: bookH - 16))
        ctx.setBlendMode(.normal)
    } else {
        ctx.setFillColor(lineColor)
        ctx.fill(CGRect(x: cx - spineGap, y: cy - halfH + 8, width: spineGap * 2, height: bookH - 16))
    }
}

func render(_ variant: Variant, to path: String) {
    let ctx = makeContext()
    let palette = colors(for: variant)
    if let bg = palette.bg {
        ctx.setFillColor(bg)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    } else {
        ctx.clear(CGRect(x: 0, y: 0, width: width, height: height))
    }
    drawBook(ctx, ink: palette.ink, bg: palette.bg)

    guard let image = ctx.makeImage() else {
        FileHandle.standardError.write("makeImage failed\n".data(using: .utf8)!)
        exit(1)
    }
    let url = URL(fileURLWithPath: path)
    let dir = url.deletingLastPathComponent().path
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        FileHandle.standardError.write("destination create failed for \(path)\n".data(using: .utf8)!)
        exit(1)
    }
    CGImageDestinationAddImage(dest, image, nil)
    if !CGImageDestinationFinalize(dest) {
        FileHandle.standardError.write("destination finalize failed for \(path)\n".data(using: .utf8)!)
        exit(1)
    }
    print("wrote \(path)")
}

let assetDir = "Fanficly/Assets.xcassets/AppIcon.appiconset"

if CommandLine.arguments.count > 1 {
    render(.light, to: CommandLine.arguments[1])
} else {
    render(.light,  to: "\(assetDir)/icon-1024.png")
    render(.dark,   to: "\(assetDir)/icon-1024-dark.png")
    render(.tinted, to: "\(assetDir)/icon-1024-tinted.png")
}
