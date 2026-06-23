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

func colors(for variant: Variant) -> (bgColors: [CGColor]?, ink: CGColor, line: CGColor?) {
    switch variant {
    case .light:
        // Deep indigo → violet gradient, white book ink
        let c1 = CGColor(red: 0.224, green: 0.176, blue: 0.533, alpha: 1.0)
        let c2 = CGColor(red: 0.280, green: 0.220, blue: 0.670, alpha: 1.0)
        return ([c1, c2], CGColor(gray: 0.98, alpha: 1.0), CGColor(red: 0.224, green: 0.176, blue: 0.533, alpha: 1.0))
    case .dark:
        // Very dark midnight indigo gradient, white book ink
        let c1 = CGColor(red: 0.114, green: 0.086, blue: 0.267, alpha: 1.0)
        let c2 = CGColor(red: 0.180, green: 0.140, blue: 0.427, alpha: 1.0)
        return ([c1, c2], CGColor(gray: 0.95, alpha: 1.0), CGColor(red: 0.114, green: 0.086, blue: 0.267, alpha: 1.0))
    case .tinted:
        // Transparent background, light ink
        return (nil, CGColor(gray: 0.92, alpha: 1.0), nil)
    }
}

/// A quadrilateral with lightly rounded corners.
func roundedQuad(p0: CGPoint, p1: CGPoint, p2: CGPoint, p3: CGPoint, radius: CGFloat) -> CGPath {
    let pts = [p0, p1, p2, p3]
    let path = CGMutablePath()
    for i in 0..<4 {
        let curr = pts[i]
        let prev = pts[(i + 3) % 4]
        let next = pts[(i + 1) % 4]
        let toPrev = normalize(CGPoint(x: prev.x - curr.x, y: prev.y - curr.y))
        let toNext = normalize(CGPoint(x: next.x - curr.x, y: next.y - curr.y))
        let start = CGPoint(x: curr.x + toPrev.x * radius, y: curr.y + toPrev.y * radius)
        let end = CGPoint(x: curr.x + toNext.x * radius, y: curr.y + toNext.y * radius)
        if i == 0 { path.move(to: start) } else { path.addLine(to: start) }
        path.addQuadCurve(to: end, control: curr)
    }
    path.closeSubpath()
    return path
}

func normalize(_ p: CGPoint) -> CGPoint {
    let len = max(1, (p.x * p.x + p.y * p.y).squareRoot())
    return CGPoint(x: p.x / len, y: p.y / len)
}

/// A clean open book: two solid pages meeting at a spine, with thin
/// background-coloured text lines cut into each page. Pages are flat
/// quadrilaterals (straight edges) with only a slight fan at the spine.
func drawBook(_ ctx: CGContext, ink: CGColor, bgColors: [CGColor]?, line: CGColor?) {
    let bookW = width * 0.60
    let bookH = height * 0.46
    let cx = width / 2
    let cy = height / 2
    let halfW = bookW / 2
    let halfH = bookH / 2
    let fan: CGFloat = bookH * 0.06    // pages a touch taller at the outer edge
    let spineDrop: CGFloat = bookH * 0.05  // slight dip at the spine
    let spineGap: CGFloat = width * 0.018
    let corner: CGFloat = width * 0.015 // tiny corner rounding only

    // Left page — straight edges (top-left, top-spine, spine-bottom, bottom-left).
    let left = roundedQuad(
        p0: CGPoint(x: cx - halfW,    y: cy - halfH + fan),       // outer top
        p1: CGPoint(x: cx - spineGap, y: cy - halfH + spineDrop), // spine top
        p2: CGPoint(x: cx - spineGap, y: cy + halfH - spineDrop), // spine bottom
        p3: CGPoint(x: cx - halfW,    y: cy + halfH - fan),       // outer bottom
        radius: corner)

    let right = roundedQuad(
        p0: CGPoint(x: cx + spineGap, y: cy - halfH + spineDrop),
        p1: CGPoint(x: cx + halfW,    y: cy - halfH + fan),
        p2: CGPoint(x: cx + halfW,    y: cy + halfH - fan),
        p3: CGPoint(x: cx + spineGap, y: cy + halfH - spineDrop),
        radius: corner)

    // Add a beautiful soft drop shadow under the book to give it a modern 3D appearance
    ctx.setShadow(offset: CGSize(width: 0, height: -height * 0.018), blur: height * 0.025, color: CGColor(gray: 0.0, alpha: 0.35))

    ctx.setFillColor(ink)
    ctx.addPath(left)
    ctx.fillPath()
    ctx.addPath(right)
    ctx.fillPath()

    // Clear shadow for text lines cut out of the book
    ctx.setShadow(offset: .zero, blur: 0, color: nil)

    // Text lines, cut out in the background color (or cleared for tinted).
    let lineColor = line ?? CGColor(gray: 0, alpha: 1)
    let lineCount = 5
    let lineH: CGFloat = bookH * 0.045
    let gap = (bookH * 0.62) / CGFloat(lineCount)
    
    // Centered horizontal alignment for text lines within each page
    let pageWidth = halfW - spineGap
    let pagePadding = pageWidth * 0.16
    let fullLineWidth = pageWidth - (pagePadding * 2)
    
    for i in 0..<lineCount {
        let y = cy - bookH * 0.27 + CGFloat(i) * gap
        let leftW = fullLineWidth * (i == lineCount - 1 ? 0.6 : 1.0)
        let rightW = fullLineWidth * (i == lineCount - 1 ? 0.55 : 1.0)
        
        let leftX = cx - halfW + pagePadding
        let rightX = cx + spineGap + pagePadding
        
        let leftRect = CGRect(x: leftX, y: y, width: leftW, height: lineH)
        let rightRect = CGRect(x: rightX, y: y, width: rightW, height: lineH)
        
        if bgColors == nil {
            // tinted: clear the lines so they read as gaps
            ctx.setBlendMode(.clear)
            ctx.fill(leftRect); ctx.fill(rightRect)
            ctx.setBlendMode(.normal)
        } else {
            ctx.setFillColor(lineColor)
            ctx.fill(leftRect); ctx.fill(rightRect)
        }
    }

    // Spine gap is naturally created by the spacing between the left and right pages.
    // No extra vertical bar is drawn to keep the book design clean and unified.
}

func render(_ variant: Variant, to path: String) {
    let ctx = makeContext()
    let palette = colors(for: variant)
    if let bgColors = palette.bgColors {
        // Draw linear vertical gradient
        let colorsArray = bgColors as CFArray
        if let gradient = CGGradient(colorsSpace: colorSpace, colors: colorsArray, locations: nil) {
            ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: 0), end: CGPoint(x: 0, y: height), options: [])
        }
    } else {
        ctx.clear(CGRect(x: 0, y: 0, width: width, height: height))
    }
    drawBook(ctx, ink: palette.ink, bgColors: palette.bgColors, line: palette.line)

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
