#!/usr/bin/env swift
//
// GenerateIcon.swift
//
// Generates every PNG in Sources/UltraBass9000/Assets.xcassets/AppIcon.appiconset
// plus its Contents.json, from vector drawing code. No source art, no external
// tools (no ImageMagick, no npm) — just CoreGraphics + ImageIO, both part of the
// system. Run from anywhere; paths resolve relative to this file, not to $PWD:
//
//   swift tools/icon/GenerateIcon.swift
//
// Concept — "one signal, many outputs"
// --------------------------------------
// UltraBass 9000 takes one system-audio stream and fans it out to several
// output devices, each with its own EQ/filter/delay chain. The icon draws
// that literally: a single source node splits into independent branches,
// each terminating in a node colored with the app's own meter ramp
// (green / amber / red — safe / hot / clipping), echoing the per-device
// level meters in the real UI. Nothing here is a speaker cone, a headphone,
// or a music note.
//
// Palette — deliberately bridges two systems
// --------------------------------------
// - The cool, near-black background and the soft glow behind the source
//   node borrow the visual language of the user's own design system,
//   github.com/nelitow/Nelitomorphism-UI-Kit (dark near-blacks at hue ~250,
//   a single glowing accent per region, tight radii, no fake materials).
//   Another agent is building a landing page from that kit, so this icon
//   shares a family resemblance with it. The kit's oklch tokens were
//   converted to sRGB by hand (see comments below) rather than eyeballed.
// - The meter green/amber/red and the signal blue are pulled directly from
//   Sources/UltraBass9000/Views/DesignSystem.swift (Colors.meterGreen /
//   meterAmber / meterRed), so the icon reads as unmistakably *this* app's
//   own instrument, not a generic dark-mode glyph.
//
// Grid — current macOS app icon proportions
// --------------------------------------
// Apple's macOS Big Sur-and-later icon template (still the current shape
// language, including under Liquid Glass) specifies a 1024x1024 canvas
// containing an 824x824 rounded-rectangle ("squircle") silhouette, centered
// (so a 100pt margin on every side), with a corner radius of 185.4pt on
// that 824pt shape — a ratio of ~0.225. Icon content should sit inside that
// silhouette with additional breathing room, not touch its edge. Those are
// the numbers used below (`squircleMargin`, `squircleSize`, `cornerRadius`).
//
// Detail tiers
// --------------------------------------
// A design that reads at 1024 does not automatically read at 16 — the brief
// is explicit that 16pt is the real test. Rather than draw once and downscale,
// three tiers are drawn with different *geometry*, not just different scale:
//   .full   (128, 256, 512, 1024): 3 branches, soft glow behind the source.
//   .medium (32, 64): 3 branches, no glow, bolder strokes/nodes.
//   .tiny   (16): 2 branches only (top/bottom, amber dropped), bold strokes,
//                 oversized nodes. Simplified until it survives being tiny.

import CoreGraphics
import Foundation
import ImageIO

// MARK: - Palette

enum Palette {
    // Cool near-black surface gradient. Converted from Nelitomorphism's
    // oklch tokens (--bg-3: oklch(0.225 0.018 250), --bg-1: oklch(0.145 0.014 250))
    // to sRGB via the standard OKLab -> linear sRGB matrices. Deliberately a
    // notch lighter than --bg-2/--bg-0: composited against a dark desktop
    // background, those read as near-invisible with no OS drop shadow to
    // separate them (verified by compositing at 32px). Still reads as "cool
    // near-black", just with a floor under how close it can get to the
    // wallpaper it might sit on.
    static let bgTop = CGColor(srgbRed: 21 / 255, green: 28 / 255, blue: 36 / 255, alpha: 1)
    static let bgBottom = CGColor(srgbRed: 6 / 255, green: 11 / 255, blue: 16 / 255, alpha: 1)

    // Nelitomorphism draws surface boundaries as "1px white-alpha borders,
    // not shadow-defined" (--edge-2: oklch(1 0 0 / 0.13)). Same fix here:
    // a faint rim keeps the squircle silhouette legible against a dark
    // desktop without leaning on the Dock/Finder's own drop shadow.
    static let rim = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.14)

    // Signal color: bridges macOS system blue (the app's own `accentColor`,
    // ~RGB 10/132/255 by default) with Nelitomorphism's cyan accent
    // (--accent: oklch(0.82 0.15 195) -> sRGB ~0/225/226). Leans blue, not teal,
    // so it still reads as "this app's accent" rather than borrowed teal.
    static let signal = CGColor(srgbRed: 58 / 255, green: 179 / 255, blue: 255 / 255, alpha: 1)

    // Exact meter ramp, copied from DesignSystem.Colors so the icon and the
    // real UI never drift apart.
    static let meterGreen = CGColor(srgbRed: 0.20, green: 0.85, blue: 0.45, alpha: 1)
    static let meterAmber = CGColor(srgbRed: 0.98, green: 0.75, blue: 0.15, alpha: 1)
    static let meterRed = CGColor(srgbRed: 0.95, green: 0.25, blue: 0.25, alpha: 1)
}

private func CGColor(srgbRed r: CGFloat, green g: CGFloat, blue b: CGFloat, alpha a: CGFloat) -> CGColor {
    CGColor(colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!, components: [r, g, b, a])!
}

private extension CGColor {
    func withAlpha(_ alpha: CGFloat) -> CGColor {
        copy(alpha: alpha) ?? self
    }
}

// MARK: - Grid constants (1024pt design basis; see header comment for sourcing)

enum Grid {
    static let canvas: CGFloat = 1024
    static let squircleMargin: CGFloat = 100
    static let squircleSize: CGFloat = 824
    static let cornerRadius: CGFloat = 185.4

    static var squircleRect: CGRect {
        CGRect(x: squircleMargin, y: squircleMargin, width: squircleSize, height: squircleSize)
    }
}

// MARK: - Detail tiers

enum DetailTier {
    case full, medium, tiny

    static func forPixelSize(_ size: Int) -> DetailTier {
        switch size {
        case ..<20: return .tiny
        case 20...96: return .medium
        default: return .full
        }
    }
}

// MARK: - Drawing

func drawSquircleBackground(in ctx: CGContext) {
    let rect = Grid.squircleRect
    let path = CGPath(roundedRect: rect, cornerWidth: Grid.cornerRadius, cornerHeight: Grid.cornerRadius, transform: nil)
    ctx.addPath(path)
    ctx.clip()

    let gradient = CGGradient(
        colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
        colors: [Palette.bgTop, Palette.bgBottom] as CFArray,
        locations: [0, 1]
    )!
    ctx.drawLinearGradient(
        gradient,
        start: CGPoint(x: rect.midX, y: rect.maxY),
        end: CGPoint(x: rect.midX, y: rect.minY),
        options: []
    )
}

/// Strokes a faint rim just inside the squircle silhouette. Must run after
/// the background's clip has been released (`ctx.restoreGState()`) — a
/// stroke drawn while still clipped to the same path only shows its inner
/// half, at half the intended weight.
func drawSquircleRim(in ctx: CGContext) {
    let inset: CGFloat = 1.5
    let rect = Grid.squircleRect.insetBy(dx: inset, dy: inset)
    let radius = Grid.cornerRadius - inset
    let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
    ctx.addPath(path)
    ctx.setStrokeColor(Palette.rim)
    ctx.setLineWidth(3)
    ctx.strokePath()
}

/// Fan-out glyph: a source node on the left, 2 or 3 branch lines opening
/// rightward, each ending in a node. `tier` controls branch count, stroke
/// weight, node size, and whether the source gets a soft glow.
func drawSignalFanOut(in ctx: CGContext, tier: DetailTier) {
    let squircle = Grid.squircleRect

    // Tiny gets a bit more of the squircle's real estate — bold, simple
    // shapes can safely sit closer to the edge than fine detail can.
    let glyphFraction: CGFloat = tier == .tiny ? 0.72 : 0.66
    let glyphSize = squircle.width * glyphFraction
    let glyphBox = CGRect(
        x: squircle.midX - glyphSize / 2,
        y: squircle.midY - glyphSize / 2,
        width: glyphSize,
        height: glyphSize
    )

    let sourceXFraction: CGFloat = tier == .tiny ? 0.18 : 0.16
    let sourceCenter = CGPoint(x: glyphBox.minX + glyphBox.width * sourceXFraction, y: glyphBox.midY)
    let endpointX = glyphBox.maxX - glyphBox.width * (tier == .tiny ? 0.04 : 0.05)

    struct Branch {
        let yFraction: CGFloat // offset from glyphBox.midY, as a fraction of glyphBox.height
        let color: CGColor
    }

    let branches: [Branch]
    switch tier {
    case .full, .medium:
        branches = [
            Branch(yFraction: -0.30, color: Palette.meterGreen),
            Branch(yFraction: 0.0, color: Palette.meterAmber),
            Branch(yFraction: 0.30, color: Palette.meterRed),
        ]
    case .tiny:
        // Amber dropped: at 16pt, green vs. red is the contrast that
        // survives; a third mid-tone just muddies two pixels into three.
        branches = [
            Branch(yFraction: -0.34, color: Palette.meterGreen),
            Branch(yFraction: 0.34, color: Palette.meterRed),
        ]
    }

    let sourceRadius: CGFloat
    let tipRadius: CGFloat
    let lineWidth: CGFloat
    switch tier {
    case .full:
        sourceRadius = glyphBox.width * 0.085
        tipRadius = glyphBox.width * 0.072
        lineWidth = glyphBox.width * 0.048
    case .medium:
        sourceRadius = glyphBox.width * 0.095
        tipRadius = glyphBox.width * 0.085
        lineWidth = glyphBox.width * 0.062
    case .tiny:
        sourceRadius = glyphBox.width * 0.15
        tipRadius = glyphBox.width * 0.13
        lineWidth = glyphBox.width * 0.11
    }

    // Branch lines first, so the filled nodes drawn afterwards cover the
    // stroked ends cleanly and every joint looks intentional.
    ctx.setLineCap(.round)
    ctx.setStrokeColor(Palette.signal)
    ctx.setLineWidth(lineWidth)
    for branch in branches {
        let end = CGPoint(x: endpointX, y: glyphBox.midY + glyphBox.height * branch.yFraction)
        ctx.beginPath()
        ctx.move(to: sourceCenter)
        ctx.addLine(to: end)
        ctx.strokePath()
    }

    // Soft glow behind the source node only — the "full" tier's one nod to
    // Nelitomorphism's single-glow-per-region rule. Skipped below 128px:
    // a blur radius that reads as a glow at 1024 is just mud at 32 and 16.
    if tier == .full {
        ctx.setShadow(offset: .zero, blur: sourceRadius * 1.5, color: Palette.signal.withAlpha(0.65))
    }
    ctx.setFillColor(Palette.signal)
    ctx.beginPath()
    ctx.addArc(center: sourceCenter, radius: sourceRadius, startAngle: 0, endAngle: .pi * 2, clockwise: false)
    ctx.fillPath()
    if tier == .full {
        ctx.setShadow(offset: .zero, blur: 0, color: nil)
    }

    for branch in branches {
        let end = CGPoint(x: endpointX, y: glyphBox.midY + glyphBox.height * branch.yFraction)
        ctx.setFillColor(branch.color)
        ctx.beginPath()
        ctx.addArc(center: end, radius: tipRadius, startAngle: 0, endAngle: .pi * 2, clockwise: false)
        ctx.fillPath()
    }
}

func renderIcon(pixelSize: Int) -> CGImage {
    let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    guard let ctx = CGContext(
        data: nil,
        width: pixelSize,
        height: pixelSize,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        fatalError("Could not create bitmap context at \(pixelSize)px")
    }
    ctx.setAllowsAntialiasing(true)
    ctx.setShouldAntialias(true)
    ctx.clear(CGRect(x: 0, y: 0, width: pixelSize, height: pixelSize))

    let scale = CGFloat(pixelSize) / Grid.canvas
    ctx.scaleBy(x: scale, y: scale)

    ctx.saveGState()
    drawSquircleBackground(in: ctx)
    drawSignalFanOut(in: ctx, tier: .forPixelSize(pixelSize))
    ctx.restoreGState() // releases the squircle clip before the rim is stroked

    drawSquircleRim(in: ctx)

    guard let image = ctx.makeImage() else {
        fatalError("Could not rasterize icon at \(pixelSize)px")
    }
    return image
}

func writePNG(_ image: CGImage, to url: URL) {
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
        fatalError("Could not create PNG destination at \(url.path)")
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
        fatalError("Could not write PNG at \(url.path)")
    }
}

/// Nearest-neighbor upscale, purely so a tiny render can be inspected without
/// a resampler's smoothing hiding exactly what a real 16pt icon looks like.
func writeDebugPreview(_ image: CGImage, scaleFactor: Int, to url: URL) {
    let outSize = image.width * scaleFactor
    let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    guard let ctx = CGContext(
        data: nil,
        width: outSize,
        height: outSize,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return }
    ctx.interpolationQuality = .none
    ctx.setFillColor(CGColor(srgbRed: 0.5, green: 0.5, blue: 0.5, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: outSize, height: outSize))
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: outSize, height: outSize))
    guard let out = ctx.makeImage() else { return }
    writePNG(out, to: url)
}

// MARK: - Contents.json

let appIconContentsJSON = """
{
  "images" : [
    {
      "filename" : "icon_16.png",
      "idiom" : "mac",
      "scale" : "1x",
      "size" : "16x16"
    },
    {
      "filename" : "icon_32.png",
      "idiom" : "mac",
      "scale" : "2x",
      "size" : "16x16"
    },
    {
      "filename" : "icon_32.png",
      "idiom" : "mac",
      "scale" : "1x",
      "size" : "32x32"
    },
    {
      "filename" : "icon_64.png",
      "idiom" : "mac",
      "scale" : "2x",
      "size" : "32x32"
    },
    {
      "filename" : "icon_128.png",
      "idiom" : "mac",
      "scale" : "1x",
      "size" : "128x128"
    },
    {
      "filename" : "icon_256.png",
      "idiom" : "mac",
      "scale" : "2x",
      "size" : "128x128"
    },
    {
      "filename" : "icon_256.png",
      "idiom" : "mac",
      "scale" : "1x",
      "size" : "256x256"
    },
    {
      "filename" : "icon_512.png",
      "idiom" : "mac",
      "scale" : "2x",
      "size" : "256x256"
    },
    {
      "filename" : "icon_512.png",
      "idiom" : "mac",
      "scale" : "1x",
      "size" : "512x512"
    },
    {
      "filename" : "icon_1024.png",
      "idiom" : "mac",
      "scale" : "2x",
      "size" : "512x512"
    }
  ],
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}
"""

let assetCatalogContentsJSON = """
{
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}
"""

// MARK: - Main

let scriptURL = URL(fileURLWithPath: #filePath)
let repoRoot = scriptURL
    .deletingLastPathComponent() // tools/icon
    .deletingLastPathComponent() // tools
    .deletingLastPathComponent() // repo root

let assetsDir = repoRoot
    .appendingPathComponent("Sources/UltraBass9000/Assets.xcassets")
let appIconDir = assetsDir.appendingPathComponent("AppIcon.appiconset")

try FileManager.default.createDirectory(at: appIconDir, withIntermediateDirectories: true)

try assetCatalogContentsJSON.write(
    to: assetsDir.appendingPathComponent("Contents.json"),
    atomically: true,
    encoding: .utf8
)
try appIconContentsJSON.write(
    to: appIconDir.appendingPathComponent("Contents.json"),
    atomically: true,
    encoding: .utf8
)

// Every distinct pixel size the appiconset references. 32/256/512 are each
// reused by two Contents.json entries (16pt@2x == 32pt@1x, etc.), so only
// seven files are actually rendered.
let sizes = [16, 32, 64, 128, 256, 512, 1024]

for size in sizes {
    let image = renderIcon(pixelSize: size)
    writePNG(image, to: appIconDir.appendingPathComponent("icon_\(size).png"))
    print("Wrote icon_\(size).png (\(DetailTier.forPixelSize(size)) tier)")
}

// Debug-only previews (not part of the appiconset) so 16pt and 32pt can
// actually be inspected instead of trusted on faith. Written to /tmp, never
// into the repo.
let previewDir = URL(fileURLWithPath: "/private/tmp/claude-501/-Users-nelitojr-Documents-GitHub-ultrabass9000/774dad8f-501d-4eba-a48a-ec015291c99d/scratchpad")
if FileManager.default.fileExists(atPath: previewDir.path) {
    writeDebugPreview(renderIcon(pixelSize: 16), scaleFactor: 16, to: previewDir.appendingPathComponent("preview_16_at_16x.png"))
    writeDebugPreview(renderIcon(pixelSize: 32), scaleFactor: 8, to: previewDir.appendingPathComponent("preview_32_at_8x.png"))
    print("Wrote debug previews to \(previewDir.path)")
}

print("Done.")
