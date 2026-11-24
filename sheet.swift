// Draws a numbered contact sheet from thumbnails, so a reviewer can compare a whole group in one image.
// Usage: sheet <output.jpg> <first-number> [--you=2,5] <thumb1.jpg> [thumb2.jpg ...]
// Photos listed in --you (by number) get a blue "YOU" badge instead of the red number badge.

import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

let cellHeight = 300.0
let gap = 8.0
let maxColumns = 4

let args = CommandLine.arguments
guard args.count >= 4, let firstNumber = Int(args[2]) else {
    FileHandle.standardError.write("usage: sheet <output.jpg> <first-number> <thumb...>\n".data(using: .utf8)!)
    exit(2)
}
var rest = Array(args.dropFirst(3))
var you = Set<Int>()
if let flag = rest.first, flag.hasPrefix("--you=") {
    you = Set(flag.dropFirst(6).split(separator: ",").compactMap { Int($0) })
    rest.removeFirst()
}
let images: [CGImage] = rest.map { path in
    let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil)
    return src.flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }!
}

// Lay out rows of up to maxColumns cells, each cell keeping its image's aspect ratio.
let widths = images.map { cellHeight * min(1.6, max(0.6, Double($0.width) / Double($0.height))) }
var rows: [[Int]] = []
for i in images.indices {
    if rows.isEmpty || rows[rows.count - 1].count == maxColumns { rows.append([]) }
    rows[rows.count - 1].append(i)
}
let canvasWidth = rows.map { r in r.reduce(0.0) { $0 + widths[$1] } + gap * Double(r.count + 1) }.max()!
let canvasHeight = Double(rows.count) * (cellHeight + gap) + gap

let ctx = CGContext(data: nil, width: Int(canvasWidth), height: Int(canvasHeight), bitsPerComponent: 8, bytesPerRow: 0,
                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
ctx.setFillColor(CGColor(gray: 0.12, alpha: 1))
ctx.fill(CGRect(x: 0, y: 0, width: canvasWidth, height: canvasHeight))
let font = CTFontCreateWithName("Helvetica-Bold" as CFString, 34, nil)

for (r, row) in rows.enumerated() {
    var x = gap
    let y = canvasHeight - Double(r + 1) * (cellHeight + gap)  // CoreGraphics origin is bottom-left
    for i in row {
        let rect = CGRect(x: x, y: y, width: widths[i], height: cellHeight)
        // Aspect-fill the cell.
        let img = images[i]
        let scale = max(rect.width / Double(img.width), rect.height / Double(img.height))
        let w = Double(img.width) * scale, h = Double(img.height) * scale
        ctx.saveGState()
        ctx.clip(to: rect)
        ctx.draw(img, in: CGRect(x: rect.midX - w / 2, y: rect.midY - h / 2, width: w, height: h))
        ctx.restoreGState()
        // Number badge, top-left.
        let number = i + firstNumber
        let isYou = you.contains(number)
        let label = NSAttributedString(string: isYou ? "\(number) YOU" : "\(number)", attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 1, alpha: 1),
        ])
        let line = CTLineCreateWithAttributedString(label)
        let tw = CTLineGetTypographicBounds(line, nil, nil, nil)
        let badge = CGRect(x: rect.minX + 6, y: rect.maxY - 50, width: tw + 22, height: 44)
        ctx.setFillColor(isYou ? CGColor(red: 0.1, green: 0.35, blue: 0.9, alpha: 0.95) : CGColor(red: 0.85, green: 0.1, blue: 0.1, alpha: 0.92))
        ctx.fill(badge)
        ctx.textPosition = CGPoint(x: badge.minX + 11, y: badge.minY + 10)
        CTLineDraw(line, ctx)
        x += widths[i] + gap
    }
}

let out = URL(fileURLWithPath: args[1])
let dest = CGImageDestinationCreateWithURL(out as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(dest, ctx.makeImage()!, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
guard CGImageDestinationFinalize(dest) else { exit(1) }
