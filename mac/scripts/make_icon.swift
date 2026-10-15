import AppKit
import CoreGraphics

let S: CGFloat = 1024
let cs = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: 1024, height: 1024, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
func col(_ h: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: cs, components: [CGFloat((h >> 16) & 255) / 255, CGFloat((h >> 8) & 255) / 255, CGFloat(h & 255) / 255, a])!
}
// macOS icon grid: 824pt squircle centred
let rect = CGRect(x: 100, y: 100, width: 824, height: 824)
let squircle = CGPath(roundedRect: rect, cornerWidth: 185, cornerHeight: 185, transform: nil)

// drop shadow
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 34, color: col(0x000000, 0.45))
ctx.addPath(squircle); ctx.setFillColor(col(0x5B3DF5)); ctx.fillPath()
ctx.restoreGState()

// background gradient
ctx.saveGState()
ctx.addPath(squircle); ctx.clip()
let g = CGGradient(colorsSpace: cs, colors: [col(0x3B2BD9), col(0x7C3AED), col(0xE04BC6)] as CFArray, locations: [0, 0.5, 1])!
ctx.drawLinearGradient(g, start: CGPoint(x: 160, y: 924), end: CGPoint(x: 880, y: 100), options: [])
// soft glow top-left
let glow = CGGradient(colorsSpace: cs, colors: [col(0xFFFFFF, 0.35), col(0xFFFFFF, 0)] as CFArray, locations: [0, 1])!
ctx.drawRadialGradient(glow, startCenter: CGPoint(x: 330, y: 800), startRadius: 0, endCenter: CGPoint(x: 330, y: 800), endRadius: 520, options: [])

// "screen" glass card
let card = CGRect(x: 214, y: 330, width: 596, height: 380)
let cardPath = CGPath(roundedRect: card, cornerWidth: 54, cornerHeight: 54, transform: nil)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -18), blur: 40, color: col(0x1A0B5C, 0.5))
ctx.addPath(cardPath); ctx.setFillColor(col(0xFFFFFF, 0.22)); ctx.fillPath()
ctx.restoreGState()
ctx.addPath(cardPath); ctx.setStrokeColor(col(0xFFFFFF, 0.55)); ctx.setLineWidth(5); ctx.strokePath()
// top bar dots
for (i, c) in [0xFF5F57, 0xFEBC2E, 0x28C840].enumerated() {
    ctx.setFillColor(col(UInt32(c))); ctx.fillEllipse(in: CGRect(x: 250 + CGFloat(i) * 44, y: 660, width: 26, height: 26))
}
// record dot (red) with halo rings
let c0 = CGPoint(x: 512, y: 505)
for (r, a) in [(150.0, 0.12), (118.0, 0.2)] as [(CGFloat, CGFloat)] {
    ctx.setFillColor(col(0xFFFFFF, a)); ctx.fillEllipse(in: CGRect(x: c0.x - r, y: c0.y - r, width: r * 2, height: r * 2))
}
let rg = CGGradient(colorsSpace: cs, colors: [col(0xFF6B81), col(0xFF2D55)] as CFArray, locations: [0, 1])!
ctx.saveGState()
ctx.addEllipse(in: CGRect(x: c0.x - 84, y: c0.y - 84, width: 168, height: 168)); ctx.clip()
ctx.drawLinearGradient(rg, start: CGPoint(x: c0.x, y: c0.y + 84), end: CGPoint(x: c0.x, y: c0.y - 84), options: [])
ctx.restoreGState()
ctx.setStrokeColor(col(0xFFFFFF)); ctx.setLineWidth(10)
ctx.strokeEllipse(in: CGRect(x: c0.x - 84, y: c0.y - 84, width: 168, height: 168))

// cursor arrow (white with dark outline), tip at (610, 470)
let tip = CGPoint(x: 612, y: 452)
let arrow = CGMutablePath()
let pts: [(CGFloat, CGFloat)] = [(0, 0), (0, -250), (66, -190), (112, -296), (160, -276), (116, -172), (210, -172)]
arrow.move(to: CGPoint(x: tip.x + pts[0].0, y: tip.y + pts[0].1))
for p in pts.dropFirst() { arrow.addLine(to: CGPoint(x: tip.x + p.0, y: tip.y + p.1)) }
arrow.closeSubpath()
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 22, color: col(0x000000, 0.5))
ctx.addPath(arrow); ctx.setFillColor(col(0xFFFFFF)); ctx.fillPath()
ctx.restoreGState()
ctx.addPath(arrow); ctx.setStrokeColor(col(0x15122E)); ctx.setLineWidth(16); ctx.setLineJoin(.round); ctx.strokePath()
ctx.addPath(arrow); ctx.setFillColor(col(0xFFFFFF)); ctx.fillPath()

// top glossy edge
ctx.restoreGState()
ctx.saveGState()
ctx.addPath(squircle); ctx.clip()
ctx.addPath(squircle); ctx.setStrokeColor(col(0xFFFFFF, 0.25)); ctx.setLineWidth(6); ctx.strokePath()
ctx.restoreGState()

let img = ctx.makeImage()!
let rep = NSBitmapImageRep(cgImage: img)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
