#!/usr/bin/env swift
/// Renders the Postmark app icon (a white `envelope.badge.fill`-style glyph on a
/// rounded-rect accent-gradient background) into a macOS `AppIcon.appiconset`,
/// writing PNG slices + `Contents.json`. Xcode's asset-catalog compiler consumes
/// this set directly.
///
/// The glyph is drawn with AppKit paths (not `NSImage(systemSymbolName:)`) so it
/// builds deterministically across macOS SDK versions — see the plan's
/// "fallback documented to `AppIcon.appiconset`" note.
///
///   make render-icon   ->   swift scripts/render-icon.swift
///
/// Idempotent: re-running overwrites slices with identical bytes.
import Foundation
import AppKit

let root: URL = {
    if CommandLine.arguments.count > 1 {
        return URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
    }
    return URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
}()

let setDir = root
    .appendingPathComponent("Postmark")
    .appendingPathComponent("Resources")
    .appendingPathComponent("Assets.xcassets")
    .appendingPathComponent("AppIcon.appiconset")
    .standardized

try FileManager.default.createDirectory(at: setDir, withIntermediateDirectories: true)

typealias Entry = (size: Int, scale: Int, filename: String)
let entries: [Entry] = [
    (16, 1, "app-icon-16x16@1x.png"), (16, 2, "app-icon-16x16@2x.png"), (16, 3, "app-icon-16x16@3x.png"),
    (32, 1, "app-icon-32x32@1x.png"), (32, 2, "app-icon-32x32@2x.png"), (32, 3, "app-icon-32x32@3x.png"),
    (128, 1, "app-icon-128x128@1x.png"), (128, 2, "app-icon-128x128@2x.png"), (128, 3, "app-icon-128x128@3x.png"),
    (256, 1, "app-icon-256x256@1x.png"), (256, 2, "app-icon-256x256@2x.png"), (256, 3, "app-icon-256x256@3x.png"),
    (512, 1, "app-icon-512x512@1x.png"), (512, 2, "app-icon-512x512@2x.png"), (512, 3, "app-icon-512x512@3x.png"),
]

let accent = NSColor(deviceHue: 0.590, saturation: 0.933, brightness: 1.0, alpha: 1.0)
let dark = NSColor(deviceHue: 0.590, saturation: 0.850, brightness: 0.86, alpha: 1.0)
let baseSize: CGFloat = 1024

func makeBaseImage() -> NSImage {
    let img = NSImage(size: NSSize(width: baseSize, height: baseSize))
    img.lockFocus()
    defer { img.unlockFocus() }

    NSGraphicsContext.saveGraphicsState()
    let radius = baseSize * 0.23
    let rect = NSRect(origin: .zero, size: NSSize(width: baseSize, height: baseSize))

    let bg = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
    if let gradient = NSGradient(colors: [accent, dark]) {
        gradient.draw(in: bg, angle: 135)
    } else {
        accent.setFill()
        bg.fill()
    }

    drawGlyph(in: rect)
    NSGraphicsContext.restoreGraphicsState()
    return img
}

/// White envelope with a round notification badge in the upper-right flap corner.
func drawGlyph(in rect: NSRect) {
    let w = rect.width
    // Envelope body: a rounded rectangle, slightly narrower than full width.
    let bodyW = w * 0.62
    let bodyH = w * 0.52
    let bodyX = (w - bodyW) / 2
    let bodyY = (rect.height - bodyH) / 2
    let bodyRect = NSRect(x: bodyX, y: bodyY, width: bodyW, height: bodyH)

    NSColor.white.setFill()
    NSBezierPath(roundedRect: bodyRect, xRadius: 6, yRadius: 6).fill()

    // Envelope flap: a triangle whose base is the top edge midpoint.
    let flap = NSBezierPath()
    flap.move(to: NSPoint(x: bodyRect.minX + 8, y: bodyRect.maxY - 4))
    flap.curve(to: NSPoint(x: bodyRect.maxX - 8, y: bodyRect.maxY - 4),
               controlPoint1: NSPoint(x: bodyRect.midX, y: bodyRect.maxY + bodyH * 0.18),
               controlPoint2: NSPoint(x: bodyRect.midX, y: bodyRect.maxY + bodyH * 0.18))
    flap.line(to: NSPoint(x: bodyRect.maxX - 8, y: bodyRect.maxY - 4))
    flap.close()
    NSColor.white.setFill()
    flap.fill()

    // Fold lines (subtle separator on flap).
    let shadow = NSColor(white: 1, alpha: 0.18)
    shadow.setStroke()
    let sep = NSBezierPath()
    sep.move(to: NSPoint(x: bodyRect.minX + 8, y: bodyRect.maxY - 4))
    sep.line(to: NSPoint(x: bodyRect.maxX - 8, y: bodyRect.maxY - 4))
    sep.lineWidth = 1
    sep.stroke()

    // Badge: a small pill/circle floating in the upper-right of the flap.
    let badgeR = bodyW * 0.09
    let badgeX = bodyRect.maxX - badgeR - 4
    let badgeY = bodyRect.maxY - badgeR * 2
    NSBezierPath(roundedRect: NSRect(x: badgeX, y: badgeY, width: badgeR * 2, height: badgeR * 2),
                 xRadius: badgeR, yRadius: badgeR).fill()
}

func pngData(for image: NSImage, pixel: Int) -> Data? {
    let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil)?
        .cropping(to: CGRect(x: 0, y: 0, width: pixel, height: pixel))
    guard let cg else { return nil }
    return NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])
}

let base = makeBaseImage()

struct ImageEntry: Codable {
    var idiom: String = "mac"
    let size: String
    let scale: String
    let filename: String

    enum CodingKeys: String, CodingKey {
        case idiom, size, scale, filename
    }
}

struct Manifest: Codable {
    let images: [ImageEntry]
    let info: Info
    struct Info: Codable { let author: String; let version: Int }
}

var contents: [ImageEntry] = []
for entry in entries {
    let pixel = entry.size * entry.scale
    guard let data = pngData(for: base, pixel: pixel) else {
        print("⚠️ failed to render \(entry.filename)")
        continue
    }
    try data.write(to: setDir.appendingPathComponent(entry.filename), options: .atomic)
    contents.append(ImageEntry(size: "\(entry.size)x\(entry.size)", scale: "\(entry.scale)x", filename: entry.filename))
}

let manifest = Manifest(images: contents, info: .init(author: "Postmark", version: 1))
let jsonData = try JSONEncoder().encode(manifest)
try jsonData.write(to: setDir.appendingPathComponent("Contents.json"), options: .atomic)

print("✅ Rendered \(contents.count) icon slices into \(setDir.path)")
