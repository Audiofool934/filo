import AppKit

let destination = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                      colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        let transform = NSAffineTransform()
        transform.scale(by: CGFloat(pixels) / 1024); transform.concat()
        NSColor(calibratedRed: 0.94, green: 0.96, blue: 0.94, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x: 64, y: 64, width: 896, height: 896), xRadius: 200, yRadius: 200).fill()
        let ink = NSColor(calibratedRed: 0.12, green: 0.48, blue: 0.46, alpha: 1)
        ink.setStroke(); ink.setFill()
        let thread = NSBezierPath()
        thread.move(to: NSPoint(x: 295, y: 267))
        thread.curve(to: NSPoint(x: 470, y: 455), controlPoint1: NSPoint(x: 422, y: 267), controlPoint2: NSPoint(x: 470, y: 330))
        thread.line(to: NSPoint(x: 470, y: 633))
        thread.curve(to: NSPoint(x: 679, y: 763), controlPoint1: NSPoint(x: 470, y: 755), controlPoint2: NSPoint(x: 555, y: 800))
        thread.lineWidth = 43; thread.lineCapStyle = .round; thread.stroke()
        let cross = NSBezierPath()
        cross.move(to: NSPoint(x: 335, y: 528)); cross.line(to: NSPoint(x: 679, y: 528))
        cross.lineWidth = 43; cross.lineCapStyle = .round; cross.stroke()
        NSBezierPath(ovalIn: NSRect(x: 255, y: 227, width: 80, height: 80)).fill()
        NSColor(calibratedRed: 0.94, green: 0.96, blue: 0.94, alpha: 1).setFill()
        let endpoint = NSBezierPath(ovalIn: NSRect(x: 646, y: 730, width: 66, height: 66))
        endpoint.fill(); ink.setStroke(); endpoint.lineWidth = 17; endpoint.stroke()
        NSGraphicsContext.restoreGraphicsState()
        let suffix = scale == 2 ? "@2x" : ""
        let file = destination.appendingPathComponent("icon_\(size)x\(size)\(suffix).png")
        try bitmap.representation(using: .png, properties: [:])!.write(to: file)
    }
}
