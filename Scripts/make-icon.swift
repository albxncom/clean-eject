#!/usr/bin/env swift
// Renders the CleanEject icon set: a blue-to-teal rounded square with a white eject symbol.
// Usage: swift Scripts/make-icon.swift <output.iconset>, then iconutil -c icns <output.iconset>.
// `make icon` does both and writes Resources/AppIcon.icns.
import AppKit

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: make-icon.swift <output.iconset>\n".utf8))
    exit(64)
}
let outputDirectory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

func render(pixels: Int) -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    // One point per pixel so every measurement below is in pixels.
    rep.size = NSSize(width: pixels, height: pixels)
    NSGraphicsContext.saveGraphicsState()
    defer { NSGraphicsContext.restoreGraphicsState() }
    let context = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = context
    context.imageInterpolation = .high

    let side = CGFloat(pixels)
    // The macOS icon grid leaves roughly 10% margin around the shape.
    let inset = side * 0.1
    let shape = NSBezierPath(
        roundedRect: NSRect(x: inset, y: inset, width: side - 2 * inset, height: side - 2 * inset),
        xRadius: side * 0.18, yRadius: side * 0.18
    )
    let gradient = NSGradient(
        starting: NSColor(calibratedRed: 0.10, green: 0.45, blue: 0.95, alpha: 1),
        ending: NSColor(calibratedRed: 0.05, green: 0.75, blue: 0.70, alpha: 1)
    )!
    gradient.draw(in: shape, angle: -60)

    let configuration = NSImage.SymbolConfiguration(pointSize: side * 0.4, weight: .bold)
        .applying(.init(paletteColors: [.white]))
    if let symbol = NSImage(systemSymbolName: "eject.fill", accessibilityDescription: nil)?.withSymbolConfiguration(configuration) {
        let scale = side * 0.55 / max(symbol.size.width, symbol.size.height)
        let size = NSSize(width: symbol.size.width * scale, height: symbol.size.height * scale)
        let origin = NSPoint(x: (side - size.width) / 2, y: (side - size.height) / 2)
        symbol.draw(in: NSRect(origin: origin, size: size), from: .zero, operation: .sourceOver, fraction: 1)
    }
    return rep.representation(using: .png, properties: [:])!
}

for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
        try render(pixels: points * scale).write(to: outputDirectory.appendingPathComponent(name))
    }
}
