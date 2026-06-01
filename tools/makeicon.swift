// Renders the MacChargePower app icon (aurora gradient + glowing bolt) to a PNG.
// Usage: swift tools/makeicon.swift <output-1024.png>
import AppKit

func color(_ rgb: UInt, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((rgb >> 16) & 0xff) / 255,
            green: CGFloat((rgb >> 8) & 0xff) / 255,
            blue: CGFloat(rgb & 0xff) / 255, alpha: a)
}

let S: CGFloat = 1024
let img = NSImage(size: NSSize(width: S, height: S))
img.lockFocus()
let ctx = NSGraphicsContext.current!.cgContext
let cs = CGColorSpaceCreateDeviceRGB()

// Rounded-rect "squircle" clip with the standard macOS-ish margin.
let margin = S * 0.085
let rect = CGRect(x: margin, y: margin, width: S - 2 * margin, height: S - 2 * margin)
let radius = rect.width * 0.2237
NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).addClip()

// Base diagonal gradient.
let bg = CGGradient(colorsSpace: cs,
                    colors: [color(0x241a44).cgColor, color(0x0c0a18).cgColor] as CFArray,
                    locations: [0, 1])!
ctx.drawLinearGradient(bg, start: CGPoint(x: margin, y: S - margin),
                       end: CGPoint(x: S - margin, y: margin), options: [])

// Drifting aurora blobs.
func blob(_ c: NSColor, _ center: CGPoint, _ r: CGFloat, _ a: CGFloat) {
    let g = CGGradient(colorsSpace: cs,
                       colors: [c.withAlphaComponent(a).cgColor, c.withAlphaComponent(0).cgColor] as CFArray,
                       locations: [0, 1])!
    ctx.drawRadialGradient(g, startCenter: center, startRadius: 0,
                           endCenter: center, endRadius: r, options: [])
}
blob(color(0x3B82F6), CGPoint(x: margin + rect.width * 0.22, y: S - margin - rect.height * 0.18), rect.width * 0.62, 0.85)
blob(color(0xA855F7), CGPoint(x: S - margin - rect.width * 0.16, y: margin + rect.height * 0.16), rect.width * 0.6, 0.8)

// Bolt (SF Symbol), tinted near-white, with a soft glow.
let cfg = NSImage.SymbolConfiguration(pointSize: S * 0.5, weight: .bold)
if let sym = NSImage(systemSymbolName: "bolt.fill", accessibilityDescription: nil)?.withSymbolConfiguration(cfg) {
    let bs = sym.size
    let tinted = NSImage(size: bs)
    tinted.lockFocus()
    color(0xeaf2ff).set()
    let r0 = CGRect(origin: .zero, size: bs)
    sym.draw(in: r0)
    r0.fill(using: .sourceAtop)
    tinted.unlockFocus()
    ctx.setShadow(offset: .zero, blur: S * 0.045, color: color(0x9ec7ff, 0.9).cgColor)
    tinted.draw(in: CGRect(x: (S - bs.width) / 2, y: (S - bs.height) / 2, width: bs.width, height: bs.height))
}

img.unlockFocus()
let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
print("wrote \(CommandLine.arguments[1])")
