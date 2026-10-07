import AppKit
import Foundation

let root = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? FileManager.default.currentDirectoryPath)
let assets = root.appendingPathComponent("CodexUsageViewer/Assets.xcassets")
let icons = assets.appendingPathComponent("AppIcon.appiconset")
try FileManager.default.createDirectory(at: icons, withIntermediateDirectories: true)
let base: [String: Any] = ["info": ["author": "xcode", "version": 1]]
try JSONSerialization.data(withJSONObject: base, options: .prettyPrinted).write(to: assets.appendingPathComponent("Contents.json"))
let accent = assets.appendingPathComponent("AccentColor.colorset")
try FileManager.default.createDirectory(at: accent, withIntermediateDirectories: true)
try JSONSerialization.data(withJSONObject: ["info": ["author": "xcode", "version": 1], "colors": [["idiom": "universal", "color": ["color-space": "srgb", "components": ["red": "0.36", "green": "0.56", "blue": "0.87", "alpha": "1.0"]]]]], options: .prettyPrinted).write(to: accent.appendingPathComponent("Contents.json"))

var images: [[String: String]] = []
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let context = NSGraphicsContext(bitmapImageRep: bitmap)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.cgContext.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
        let tile = NSBezierPath(roundedRect: NSRect(x: 62, y: 62, width: 900, height: 900), xRadius: 220, yRadius: 220)
        let shadow = NSShadow(); shadow.shadowColor = NSColor.black.withAlphaComponent(0.22); shadow.shadowBlurRadius = 34; shadow.shadowOffset = NSSize(width: 0, height: -14)
        shadow.set()
        NSGradient(colors: [NSColor(srgbRed: 0.24, green: 0.30, blue: 0.44, alpha: 1), NSColor(srgbRed: 0.08, green: 0.12, blue: 0.20, alpha: 1)])!.draw(in: tile, angle: -80)
        NSShadow().set()
        NSGraphicsContext.saveGraphicsState()
        tile.addClip()
        NSColor.white.withAlphaComponent(0.16).setStroke(); tile.lineWidth = 5; tile.stroke()
        let cg = context.cgContext
        cg.translateBy(x: 512, y: 512)
        cg.rotate(by: -.pi / 5)
        let codexusageviewer = NSBezierPath(ovalIn: NSRect(x: -315, y: -190, width: 630, height: 380))
        codexusageviewer.lineWidth = 24
        NSColor.white.withAlphaComponent(0.26).setStroke(); codexusageviewer.stroke()
        let inner = NSBezierPath(ovalIn: NSRect(x: -208, y: -300, width: 416, height: 600))
        inner.lineWidth = 13; NSColor.white.withAlphaComponent(0.14).setStroke(); inner.stroke()
        let colors = [NSColor(srgbRed: 0.56, green: 0.89, blue: 0.77, alpha: 1), NSColor(srgbRed: 0.75, green: 0.68, blue: 0.98, alpha: 1), NSColor(srgbRed: 1, green: 0.75, blue: 0.56, alpha: 1)]
        let centers = [NSPoint(x: -268, y: 95), NSPoint(x: 238, y: 125), NSPoint(x: 25, y: -190)]
        for (index, point) in centers.enumerated() {
            let sphere = NSBezierPath(ovalIn: NSRect(x: point.x - 79, y: point.y - 79, width: 158, height: 158))
            let glow = NSShadow(); glow.shadowColor = colors[index].withAlphaComponent(0.45); glow.shadowBlurRadius = 30; glow.set()
            NSGradient(starting: colors[index].blended(withFraction: 0.6, of: .white)!, ending: colors[index])!.draw(in: sphere, angle: -80)
            NSShadow().set()
            NSColor.white.withAlphaComponent(0.45).setStroke(); sphere.lineWidth = 3; sphere.stroke()
        }
        let core = NSBezierPath(ovalIn: NSRect(x: -55, y: -55, width: 110, height: 110))
        NSGradient(starting: .white, ending: NSColor.white.withAlphaComponent(0.66))!.draw(in: core, angle: -90)
        NSGraphicsContext.restoreGraphicsState()
        NSGraphicsContext.restoreGraphicsState()
        let filename = "icon_\(size)x\(size)@\(scale)x.png"
        try bitmap.representation(using: .png, properties: [:])!.write(to: icons.appendingPathComponent(filename))
        images.append(["idiom": "mac", "size": "\(size)x\(size)", "scale": "\(scale)x", "filename": filename])
    }
}
try JSONSerialization.data(withJSONObject: ["info": ["author": "xcode", "version": 1], "images": images], options: [.prettyPrinted, .sortedKeys]).write(to: icons.appendingPathComponent("Contents.json"))
print("Generated CodexUsageViewer’s app icon and accent color.")
