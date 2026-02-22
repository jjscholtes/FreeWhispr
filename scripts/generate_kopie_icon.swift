#!/usr/bin/env swift

import AppKit
import Foundation

let outputURL: URL = {
    let args = CommandLine.arguments
    if let idx = args.firstIndex(of: "--output"), args.indices.contains(idx + 1) {
        return URL(fileURLWithPath: args[idx + 1])
    }
    return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent("FreeWhispr-1024.png")
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
let softWhite = NSColor(calibratedWhite: 1.0, alpha: 0.78)

// Rounded-square base.
black.setFill()
NSBezierPath(roundedRect: rect(64, 64, 896, 896), xRadius: 220, yRadius: 220).fill()

// Clear microphone glyph (left): capsule, yoke, stem, base.
let micCenterX: CGFloat = 304
let micTopY: CGFloat = 676
let micCapsuleW: CGFloat = 160
let micCapsuleH: CGFloat = 250

white.setFill()
NSBezierPath(
    roundedRect: rect(micCenterX - micCapsuleW / 2, micTopY - micCapsuleH, micCapsuleW, micCapsuleH),
    xRadius: micCapsuleW / 2,
    yRadius: micCapsuleW / 2
).fill()

// Capsule inner cut to make it read as a mic head, not a plain pill.
black.setFill()
NSBezierPath(
    roundedRect: rect(micCenterX - 34, micTopY - 206, 68, 162),
    xRadius: 34,
    yRadius: 34
).fill()

// Mic grille slit.
white.setFill()
NSBezierPath(roundedRect: rect(micCenterX - 10, micTopY - 176, 20, 102), xRadius: 10, yRadius: 10).fill()

// U-yoke (stroke).
let yoke = NSBezierPath()
yoke.lineWidth = 22
yoke.lineCapStyle = .round
yoke.appendArc(withCenter: NSPoint(x: micCenterX, y: 494), radius: 104, startAngle: 205, endAngle: 335, clockwise: false)
white.setStroke()
yoke.stroke()

// Stem + base.
white.setFill()
NSBezierPath(roundedRect: rect(micCenterX - 10, 372, 20, 76), xRadius: 10, yRadius: 10).fill()
NSBezierPath(roundedRect: rect(micCenterX - 74, 340, 148, 18), xRadius: 9, yRadius: 9).fill()

// Tiny record dot accent (top-left) to reinforce "recording".
softWhite.setFill()
NSBezierPath(ovalIn: circleRect(cx: 192, cy: 722, r: 16)).fill()

// Transcript lines (right): aligned, readable, and not "crossed out".
let lineX: CGFloat = 468
let lineR: CGFloat = 20

softWhite.setFill()
NSBezierPath(roundedRect: rect(lineX, 670, 264, 20), xRadius: 10, yRadius: 10).fill()

white.setFill()
NSBezierPath(roundedRect: rect(lineX, 606, 346, 40), xRadius: lineR, yRadius: lineR).fill()
NSBezierPath(roundedRect: rect(lineX, 550, 292, 40), xRadius: lineR, yRadius: lineR).fill()

// One split row to suggest turns, but keep clean spacing.
NSBezierPath(roundedRect: rect(lineX, 494, 122, 40), xRadius: lineR, yRadius: lineR).fill()
NSBezierPath(roundedRect: rect(lineX + 138, 494, 208, 40), xRadius: lineR, yRadius: lineR).fill()

NSBezierPath(roundedRect: rect(lineX, 438, 330, 40), xRadius: lineR, yRadius: lineR).fill()

softWhite.setFill()
NSBezierPath(roundedRect: rect(lineX, 386, 222, 20), xRadius: 10, yRadius: 10).fill()

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
