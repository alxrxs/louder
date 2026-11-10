// Draws the app icon and writes Resources/AppIcon.icns (and AppIcon.png for the README).
// Run from the repo root: swift scripts/make-icon.swift
import AppKit

func draw(size: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = size / 1024
    func shadow(_ alpha: CGFloat, blur: CGFloat, y: CGFloat) {
        let shadow = NSShadow()
        shadow.shadowColor = .black.withAlphaComponent(alpha)
        shadow.shadowBlurRadius = blur * s
        shadow.shadowOffset = NSSize(width: 0, height: y * s)
        shadow.set()
    }

    // macOS icon grid: 824pt rounded square centred on a 1024 canvas.
    let tile = NSBezierPath(roundedRect: NSRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s), xRadius: 185 * s, yRadius: 185 * s)
    shadow(0.3, blur: 20, y: -10)
    NSGradient(starting: NSColor(srgbRed: 1.00, green: 0.50, blue: 0.22, alpha: 1),
               ending: NSColor(srgbRed: 0.62, green: 0.08, blue: 0.30, alpha: 1))!.draw(in: tile, angle: -90)
    NSShadow().set()

    // Sound waves, nearest first, fading out the way Flipane's windows fade back. The last
    // one, past where a normal speaker glyph stops, is the boost: warm yellow.
    let centre = NSPoint(x: 400 * s, y: 512 * s)
    let waves: [(radius: CGFloat, colour: NSColor)] = [
        (150, .white),
        (245, .white.withAlphaComponent(0.7)),
        (340, .white.withAlphaComponent(0.45)),
        (435, NSColor(srgbRed: 1.0, green: 0.86, blue: 0.35, alpha: 1)),
    ]
    for (index, wave) in waves.enumerated() {
        let arc = NSBezierPath()
        arc.appendArc(withCenter: centre, radius: wave.radius * s, startAngle: -38, endAngle: 38)
        arc.lineWidth = 46 * s
        arc.lineCapStyle = .round
        shadow(index == waves.count - 1 ? 0.35 : 0.22, blur: 22, y: -8)
        wave.colour.setStroke()
        arc.stroke()
    }
    NSShadow().set()

    // The speaker: a rounded magnet block and a flared cone, white with a soft drop shadow.
    let speaker = NSBezierPath()
    let body = NSRect(x: 210 * s, y: 420 * s, width: 110 * s, height: 184 * s)
    speaker.append(NSBezierPath(roundedRect: body, xRadius: 30 * s, yRadius: 30 * s))
    let cone = NSBezierPath()
    cone.move(to: NSPoint(x: 290 * s, y: 430 * s))
    cone.line(to: NSPoint(x: 430 * s, y: 318 * s))
    cone.curve(to: NSPoint(x: 470 * s, y: 340 * s), controlPoint1: NSPoint(x: 450 * s, y: 302 * s), controlPoint2: NSPoint(x: 470 * s, y: 315 * s))
    cone.line(to: NSPoint(x: 470 * s, y: 684 * s))
    cone.curve(to: NSPoint(x: 430 * s, y: 706 * s), controlPoint1: NSPoint(x: 470 * s, y: 709 * s), controlPoint2: NSPoint(x: 450 * s, y: 722 * s))
    cone.line(to: NSPoint(x: 290 * s, y: 594 * s))
    cone.close()
    speaker.append(cone)
    shadow(0.35, blur: 26, y: -10)
    NSColor.white.setFill()
    speaker.fill()
    NSShadow().set()

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        try draw(size: CGFloat(base * scale)).representation(using: .png, properties: [:])!
            .write(to: iconset.appendingPathComponent(name))
    }
}
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path, "-o", "Resources/AppIcon.icns"]
try task.run()
task.waitUntilExit()
try draw(size: 512).representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "Resources/AppIcon.png"))
print(task.terminationStatus == 0 ? "Wrote Resources/AppIcon.icns" : "iconutil failed")
