#!/usr/bin/env swift

import AppKit
import Foundation

let outputURL: URL = {
    let args = CommandLine.arguments
    if let idx = args.firstIndex(of: "--output"), args.indices.contains(idx + 1) {
        return URL(fileURLWithPath: args[idx + 1])
    }
    return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent("tmp/icon-build/Kopie-1024.png")
}()

let canvas: CGFloat = 1024

func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> NSRect {
    NSRect(x: x, y: y, width: w, height: h)
}

func circleRect(cx: CGFloat, cy: CGFloat, r: CGFloat) -> NSRect {
    NSRect(x: cx - r, y: cy - r, width: r * 2, height: r * 2)
}

guard let bitmap = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: Int(canvas),
    pixelsHigh: Int(canvas),
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0,
    bitsPerPixel: 0
) else {
    fputs("Failed to allocate bitmap.\n", stderr)
    exit(1)
}

guard let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
    fputs("Failed to create graphics context.\n", stderr)
    exit(1)
}

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = context
context.imageInterpolation = .high

// Transparent canvas.
NSColor.clear.setFill()
NSBezierPath(rect: rect(0, 0, canvas, canvas)).fill()

let black = NSColor(calibratedWhite: 0.04, alpha: 1.0)
let white = NSColor.white

// Rounded-square base.
black.setFill()
NSBezierPath(roundedRect: rect(64, 64, 896, 896), xRadius: 220, yRadius: 220).fill()

// Tape spool (left).
white.setFill()
NSBezierPath(ovalIn: circleRect(cx: 356, cy: 512, r: 170)).fill()

black.setFill()
NSBezierPath(ovalIn: circleRect(cx: 356, cy: 512, r: 58)).fill()

// Three tape holes around the center to suggest a spool.
let holeRadius: CGFloat = 36
let holeOrbit: CGFloat = 92
for angleDeg in [90.0, 210.0, 330.0] {
    let radians = angleDeg * .pi / 180
    let cx = 356 + cos(radians) * holeOrbit
    let cy = 512 + sin(radians) * holeOrbit
    NSBezierPath(ovalIn: circleRect(cx: cx, cy: cy, r: holeRadius)).fill()
}

// Transcript lines (right).
white.setFill()
NSBezierPath(roundedRect: rect(532, 396, 260, 54), xRadius: 27, yRadius: 27).fill()
NSBezierPath(roundedRect: rect(532, 482, 184, 54), xRadius: 27, yRadius: 27).fill()

// Segmented line to hint speaker turns.
NSBezierPath(roundedRect: rect(532, 568, 90, 54), xRadius: 27, yRadius: 27).fill()
NSBezierPath(roundedRect: rect(646, 568, 146, 54), xRadius: 27, yRadius: 27).fill()

NSGraphicsContext.restoreGraphicsState()

guard let png = bitmap.representation(using: .png, properties: [:]) else {
    fputs("Failed to encode PNG.\n", stderr)
    exit(1)
}

do {
    try FileManager.default.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try png.write(to: outputURL)
    print("Wrote icon master PNG: \(outputURL.path)")
} catch {
    fputs("Failed to write icon PNG: \(error)\n", stderr)
    exit(1)
}
