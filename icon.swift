// Gera icon.png (1024x1024) no gabarito de ícones do macOS: forma de 824 px, cantos de raio 185.
// Uso: swift icon.swift
import AppKit

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1024, pixelsHigh: 1024, bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let r = NSRect(x: 100, y: 100, width: 824, height: 824)
NSBezierPath(roundedRect: r, xRadius: 185, yRadius: 185).addClip()
NSGradient(colors: [NSColor(red: 0.98, green: 0.45, blue: 0.33, alpha: 1), NSColor(red: 0.62, green: 0.20, blue: 0.78, alpha: 1)])!
    .draw(in: r, angle: -60)
// ondas de voz
NSColor.white.setFill()
let heights: [CGFloat] = [140, 260, 420, 560, 360, 480, 250, 150]
let w: CGFloat = 52, gap: CGFloat = 34
var x = 512 - (CGFloat(heights.count) * w + CGFloat(heights.count - 1) * gap) / 2
for h in heights {
    NSBezierPath(roundedRect: NSRect(x: x, y: 512 - h / 2, width: w, height: h), xRadius: w / 2, yRadius: w / 2).fill()
    x += w + gap
}
NSGraphicsContext.current = nil
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "icon.png"))
print("ok: icon.png")
