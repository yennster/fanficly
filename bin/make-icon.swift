#!/usr/bin/env swift
// Generates a 1024x1024 Fanficly app icon as PNG.
// Usage: bin/make-icon.swift [out.png]
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import AppKit

let outPath = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "Fanficly/Assets.xcassets/AppIcon.appiconset/icon-1024.png"

let size = 1024
let width = CGFloat(size)
let height = CGFloat(size)

let colorSpace = CGColorSpaceCreateDeviceRGB()
guard let ctx = CGContext(
    data: nil, width: size, height: size,
    bitsPerComponent: 8, bytesPerRow: 0,
    space: colorSpace,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
) else {
    FileHandle.standardError.write("could not create CGContext\n".data(using: .utf8)!)
    exit(1)
}

func gradient(_ ctx: CGContext) {
    let colors = [
        CGColor(red: 0.69, green: 0.18, blue: 0.38, alpha: 1.0),
        CGColor(red: 0.42, green: 0.12, blue: 0.55, alpha: 1.0),
    ] as CFArray
    guard let grad = CGGradient(colorsSpace: colorSpace, colors: colors, locations: [0, 1]) else { return }
    ctx.drawLinearGradient(grad,
        start: CGPoint(x: 0, y: height),
        end: CGPoint(x: width, y: 0),
        options: [])
}

func drawOpenBook(_ ctx: CGContext) {
    let bookW = width * 0.78
    let bookH = height * 0.54
    let cx = width / 2
    let cy = height / 2 + height * 0.02
    let halfW = bookW / 2
    let halfH = bookH / 2
    let tilt: CGFloat = 24

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -18), blur: 42,
                  color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.32))

    let cream = CGColor(red: 0.99, green: 0.97, blue: 0.92, alpha: 1.0)
    let edge  = CGColor(red: 0.86, green: 0.78, blue: 0.66, alpha: 1.0)

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

    ctx.setFillColor(cream)
    ctx.addPath(leftPage)
    ctx.fillPath()
    ctx.setFillColor(cream)
    ctx.addPath(rightPage)
    ctx.fillPath()

    ctx.restoreGState()

    ctx.setStrokeColor(edge)
    ctx.setLineWidth(3)
    ctx.addPath(leftPage)
    ctx.strokePath()
    ctx.addPath(rightPage)
    ctx.strokePath()

    let spineDarker = CGColor(red: 0.30, green: 0.08, blue: 0.40, alpha: 1.0)
    ctx.setStrokeColor(spineDarker)
    ctx.setLineWidth(6)
    ctx.move(to: CGPoint(x: cx, y: cy - halfH + 4))
    ctx.addLine(to: CGPoint(x: cx, y: cy + halfH - 4))
    ctx.strokePath()

    let textColor = CGColor(red: 0.45, green: 0.30, blue: 0.20, alpha: 0.55)
    ctx.setFillColor(textColor)
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

func drawFAccent(_ ctx: CGContext) {
    // Small F watermark on the left page, scrabble-tile style.
    let badgeSize: CGFloat = 130
    let bx = width * 0.20
    let by = height * 0.62
    let badge = CGRect(x: bx, y: by, width: badgeSize, height: badgeSize)
    ctx.setFillColor(CGColor(red: 0.42, green: 0.12, blue: 0.55, alpha: 1.0))
    ctx.addPath(CGPath(roundedRect: badge, cornerWidth: 24, cornerHeight: 24, transform: nil))
    ctx.fillPath()

    let attrs: [NSAttributedString.Key: Any] = [
        .font: NSFont(name: "New York Bold", size: 96) ?? NSFont.systemFont(ofSize: 96, weight: .heavy),
        .foregroundColor: NSColor(srgbRed: 0.99, green: 0.97, blue: 0.92, alpha: 1.0),
    ]
    let s = NSAttributedString(string: "F", attributes: attrs)
    let line = CTLineCreateWithAttributedString(s)
    let bounds = CTLineGetImageBounds(line, ctx)
    let x = badge.midX - bounds.width / 2 - bounds.origin.x
    let y = badge.midY - bounds.height / 2 - bounds.origin.y
    ctx.textPosition = CGPoint(x: x, y: y)
    CTLineDraw(line, ctx)
}

gradient(ctx)
drawOpenBook(ctx)
drawFAccent(ctx)

guard let image = ctx.makeImage() else {
    FileHandle.standardError.write("makeImage failed\n".data(using: .utf8)!)
    exit(1)
}
let url = URL(fileURLWithPath: outPath)
let dir = url.deletingLastPathComponent().path
try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
    FileHandle.standardError.write("destination create failed\n".data(using: .utf8)!)
    exit(1)
}
CGImageDestinationAddImage(dest, image, nil)
if !CGImageDestinationFinalize(dest) {
    FileHandle.standardError.write("destination finalize failed\n".data(using: .utf8)!)
    exit(1)
}
print("wrote \(outPath)")
