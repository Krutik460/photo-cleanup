import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Draws a numbered contact sheet from thumbnails, so a reviewer can compare a whole group in one
/// image. Photos whose number is in `you` get a blue "YOU" badge instead of the red number badge.
/// Returns JPEG data, or nil when no thumbnail could be read.
func contactSheet(thumbnails: [URL], firstNumber: Int, you: Set<Int>) -> Data? {
    let cellHeight = 300.0, gap = 8.0, maxColumns = 4
    // A missing thumbnail keeps its number: the cell stays empty rather than shifting the others.
    let images: [CGImage?] = thumbnails.map { url in
        CGImageSourceCreateWithURL(url as CFURL, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }
    }
    guard images.contains(where: { $0 != nil }) else { return nil }

    // Rows of up to maxColumns cells, each cell keeping its image's aspect ratio.
    let widths = images.map { img in cellHeight * min(1.6, max(0.6, img.map { Double($0.width) / Double($0.height) } ?? 1)) }
    var rows: [[Int]] = []
    for i in images.indices {
        if rows.isEmpty || rows[rows.count - 1].count == maxColumns { rows.append([]) }
        rows[rows.count - 1].append(i)
    }
    let canvasWidth = rows.map { r in r.reduce(0.0) { $0 + widths[$1] } + gap * Double(r.count + 1) }.max()!
    let canvasHeight = Double(rows.count) * (cellHeight + gap) + gap
    guard let ctx = CGContext(data: nil, width: Int(canvasWidth), height: Int(canvasHeight), bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
    ctx.setFillColor(CGColor(gray: 0.12, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: canvasWidth, height: canvasHeight))
    let font = CTFontCreateWithName("Helvetica-Bold" as CFString, 34, nil)

    for (r, row) in rows.enumerated() {
        var x = gap
        let y = canvasHeight - Double(r + 1) * (cellHeight + gap)  // CoreGraphics origin is bottom-left
        for i in row {
            let rect = CGRect(x: x, y: y, width: widths[i], height: cellHeight)
            if let img = images[i] {  // aspect-fill the cell
                let scale = max(rect.width / Double(img.width), rect.height / Double(img.height))
                let w = Double(img.width) * scale, h = Double(img.height) * scale
                ctx.saveGState()
                ctx.clip(to: rect)
                ctx.draw(img, in: CGRect(x: rect.midX - w / 2, y: rect.midY - h / 2, width: w, height: h))
                ctx.restoreGState()
            }
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

    guard let image = ctx.makeImage() else { return nil }
    let data = NSMutableData()
    guard let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
    CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
    return CGImageDestinationFinalize(dest) ? data as Data : nil
}
