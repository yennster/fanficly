#!/usr/bin/env swift
// Generates a 1024x1024 Fanficly app icon as PNG.
// Usage: swift bin/make-icon.swift > /tmp/icon.png  (or pipe target)
//        bin/make-icon.swift <out.png>
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

func drawBook(_ ctx: CGContext) {
    let bookW = width * 0.56
    let bookH = height * 0.62
    let bookX = (width - bookW) / 2
    let bookY = (height - bookH) / 2 + height * 0.02

    ctx.setShadow(offset: .init(width: 0, height: -24), blur: 48,
                  color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.35))

    let rect = CGRect(x: bookX, y: bookY, width: bookW, height: bookH)
    let bookPath = CGPath(roundedRect: rect, cornerWidth: 36, cornerHeight: 36, transform: nil)
    ctx.addPath(bookPath)
    ctx.setFillColor(CGColor(red: 0.99, green: 0.97, blue: 0.93, alpha: 1.0))
    ctx.fillPath()

    ctx.setShadow(offset: .zero, blur: 0, color: nil)

    let spineX = bookX + bookW / 2 - 4
    ctx.setStrokeColor(CGColor(red: 0.85, green: 0.78, blue: 0.66, alpha: 1.0))
    ctx.setLineWidth(6)
    ctx.move(to: CGPoint(x: spineX, y: bookY + 32))
    ctx.addLine(to: CGPoint(x: spineX, y: bookY + bookH - 32))
    ctx.strokePath()
}

func drawLetter(_ ctx: CGContext) {
    let attrs: [NSAttributedString.Key: Any] = [
        .font: NSFont(name: "New York", size: 520) ?? NSFont.systemFont(ofSize: 520, weight: .bold),
        .foregroundColor: NSColor(srgbRed: 0.42, green: 0.12, blue: 0.55, alpha: 1.0),
    ]
    let s = NSAttributedString(string: "F", attributes: attrs)
    let line = CTLineCreateWithAttributedString(s)
    let bounds = CTLineGetImageBounds(line, ctx)
    let x = (width - bounds.width) / 2 - bounds.origin.x
    let y = (height - bounds.height) / 2 - bounds.origin.y - 12
    ctx.textPosition = CGPoint(x: x, y: y)
    CTLineDraw(line, ctx)
}

func drawHeart(_ ctx: CGContext) {
    let attrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 220, weight: .heavy),
        .foregroundColor: NSColor(srgbRed: 0.96, green: 0.30, blue: 0.45, alpha: 1.0),
    ]
    let s = NSAttributedString(string: "\u{2665}", attributes: attrs)
    let line = CTLineCreateWithAttributedString(s)
    let bounds = CTLineGetImageBounds(line, ctx)
    let x = width * 0.71 - bounds.origin.x
    let y = height * 0.18 - bounds.origin.y
    ctx.textPosition = CGPoint(x: x, y: y)
    CTLineDraw(line, ctx)
}

gradient(ctx)
drawBook(ctx)
drawLetter(ctx)
// drawHeart(ctx) — Core Text glyph positioning misbehaved; clean F-on-book reads better anyway.

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
