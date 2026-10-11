#!/usr/bin/env swift
//
//  export-icons.swift
//  Renders the SVG sources in branding/ into the Xcode asset catalog.
//
//  Usage (from the repository root):
//      swift branding/export-icons.swift
//
//  - AppIcon.appiconset: one PNG per size (16–1024 px) with the macOS drop shadow.
//    16 px and 32 px outputs use app-icon-small.svg, which drops fine detail.
//  - MenuBarIcon.imageset: 18 px / 36 px template PNGs (alpha only; macOS tints them).
//  - LogoMark.imageset: the icon cropped to its body, for the in-app logo (28 pt).
//  - branding/exports: logo mark PNGs for the website and docs.
//

import AppKit

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let branding = root.appendingPathComponent("branding")
let assets = root.appendingPathComponent("SideCli/SideCli/Assets.xcassets")
let appIconSet = assets.appendingPathComponent("AppIcon.appiconset")
let menuBarSet = assets.appendingPathComponent("MenuBarIcon.imageset")
let logoMarkSet = assets.appendingPathComponent("LogoMark.imageset")
let exports = branding.appendingPathComponent("exports")

func load(_ name: String) -> NSImage {
    guard let image = NSImage(contentsOf: branding.appendingPathComponent(name)) else {
        fatalError("Could not load branding/\(name)")
    }
    return image
}

/// Draws `image` (vector) into a square bitmap of `pixels`, optionally with the
/// macOS app-icon drop shadow scaled from the 1024 px template. `cropToBody`
/// drops the 100 px icon-grid margin so the rounded body fills the bitmap.
func render(_ image: NSImage, pixels: Int, shadow: Bool, cropToBody: Bool = false) -> Data {
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                     bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                     colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
          let context = NSGraphicsContext(bitmapImageRep: rep) else {
        fatalError("Could not create a \(pixels) px bitmap")
    }
    rep.size = NSSize(width: pixels, height: pixels)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    context.imageInterpolation = .high
    if shadow {
        let scale = CGFloat(pixels) / 1024
        let dropShadow = NSShadow()
        dropShadow.shadowColor = NSColor.black.withAlphaComponent(0.32)
        dropShadow.shadowOffset = NSSize(width: 0, height: -12 * scale)
        dropShadow.shadowBlurRadius = 24 * scale
        dropShadow.set()
    }
    if cropToBody {
        let scale = CGFloat(pixels) / 824
        image.draw(in: NSRect(x: -100 * scale, y: -100 * scale, width: 1024 * scale, height: 1024 * scale))
    } else {
        image.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
    }
    NSGraphicsContext.restoreGraphicsState()
    guard let tagged = rep.retagging(with: .sRGB),
          let png = tagged.representation(using: .png, properties: [:]) else {
        fatalError("Could not encode a \(pixels) px PNG")
    }
    return png
}

func write(_ data: Data, to url: URL) {
    do { try data.write(to: url) } catch { fatalError("Could not write \(url.path): \(error)") }
    print("  \(url.path.replacingOccurrences(of: root.path + "/", with: ""))")
}

func writeJSON(_ object: Any, to url: URL) {
    let data = try! JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
    write(data, to: url)
}

let fullIcon = load("app-icon.svg")
let smallIcon = load("app-icon-small.svg")
let menuBarIcon = load("menubar-icon.svg")

// MARK: App icon

print("App icon:")
let fm = FileManager.default
for file in (try? fm.contentsOfDirectory(atPath: appIconSet.path)) ?? [] where file.hasSuffix(".png") {
    try? fm.removeItem(at: appIconSet.appendingPathComponent(file))
}
var images: [[String: String]] = []
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = points * scale
        let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
        write(render(pixels <= 32 ? smallIcon : fullIcon, pixels: pixels, shadow: true),
              to: appIconSet.appendingPathComponent(name))
        images.append(["filename": name, "idiom": "mac", "scale": "\(scale)x", "size": "\(points)x\(points)"])
    }
}
writeJSON(["images": images, "info": ["author": "xcode", "version": 1]],
          to: appIconSet.appendingPathComponent("Contents.json"))

// MARK: Menu bar icon (template)

print("Menu bar icon:")
for file in (try? fm.contentsOfDirectory(atPath: menuBarSet.path)) ?? [] where file.hasSuffix(".png") {
    try? fm.removeItem(at: menuBarSet.appendingPathComponent(file))
}
write(render(menuBarIcon, pixels: 18, shadow: false), to: menuBarSet.appendingPathComponent("menubar-icon.png"))
write(render(menuBarIcon, pixels: 36, shadow: false), to: menuBarSet.appendingPathComponent("menubar-icon@2x.png"))
writeJSON([
    "images": [
        ["filename": "menubar-icon.png", "idiom": "universal", "scale": "1x"],
        ["filename": "menubar-icon@2x.png", "idiom": "universal", "scale": "2x"],
    ],
    "info": ["author": "xcode", "version": 1],
    "properties": ["template-rendering-intent": "template"],
], to: menuBarSet.appendingPathComponent("Contents.json"))

// MARK: In-app logo mark

print("Logo mark (toolbar):")
try? fm.createDirectory(at: logoMarkSet, withIntermediateDirectories: true)
for file in (try? fm.contentsOfDirectory(atPath: logoMarkSet.path)) ?? [] where file.hasSuffix(".png") {
    try? fm.removeItem(at: logoMarkSet.appendingPathComponent(file))
}
write(render(fullIcon, pixels: 28, shadow: false, cropToBody: true), to: logoMarkSet.appendingPathComponent("logo-mark.png"))
write(render(fullIcon, pixels: 56, shadow: false, cropToBody: true), to: logoMarkSet.appendingPathComponent("logo-mark@2x.png"))
writeJSON([
    "images": [
        ["filename": "logo-mark.png", "idiom": "universal", "scale": "1x"],
        ["filename": "logo-mark@2x.png", "idiom": "universal", "scale": "2x"],
    ],
    "info": ["author": "xcode", "version": 1],
], to: logoMarkSet.appendingPathComponent("Contents.json"))

// MARK: Logo mark exports

print("Logo exports:")
try? fm.createDirectory(at: exports, withIntermediateDirectories: true)
for pixels in [1024, 512, 192] {
    write(render(pixels <= 32 ? smallIcon : fullIcon, pixels: pixels, shadow: false),
          to: exports.appendingPathComponent("logo-mark-\(pixels).png"))
}
print("Done.")
