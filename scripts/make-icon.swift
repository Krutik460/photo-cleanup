// Draws the app icon and writes MacApp/Assets.xcassets/AppIcon.appiconset.
//   swift scripts/make-icon.swift MacApp/Assets.xcassets
// The icon: a stack of near-identical shots with the best one on top, marked as the keeper.

import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let size = 1024.0
let rgb = CGColorSpace(name: CGColorSpace.sRGB)!
func color(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) -> CGColor { CGColor(colorSpace: rgb, components: [r, g, b, a])! }
func gradient(_ colors: [CGColor]) -> CGGradient { CGGradient(colorsSpace: rgb, colors: colors as CFArray, locations: nil)! }
func rounded(_ rect: CGRect, _ radius: Double) -> CGPath { CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil) }

func draw() -> CGImage {
    let ctx = CGContext(data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8, bytesPerRow: 0, space: rgb,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    // The macOS icon shape: an 824 pt rounded square centered on the 1024 pt canvas, with a soft shadow.
    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: color(0, 0, 0, 0.3))
    ctx.addPath(rounded(tile, 186))
    ctx.setFillColor(color(0.1, 0.12, 0.2))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(rounded(tile, 186))
    ctx.clip()
    ctx.drawLinearGradient(gradient([color(0.16, 0.2, 0.36), color(0.07, 0.08, 0.14)]), start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])

    // Two repeats fanned out behind, dimmed: the shots that go.
    func card(angle: Double, dx: Double, dy: Double, alpha: Double) {
        ctx.saveGState()
        ctx.translateBy(x: 512 + dx, y: 500 + dy)
        ctx.rotate(by: angle * .pi / 180)
        ctx.addPath(rounded(CGRect(x: -230, y: -170, width: 460, height: 340), 36))
        ctx.setFillColor(color(0.62, 0.68, 0.84, alpha))
        ctx.fillPath()
        ctx.restoreGState()
    }
    card(angle: -13, dx: -52, dy: 26, alpha: 0.28)
    card(angle: 9, dx: 48, dy: 30, alpha: 0.45)

    // The keeper on top: a small landscape in a white frame.
    let frame = CGRect(x: 262, y: 300, width: 500, height: 372)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 34, color: color(0, 0, 0, 0.45))
    ctx.addPath(rounded(frame, 40))
    ctx.setFillColor(color(1, 1, 1))
    ctx.fillPath()
    ctx.restoreGState()

    let picture = frame.insetBy(dx: 22, dy: 22)
    ctx.saveGState()
    ctx.addPath(rounded(picture, 22))
    ctx.clip()
    ctx.drawLinearGradient(gradient([color(0.35, 0.62, 0.98), color(0.72, 0.86, 1.0)]), start: CGPoint(x: 0, y: picture.maxY), end: CGPoint(x: 0, y: picture.minY), options: [])
    ctx.setFillColor(color(1.0, 0.86, 0.36))
    ctx.fillEllipse(in: CGRect(x: picture.minX + 62, y: picture.maxY - 140, width: 84, height: 84))
    func hill(_ points: [CGPoint], _ fill: CGColor) {
        ctx.beginPath()
        ctx.move(to: CGPoint(x: picture.minX, y: picture.minY))
        for p in points { ctx.addLine(to: p) }
        ctx.addLine(to: CGPoint(x: picture.maxX, y: picture.minY))
        ctx.closePath()
        ctx.setFillColor(fill)
        ctx.fillPath()
    }
    hill([CGPoint(x: picture.minX, y: picture.minY + 90), CGPoint(x: picture.minX + 170, y: picture.minY + 215),
          CGPoint(x: picture.minX + 300, y: picture.minY + 110), CGPoint(x: picture.maxX, y: picture.minY + 190)], color(0.2, 0.5, 0.42))
    hill([CGPoint(x: picture.minX, y: picture.minY + 50), CGPoint(x: picture.minX + 120, y: picture.minY + 105),
          CGPoint(x: picture.minX + 290, y: picture.minY + 62), CGPoint(x: picture.maxX, y: picture.minY + 128)], color(0.12, 0.36, 0.33))
    ctx.restoreGState()

    // The mark of the keeper: a gold disc with a star.
    let badge = CGRect(x: 628, y: 232, width: 196, height: 196)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -8), blur: 20, color: color(0, 0, 0, 0.4))
    ctx.setFillColor(color(0.07, 0.08, 0.14))
    ctx.fillEllipse(in: badge)
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addEllipse(in: badge.insetBy(dx: 12, dy: 12))
    ctx.clip()
    ctx.drawLinearGradient(gradient([color(1.0, 0.82, 0.3), color(0.96, 0.62, 0.12)]), start: CGPoint(x: 0, y: badge.maxY), end: CGPoint(x: 0, y: badge.minY), options: [])
    ctx.restoreGState()
    ctx.beginPath()
    for i in 0..<10 {
        let r = i % 2 == 0 ? 58.0 : 25.0, a = Double(i) * .pi / 5 + .pi / 2
        let p = CGPoint(x: badge.midX + r * cos(a), y: badge.midY - 2 + r * sin(a))
        if i == 0 { ctx.move(to: p) } else { ctx.addLine(to: p) }
    }
    ctx.closePath()
    ctx.setFillColor(color(1, 1, 1))
    ctx.fillPath()
    ctx.restoreGState()
    return ctx.makeImage()!
}

func write(_ image: CGImage, pixels: Int, to url: URL) {
    let ctx = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0, space: rgb,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: pixels, height: pixels))
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
    precondition(CGImageDestinationFinalize(dest), "cannot write \(url.path)")
}

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: swift scripts/make-icon.swift <Assets.xcassets>\n".utf8))
    exit(2)
}
let catalog = URL(fileURLWithPath: CommandLine.arguments[1])
let set = catalog.appendingPathComponent("AppIcon.appiconset")
try FileManager.default.createDirectory(at: set, withIntermediateDirectories: true)
try Data(#"{"info":{"author":"xcode","version":1}}"#.utf8).write(to: catalog.appendingPathComponent("Contents.json"))

let master = draw()
var images: [[String: String]] = []
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
        write(master, pixels: points * scale, to: set.appendingPathComponent(name))
        images.append(["idiom": "mac", "size": "\(points)x\(points)", "scale": "\(scale)x", "filename": name])
    }
}
let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys]).write(to: set.appendingPathComponent("Contents.json"))
print("wrote \(images.count) sizes to \(set.path)")
