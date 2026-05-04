#!/usr/bin/env swift
//
// generate-icon.swift
// Generates Resources/Assets.xcassets/AppIcon.appiconset PNGs + Contents.json.
// Run from the repo root: swift Scripts/generate-icon.swift
//
// The icon: dark rounded-square background, multi-color gauge arc at 60%,
// small bright center dot. Visually evokes "usage indicator" without leaning
// on Anthropic's brand language.
//

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import AppKit

// MARK: - Drawing

func drawIcon(size: Int) -> CGImage? {
    let s = CGFloat(size)
    let cs = CGColorSpaceCreateDeviceRGB()
    guard let ctx = CGContext(
        data: nil,
        width: size,
        height: size,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: cs,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }

    // Rounded background
    let cornerRadius: CGFloat = s * 0.22
    let bgRect = CGRect(x: 0, y: 0, width: s, height: s)
    let bgPath = CGPath(roundedRect: bgRect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)
    ctx.addPath(bgPath)
    ctx.clip()

    // Vertical gradient (dark slate -> near-black)
    let gradColors = [
        CGColor(red: 0.13, green: 0.16, blue: 0.24, alpha: 1.0),
        CGColor(red: 0.06, green: 0.07, blue: 0.10, alpha: 1.0),
    ] as CFArray
    if let bgGrad = CGGradient(colorsSpace: cs, colors: gradColors, locations: [0.0, 1.0]) {
        ctx.drawLinearGradient(
            bgGrad,
            start: CGPoint(x: s / 2, y: s),
            end: CGPoint(x: s / 2, y: 0),
            options: []
        )
    }

    // Gauge ring geometry
    let center = CGPoint(x: s / 2, y: s / 2)
    let ringRadius = s * 0.32
    let ringWidth = s * 0.10
    let trackColor = CGColor(red: 1, green: 1, blue: 1, alpha: 0.08)

    // Background track (full circle)
    ctx.setLineWidth(ringWidth)
    ctx.setStrokeColor(trackColor)
    ctx.setLineCap(.round)
    ctx.addArc(center: center, radius: ringRadius, startAngle: 0, endAngle: .pi * 2, clockwise: false)
    ctx.strokePath()

    // Gauge arc at 60% — sweep from top, clockwise
    // CG angles: 0 = +X axis (right), CCW positive. We want to start at top (-pi/2)
    // and go clockwise 60% of full circle = 0.60 * 2pi.
    let startAngle: CGFloat = -.pi / 2
    let sweep: CGFloat = -.pi * 2 * 0.60   // negative = clockwise in CG default
    let endAngle = startAngle + sweep

    // Draw colored arc in segments to fake a gradient stroke
    // (Core Graphics can't gradient-stroke directly; segment + interp colors instead.)
    let segments = 60
    let segStops: [(CGFloat, CGFloat, CGFloat)] = [
        (0.30, 0.80, 0.45),  // green
        (1.00, 0.78, 0.20),  // amber
        (0.95, 0.45, 0.20),  // orange
        (0.95, 0.30, 0.30),  // red
    ]
    func interp(_ t: CGFloat) -> CGColor {
        let scaled = t * CGFloat(segStops.count - 1)
        let lo = Int(floor(scaled))
        let hi = min(lo + 1, segStops.count - 1)
        let f = scaled - CGFloat(lo)
        let a = segStops[lo], b = segStops[hi]
        return CGColor(
            red: a.0 + (b.0 - a.0) * f,
            green: a.1 + (b.1 - a.1) * f,
            blue: a.2 + (b.2 - a.2) * f,
            alpha: 1.0
        )
    }
    for i in 0..<segments {
        let t0 = CGFloat(i) / CGFloat(segments)
        let t1 = CGFloat(i + 1) / CGFloat(segments)
        let a0 = startAngle + sweep * t0
        let a1 = startAngle + sweep * t1
        ctx.setStrokeColor(interp(t0))
        ctx.setLineWidth(ringWidth)
        ctx.setLineCap(.round)
        ctx.addArc(center: center, radius: ringRadius, startAngle: a0, endAngle: a1, clockwise: sweep < 0)
        ctx.strokePath()
    }

    // Center dot (white, with subtle glow halo)
    let dotRadius = s * 0.075
    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.10))
    ctx.fillEllipse(in: CGRect(
        x: center.x - dotRadius * 1.8,
        y: center.y - dotRadius * 1.8,
        width: dotRadius * 3.6,
        height: dotRadius * 3.6
    ))
    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1.0))
    ctx.fillEllipse(in: CGRect(
        x: center.x - dotRadius,
        y: center.y - dotRadius,
        width: dotRadius * 2,
        height: dotRadius * 2
    ))

    // Tick at gauge head (slightly brighter cap)
    let headAngle = endAngle
    let headPoint = CGPoint(
        x: center.x + ringRadius * cos(headAngle),
        y: center.y + ringRadius * sin(headAngle)
    )
    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.95))
    let capR = ringWidth * 0.55
    ctx.fillEllipse(in: CGRect(
        x: headPoint.x - capR,
        y: headPoint.y - capR,
        width: capR * 2,
        height: capR * 2
    ))

    return ctx.makeImage()
}

// MARK: - PNG export

func writePNG(image: CGImage, to url: URL) throws {
    guard let dest = CGImageDestinationCreateWithURL(
        url as CFURL,
        UTType.png.identifier as CFString,
        1, nil
    ) else {
        throw NSError(domain: "icon", code: 1, userInfo: [NSLocalizedDescriptionKey: "failed to create destination"])
    }
    CGImageDestinationAddImage(dest, image, nil)
    if !CGImageDestinationFinalize(dest) {
        throw NSError(domain: "icon", code: 2, userInfo: [NSLocalizedDescriptionKey: "failed to finalize PNG"])
    }
}

// MARK: - Asset catalog wiring

struct IconEntry {
    let size: Int     // points
    let scale: Int    // 1 or 2
    var pixels: Int { size * scale }
    var fileName: String { "icon_\(size)x\(size)@\(scale)x.png" }
    var contentsEntry: [String: Any] {
        [
            "idiom": "mac",
            "size": "\(size)x\(size)",
            "scale": "\(scale)x",
            "filename": fileName,
        ]
    }
}

let entries: [IconEntry] = [
    IconEntry(size: 16, scale: 1),
    IconEntry(size: 16, scale: 2),
    IconEntry(size: 32, scale: 1),
    IconEntry(size: 32, scale: 2),
    IconEntry(size: 128, scale: 1),
    IconEntry(size: 128, scale: 2),
    IconEntry(size: 256, scale: 1),
    IconEntry(size: 256, scale: 2),
    IconEntry(size: 512, scale: 1),
    IconEntry(size: 512, scale: 2),
]

let fm = FileManager.default
let cwd = URL(fileURLWithPath: fm.currentDirectoryPath)
let appIconSet = cwd
    .appendingPathComponent("Resources")
    .appendingPathComponent("Assets.xcassets")
    .appendingPathComponent("AppIcon.appiconset")

try fm.createDirectory(at: appIconSet, withIntermediateDirectories: true)

// Also ensure the parent .xcassets has its Contents.json
let assetsDir = cwd
    .appendingPathComponent("Resources")
    .appendingPathComponent("Assets.xcassets")
let assetsContents: [String: Any] = [
    "info": ["version": 1, "author": "xcode"]
]
let assetsContentsURL = assetsDir.appendingPathComponent("Contents.json")
try JSONSerialization.data(withJSONObject: assetsContents, options: [.prettyPrinted])
    .write(to: assetsContentsURL)

for e in entries {
    guard let img = drawIcon(size: e.pixels) else {
        FileHandle.standardError.write(Data("failed to draw \(e.pixels)\n".utf8))
        exit(1)
    }
    let url = appIconSet.appendingPathComponent(e.fileName)
    try writePNG(image: img, to: url)
    print("wrote \(url.lastPathComponent) (\(e.pixels)px)")
}

let contents: [String: Any] = [
    "images": entries.map { $0.contentsEntry },
    "info": ["version": 1, "author": "xcode"],
]
let contentsURL = appIconSet.appendingPathComponent("Contents.json")
try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted])
    .write(to: contentsURL)
print("wrote Contents.json")
