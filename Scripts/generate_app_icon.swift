#!/usr/bin/env swift
// Generates a 1024x1024 PNG app icon for MyHeart:
// pink vertical gradient + centered white heart + subtle glow.
//
// Run: `swift Scripts/generate_app_icon.swift path/to/output.png`
//
// We avoid UIKit so this works as a macOS command-line script.

import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let args = CommandLine.arguments
guard args.count == 2 else {
    print("Usage: \(args[0]) <output.png>")
    exit(1)
}
let outputURL = URL(fileURLWithPath: args[1])

let size: CGFloat = 1024
let cs = CGColorSpaceCreateDeviceRGB()
guard let ctx = CGContext(
    data: nil,
    width: Int(size),
    height: Int(size),
    bitsPerComponent: 8,
    bytesPerRow: 0,
    space: cs,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
) else {
    print("Couldn't create bitmap context")
    exit(1)
}

// Pink vertical gradient background (coral → deep pink)
let bgGradient = CGGradient(
    colorsSpace: cs,
    colors: [
        CGColor(red: 1.00, green: 0.50, blue: 0.60, alpha: 1),
        CGColor(red: 0.92, green: 0.20, blue: 0.40, alpha: 1)
    ] as CFArray,
    locations: [0, 1]
)!
ctx.drawLinearGradient(
    bgGradient,
    start: CGPoint(x: 0, y: size),
    end: CGPoint(x: 0, y: 0),
    options: []
)

// Build the heart path (two cubic arcs from the bottom tip to the top notch and back)
let w: CGFloat = 640
let h: CGFloat = 580
let cx: CGFloat = size / 2
let cy: CGFloat = size / 2 - 30
let left   = cx - w/2
let right  = cx + w/2
let top    = cy + h/2
let bottom = cy - h/2

let heart = CGMutablePath()
heart.move(to: CGPoint(x: cx, y: bottom))
// Right half up to top-right bump, over to center notch
heart.addCurve(
    to: CGPoint(x: right, y: cy + h * 0.22),
    control1: CGPoint(x: cx + w * 0.18, y: bottom + h * 0.20),
    control2: CGPoint(x: right,        y: cy - h * 0.02)
)
heart.addCurve(
    to: CGPoint(x: cx, y: top - h * 0.14),
    control1: CGPoint(x: right, y: top + h * 0.06),
    control2: CGPoint(x: cx + w * 0.12, y: top + h * 0.06)
)
// Left half: notch → top-left bump → back to bottom tip
heart.addCurve(
    to: CGPoint(x: left, y: cy + h * 0.22),
    control1: CGPoint(x: cx - w * 0.12, y: top + h * 0.06),
    control2: CGPoint(x: left,          y: top + h * 0.06)
)
heart.addCurve(
    to: CGPoint(x: cx, y: bottom),
    control1: CGPoint(x: left,            y: cy - h * 0.02),
    control2: CGPoint(x: cx - w * 0.18,   y: bottom + h * 0.20)
)
heart.closeSubpath()

// Outer glow (soft shadow) — draw the heart twice, once with shadow and then clean on top
ctx.saveGState()
ctx.setShadow(offset: .zero, blur: 40, color: CGColor(red: 1, green: 1, blue: 1, alpha: 0.35))
ctx.setFillColor(CGColor(gray: 1, alpha: 1))
ctx.addPath(heart)
ctx.fillPath()
ctx.restoreGState()

// Subtle vertical gradient fill inside the heart (top whiter than bottom)
ctx.saveGState()
ctx.addPath(heart)
ctx.clip()
let heartGradient = CGGradient(
    colorsSpace: cs,
    colors: [
        CGColor(red: 1.00, green: 1.00, blue: 1.00, alpha: 1.0),
        CGColor(red: 1.00, green: 0.92, blue: 0.94, alpha: 1.0)
    ] as CFArray,
    locations: [0, 1]
)!
ctx.drawLinearGradient(
    heartGradient,
    start: CGPoint(x: 0, y: top),
    end: CGPoint(x: 0, y: bottom),
    options: []
)
ctx.restoreGState()

// Final image
guard let cgImage = ctx.makeImage(),
      let dest = CGImageDestinationCreateWithURL(outputURL as CFURL, UTType.png.identifier as CFString, 1, nil)
else {
    print("Couldn't create output destination at \(outputURL.path)")
    exit(1)
}
CGImageDestinationAddImage(dest, cgImage, nil)
guard CGImageDestinationFinalize(dest) else {
    print("Couldn't finalize PNG")
    exit(1)
}
print("Wrote \(outputURL.path)")
