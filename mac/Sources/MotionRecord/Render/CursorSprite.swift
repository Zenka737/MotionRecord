import Foundation
import CoreGraphics
import CoreImage

import AppKit

/// Cursor sprite (several resolutions) + click ripple.
struct CursorSprite {
    struct Level {
        var pxPerPoint: CGFloat
        var image: CIImage          // origin (0,0), CI (bottom-left) coordinates
        var hotspot: CGPoint        // tip position inside `image`, CI coordinates
        var cg: CGImage
    }
    var levels: [Level]
    var ripple: CIImage             // 256x256, circle centered, radius `rippleRadiusPx`
    let rippleRadiusPx: CGFloat = 118

    static let styles = ["macArrow", "classic", "dot", "ring", "custom"]

    /// Description of one cursor design in POINT space (top-left origin, y down).
    struct Design {
        var bounds: CGRect                  // includes margin for the shadow
        var hotspot: CGPoint                // in the same space as bounds
        var draw: (CGContext, CGFloat) -> Void   // context already flipped/scaled to points; arg = pxPerPoint
    }

    static func make(settings: RenderSettings = RenderSettings()) -> CursorSprite {
        let d = design(for: settings)
        let levels = [2.0, 4.0, 8.0, 16.0].map { makeLevel(pxPerPoint: CGFloat($0), design: d) }
        return CursorSprite(levels: levels, ripple: makeRipple())
    }

    /// Picks the smallest level that is at least as sharp as needed (so we only ever downscale by < 2x).
    func level(forPxPerPoint need: CGFloat) -> Level {
        for l in levels where l.pxPerPoint >= need * 0.99 { return l }
        return levels[levels.count - 1]
    }

    /// Sprite for a recorded system cursor image (point size / hotspot as captured).
    static func make(image img: NSImage, hotspot hot: CGPoint) -> CursorSprite {
        let margin: CGFloat = 6
        let sz = img.size
        let d = Design(bounds: CGRect(x: -hot.x - margin, y: -hot.y - margin, width: sz.width + 2 * margin, height: sz.height + 2 * margin),
                       hotspot: hot) { c, px in
            c.setShadow(offset: CGSize(width: 0, height: -1.4 * px), blur: 3.0 * px, color: CGColor(gray: 0, alpha: 0.40))
            drawNSImage(img, in: CGRect(x: -hot.x, y: -hot.y, width: sz.width, height: sz.height), ctx: c)
        }
        let levels = [2.0, 4.0, 8.0, 16.0].map { makeLevel(pxPerPoint: CGFloat($0), design: d) }
        return CursorSprite(levels: levels, ripple: makeRipple())
    }

    static func design(for s: RenderSettings) -> Design {
        let margin: CGFloat = 6
        func shadowed(_ c: CGContext, _ px: CGFloat) {
            c.setShadow(offset: CGSize(width: 0, height: -1.4 * px), blur: 3.0 * px,
                        color: CGColor(gray: 0, alpha: 0.40))
        }
        switch s.cursorStyle {
        case "dot":
            let r: CGFloat = 8
            return Design(bounds: CGRect(x: -r - margin, y: -r - margin, width: 2 * (r + margin), height: 2 * (r + margin)),
                          hotspot: .zero) { c, px in
                shadowed(c, px)
                c.setFillColor(CGColor(gray: 1, alpha: 1))
                c.fillEllipse(in: CGRect(x: -r, y: -r, width: 2 * r, height: 2 * r))
                c.setShadow(offset: .zero, blur: 0, color: nil)
                c.setStrokeColor(CGColor(gray: 0, alpha: 0.85)); c.setLineWidth(1.6)
                c.strokeEllipse(in: CGRect(x: -r, y: -r, width: 2 * r, height: 2 * r))
            }
        case "ring":
            let r: CGFloat = 10
            return Design(bounds: CGRect(x: -r - margin, y: -r - margin, width: 2 * (r + margin), height: 2 * (r + margin)),
                          hotspot: .zero) { c, px in
                shadowed(c, px)
                c.setStrokeColor(CGColor(gray: 1, alpha: 1)); c.setLineWidth(3.2)
                c.strokeEllipse(in: CGRect(x: -r, y: -r, width: 2 * r, height: 2 * r))
                c.setShadow(offset: .zero, blur: 0, color: nil)
                c.setStrokeColor(CGColor(gray: 0, alpha: 0.8)); c.setLineWidth(0.9)
                c.strokeEllipse(in: CGRect(x: -r - 1.8, y: -r - 1.8, width: 2 * r + 3.6, height: 2 * r + 3.6))
            }
        case "custom":
            if let p = s.customCursorPath, !p.isEmpty, let img = NSImage(contentsOfFile: p), img.size.width > 0, img.size.height > 0 {
                let k = 28 / max(img.size.width, img.size.height)
                let sz = CGSize(width: img.size.width * k, height: img.size.height * k)
                let hot = CGPoint(x: CGFloat(s.customCursorHotspotX) * sz.width, y: CGFloat(s.customCursorHotspotY) * sz.height)
                return Design(bounds: CGRect(x: -hot.x - margin, y: -hot.y - margin, width: sz.width + 2 * margin, height: sz.height + 2 * margin),
                              hotspot: hot) { c, px in
                    // origin of drawing space = top-left of image => shift by -hot
                    shadowed(c, px)
                    drawNSImage(img, in: CGRect(x: -hot.x, y: -hot.y, width: sz.width, height: sz.height), ctx: c)
                }
            }
            return design(for: { var t = s; t.cursorStyle = "macArrow"; return t }())
        case "classic":
            return Design(bounds: CGRect(x: -5, y: -4, width: 22, height: 30), hotspot: .zero) { c, px in
                let path = arrowPath()
                c.saveGState()
                shadowed(c, px)
                c.addPath(path)
                c.setLineWidth(2.0); c.setLineJoin(.round)
                c.setStrokeColor(CGColor(gray: 0, alpha: 1)); c.setFillColor(CGColor(gray: 0, alpha: 1))
                c.drawPath(using: .fillStroke)
                c.restoreGState()
                c.addPath(path)
                c.setFillColor(CGColor(gray: 1, alpha: 1))
                c.fillPath()
            }
        default: // macArrow
            let cur = NSCursor.arrow
            let img = cur.image
            let hot = cur.hotSpot
            let sz = img.size
            if sz.width < 1 || sz.height < 1 { return design(for: { var t = s; t.cursorStyle = "classic"; return t }()) }
            return Design(bounds: CGRect(x: -hot.x - margin, y: -hot.y - margin, width: sz.width + 2 * margin, height: sz.height + 2 * margin),
                          hotspot: hot) { c, px in
                shadowed(c, px)
                drawNSImage(img, in: CGRect(x: -hot.x, y: -hot.y, width: sz.width, height: sz.height), ctx: c)
            }
        }
    }

    /// Draws an NSImage into a context whose coordinate system is already flipped (y down).
    static func drawNSImage(_ img: NSImage, in rect: CGRect, ctx: CGContext) {
        let g = NSGraphicsContext(cgContext: ctx, flipped: true)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = g
        g.imageInterpolation = .high
        img.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true,
                 hints: [NSImageRep.HintKey.interpolation: NSImageInterpolation.high.rawValue])
        NSGraphicsContext.restoreGraphicsState()
    }

    static func arrowPath() -> CGPath {
        let p = CGMutablePath()
        p.move(to: CGPoint(x: 0, y: 0))
        p.addLine(to: CGPoint(x: 0, y: 17))
        p.addLine(to: CGPoint(x: 4.2, y: 13.2))
        p.addLine(to: CGPoint(x: 6.9, y: 19.5))
        p.addLine(to: CGPoint(x: 9.7, y: 18.3))
        p.addLine(to: CGPoint(x: 7.0, y: 12.0))
        p.addLine(to: CGPoint(x: 12.2, y: 12.0))
        p.closeSubpath()
        return p
    }

    static func makeLevel(pxPerPoint s: CGFloat, design d: Design) -> Level {
        let w = max(1, Int(ceil(d.bounds.width * s))), h = max(1, Int(ceil(d.bounds.height * s)))
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setAllowsAntialiasing(true)
        ctx.interpolationQuality = .high
        // Flip to top-left point coordinates; (0,0) of the drawing space = bounds.origin offset.
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: s, y: -s)
        ctx.translateBy(x: -d.bounds.minX, y: -d.bounds.minY)
        // Designs are drawn with their hotspot at the drawing-space origin shifted by `hotspot`:
        // macArrow/custom draw the image at -hot (so hot is at origin); classic/dot/ring draw around origin.
        d.draw(ctx, s)
        let cg = ctx.makeImage()!
        // Hotspot (drawing-space origin) inside the image, CI coordinates.
        let hot = CGPoint(x: -d.bounds.minX * s, y: CGFloat(h) - (-d.bounds.minY * s))
        return Level(pxPerPoint: s, image: CIImage(cgImage: cg), hotspot: hot, cg: cg)
    }

    static func makeRipple() -> CIImage {
        let n = 256
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: n, height: n, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let c = CGPoint(x: n / 2, y: n / 2)
        // Soft filled disc (radial falloff) ...
        let grad = CGGradient(colorsSpace: cs, colors: [
            CGColor(colorSpace: cs, components: [1, 1, 1, 0.10])!,
            CGColor(colorSpace: cs, components: [1, 1, 1, 0.34])!] as CFArray, locations: [0, 1])!
        ctx.saveGState()
        ctx.addEllipse(in: CGRect(x: c.x - 118, y: c.y - 118, width: 236, height: 236))
        ctx.clip()
        ctx.drawRadialGradient(grad, startCenter: c, startRadius: 0, endCenter: c, endRadius: 118, options: [])
        ctx.restoreGState()
        // ... plus a crisp ring.
        ctx.setStrokeColor(CGColor(colorSpace: cs, components: [1, 1, 1, 0.95])!)
        ctx.setLineWidth(9)
        ctx.strokeEllipse(in: CGRect(x: c.x - 113, y: c.y - 113, width: 226, height: 226))
        return CIImage(cgImage: ctx.makeImage()!)
    }
}
