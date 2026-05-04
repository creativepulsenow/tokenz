#!/usr/bin/env swift
//
// Builds docs/screenshot.png by extracting two regions from docs/_source.png
// (the menu-bar pill, and the popover) and laying them out on a clean black
// canvas. Avoids the translucent-material bleed problem by simply not
// including the surrounding pixels at all.
//

import CoreGraphics
import Foundation
import ImageIO
import AppKit

// MARK: - Source

let srcURL = URL(fileURLWithPath: "docs/_source.png")
guard let imgSrc = CGImageSourceCreateWithURL(srcURL as CFURL, nil),
      let cgImg = CGImageSourceCreateImageAtIndex(imgSrc, 0, nil) else {
    fatalError("could not read docs/_source.png")
}
let SW = cgImg.width    // 672
let SH = cgImg.height   // 604

// MARK: - Source regions (visual top-left coords)

struct VRect { var x, y, w, h: Int }

// The "Claude Monitor" menu-bar pill (white circle + "30%")
let pillRect = VRect(x: 12, y: 6, w: 130, h: 38)

// The popover. Trim aggressively past the translucent edge (where terminal
// text bleeds through the popover material). The left/right insets here are
// tuned to land on the popover's solid interior.
let popoverRect = VRect(x: 30, y: 86, w: 612, h: 498)

// MARK: - Output canvas

let pad: Int = 24                                // outer padding
let gap: Int = 14                                // gap between pill and popover
let CW = popoverRect.w + pad * 2                 // 626 + 48 = 674
let CH = pillRect.h + gap + popoverRect.h + pad * 2  // 38 + 14 + 510 + 48 = 610

let cs = CGColorSpaceCreateDeviceRGB()
guard let ctx = CGContext(
    data: nil, width: CW, height: CH,
    bitsPerComponent: 8, bytesPerRow: 0,
    space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
) else { fatalError("ctx") }

// Fill canvas with solid black
ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
ctx.fill(CGRect(x: 0, y: 0, width: CW, height: CH))

// MARK: - Helpers

/// Crop a CGImage by a visual (top-left origin) rect. CGImage.cropping uses
/// pixel coordinates (origin top-left), not CG-context coordinates.
func crop(_ img: CGImage, _ r: VRect) -> CGImage {
    return img.cropping(to: CGRect(x: r.x, y: r.y, width: r.w, height: r.h))!
}

/// Draw a CGImage at a visual (top-left origin) point inside the output canvas.
func drawAt(_ img: CGImage, vx: Int, vy: Int) {
    let w = img.width
    let h = img.height
    let cgY = CH - vy - h
    ctx.draw(img, in: CGRect(x: vx, y: cgY, width: w, height: h))
}

// MARK: - Compose

let pillImg = crop(cgImg, pillRect)
let popoverImg = crop(cgImg, popoverRect)

// Pill: top-left, padded
drawAt(pillImg, vx: pad, vy: pad)

// Popover: below the pill with `gap`
let popX = pad
let popY = pad + pillRect.h + gap
drawAt(popoverImg, vx: popX, vy: popY)

// The popover material is translucent at its outer edges, so terminal text
// can bleed through inside the crop. Paint a thin strip in popover-matching
// color over the inner edges to neutralize that, staying clear of the
// rounded corners and the popover content.
let popoverMaterial = CGColor(red: 32/255, green: 32/255, blue: 36/255, alpha: 1.0)
ctx.setFillColor(popoverMaterial)

func paintInPopover(vx: Int, vy: Int, vw: Int, vh: Int) {
    ctx.setFillColor(popoverMaterial)
    ctx.fill(CGRect(x: vx, y: CH - vy - vh, width: vw, height: vh))
}

// Right inner edge strip (kills "MC.." bleed)
paintInPopover(
    vx: popX + popoverRect.w - 14,
    vy: popY + 22,
    vw: 12,
    vh: popoverRect.h - 44
)
// Left inner edge strip — symmetry insurance
paintInPopover(
    vx: popX + 2,
    vy: popY + 22,
    vw: 12,
    vh: popoverRect.h - 44
)

// MARK: - Output

guard let out = ctx.makeImage() else { fatalError("makeImage") }
guard let dest = CGImageDestinationCreateWithURL(
    URL(fileURLWithPath: "docs/screenshot.png") as CFURL,
    "public.png" as CFString, 1, nil
) else { fatalError("dest") }
CGImageDestinationAddImage(dest, out, nil)
guard CGImageDestinationFinalize(dest) else { fatalError("finalize") }
print("wrote docs/screenshot.png (\(CW)x\(CH))")
