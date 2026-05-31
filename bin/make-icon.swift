#!/usr/bin/env swift
// Generates Fanficly app icon variants:
//   icon-1024.png         — light/default (gradient bg)
//   icon-1024-dark.png    — dark mode (transparent bg, lighter book)
//   icon-1024-tinted.png  — iOS 18 tinted (grayscale on transparent bg)
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

func paintBackground(_ ctx: CGContext, _ variant: Variant) {
    switch variant {
    case .light:
        let colors = [
            CGColor(red: 0.69, green: 0.18, blue: 0.38, alpha: 1.0),
            CGColor(red: 0.42, green: 0.12, blue: 0.55, alpha: 1.0),
        ] as CFArray
        guard let grad = CGGradient(colorsSpace: colorSpace, colors: colors, locations: [0, 1]) else { return }
        ctx.drawLinearGradient(grad,
            start: CGPoint(x: 0, y: height),
            end: CGPoint(x: width, y: 0),
            options: [])
    case .dark, .tinted:
        // Leave transparent. iOS composites onto its own dark backing.
        ctx.clear(CGRect(x: 0, y: 0, width: width, height: height))
    }
}

func colors(for variant: Variant) -> (pageFill: CGColor, pageStroke: CGColor, spine: CGColor, text: CGColor) {
    switch variant {
    case .light:
        return (
            pageFill:   CGColor(red: 0.99, green: 0.97, blue: 0.92, alpha: 1.0),
            pageStroke: CGColor(red: 0.86, green: 0.78, blue: 0.66, alpha: 1.0),
            spine:      CGColor(red: 0.30, green: 0.08, blue: 0.40, alpha: 1.0),
            text:       CGColor(red: 0.45, green: 0.30, blue: 0.20, alpha: 0.55)
        )
    case .dark:
        // Cream pages stay readable on dark background, slightly dimmer.
        return (
            pageFill:   CGColor(red: 0.97, green: 0.94, blue: 0.88, alpha: 1.0),
            pageStroke: CGColor(red: 0.75, green: 0.66, blue: 0.55, alpha: 1.0),
            spine:      CGColor(red: 0.60, green: 0.40, blue: 0.75, alpha: 1.0),
            text:       CGColor(red: 0.40, green: 0.28, blue: 0.18, alpha: 0.60)
        )
    case .tinted:
        // Grayscale-only. iOS applies the user's tint to the lightest pixels.
        return (
            pageFill:   CGColor(gray: 1.00, alpha: 1.0),
            pageStroke: CGColor(gray: 0.85, alpha: 1.0),
            spine:      CGColor(gray: 0.50, alpha: 1.0),
            text:       CGColor(gray: 0.55, alpha: 1.0)
        )
    }
}

func drawOpenBook(_ ctx: CGContext, _ variant: Variant) {
    let palette = colors(for: variant)
    let bookW = width * 0.78
    let bookH = height * 0.54
    let cx = width / 2
    let cy = height / 2 + height * 0.02
    let halfW = bookW / 2
    let halfH = bookH / 2
    let tilt: CGFloat = 24

    ctx.saveGState()
    if variant == .light {
        ctx.setShadow(offset: CGSize(width: 0, height: -18), blur: 42,
                      color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.32))
    } else if variant == .dark {
        ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 32,
                      color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.45))
    }

    let leftPage = CGMutablePath()
    leftPage.move(to:    CGPoint(x: cx - 4,            y: cy - halfH))
    leftPage.addLine(to: CGPoint(x: cx - halfW + tilt, y: cy - halfH + tilt * 0.8))
    leftPage.addQuadCurve(to: CGPoint(x: cx - halfW + tilt, y: cy + halfH - tilt * 0.8),
                          control: CGPoint(x: cx - halfW - tilt * 0.5, y: cy))
    leftPage.addLine(to: CGPoint(x: cx - 4,            y: cy + halfH))
    leftPage.closeSubpath()

    let rightPage = CGMutablePath()
    rightPage.move(to:    CGPoint(x: cx + 4,            y: cy - halfH))
    rightPage.addLine(to: CGPoint(x: cx + halfW - tilt, y: cy - halfH + tilt * 0.8))
    rightPage.addQuadCurve(to: CGPoint(x: cx + halfW - tilt, y: cy + halfH - tilt * 0.8),
                           control: CGPoint(x: cx + halfW + tilt * 0.5, y: cy))
    rightPage.addLine(to: CGPoint(x: cx + 4,            y: cy + halfH))
    rightPage.closeSubpath()

    ctx.setFillColor(palette.pageFill)
    ctx.addPath(leftPage)
    ctx.fillPath()
    ctx.setFillColor(palette.pageFill)
    ctx.addPath(rightPage)
    ctx.fillPath()

    ctx.restoreGState()

    ctx.setStrokeColor(palette.pageStroke)
    ctx.setLineWidth(3)
    ctx.addPath(leftPage)
    ctx.strokePath()
    ctx.addPath(rightPage)
    ctx.strokePath()

    ctx.setStrokeColor(palette.spine)
    ctx.setLineWidth(6)
    ctx.move(to: CGPoint(x: cx, y: cy - halfH + 4))
    ctx.addLine(to: CGPoint(x: cx, y: cy + halfH - 4))
    ctx.strokePath()

    ctx.setFillColor(palette.text)
    let lineH: CGFloat = 14
    let lineGap: CGFloat = 38
    let lineCount = 7
    let topY = cy + halfH - 60
    for i in 0..<lineCount {
        let y = topY - CGFloat(i) * lineGap
        let pageInset: CGFloat = 36
        let pageW = halfW - tilt - pageInset - 14
        let leftWidth: CGFloat = pageW * (i == lineCount - 1 ? 0.55 : (i % 3 == 0 ? 0.95 : 0.82))
        let rightWidth: CGFloat = pageW * (i == lineCount - 1 ? 0.48 : (i % 2 == 0 ? 0.9 : 0.78))
        ctx.fill(CGRect(x: cx - halfW + tilt + pageInset, y: y,
                        width: leftWidth, height: lineH))
        ctx.fill(CGRect(x: cx + 14, y: y,
                        width: rightWidth, height: lineH))
    }
}

func render(_ variant: Variant, to path: String) {
    let ctx = makeContext()
    paintBackground(ctx, variant)
    drawOpenBook(ctx, variant)

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
