import AppKit

let folder = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
let size = NSSize(width: 760, height: 430)
for scale in [1, 2] {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width) * scale,
                                  pixelsHigh: Int(size.height) * scale, bitsPerSample: 8,
                                  samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                  colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    let transform = NSAffineTransform()
    transform.scale(by: CGFloat(scale)); transform.concat()
    NSColor(calibratedRed: 0.96, green: 0.97, blue: 0.96, alpha: 1).setFill()
    NSRect(origin: .zero, size: size).fill()
    func text(_ string: String, y: CGFloat, font: NSFont, color: NSColor) {
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let width = (string as NSString).size(withAttributes: attributes).width
        (string as NSString).draw(at: NSPoint(x: (size.width - width) / 2, y: y), withAttributes: attributes)
    }
    text("Install filo", y: 345, font: .systemFont(ofSize: 25, weight: .medium),
         color: NSColor(calibratedWhite: 0.16, alpha: 1))
    text("Drag filo to Applications.", y: 318, font: .systemFont(ofSize: 13),
         color: NSColor(calibratedWhite: 0.40, alpha: 1))
    let arrow = NSBezierPath()
    arrow.move(to: NSPoint(x: 359, y: 205)); arrow.line(to: NSPoint(x: 401, y: 205))
    arrow.move(to: NSPoint(x: 393, y: 213)); arrow.line(to: NSPoint(x: 401, y: 205))
    arrow.line(to: NSPoint(x: 393, y: 197))
    arrow.lineWidth = 1.5; arrow.lineCapStyle = .round; arrow.lineJoinStyle = .round
    NSColor(calibratedRed: 0.12, green: 0.48, blue: 0.46, alpha: 1).setStroke()
    arrow.stroke()
    NSGraphicsContext.restoreGraphicsState()
    bitmap.size = size
    let suffix = scale == 2 ? "@2x" : ""
    try bitmap.representation(using: .png, properties: [:])!
        .write(to: folder.appendingPathComponent("background\(suffix).png"))
}
