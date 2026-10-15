import Foundation
import CoreGraphics
import CoreImage

/// Draws Mochi (squircle body, eyes, optional mouth and hat) with CoreGraphics. Everything in units of the body width.
enum MochiSprite {
    struct Pose {
        var level: Double = 0        // 0...1.15 loudness
        var blink = false
        var happy = false            // ^ ^ eyes
        var look: Double = 0         // -1...1
        var tilt: Double = 0         // radians
        var squash: Double = 1       // vertical scale
    }

    /// Canvas (in body widths) that the sprite is drawn into, so hats and hops never clip.
    static let canvasW = 1.5, canvasH = 1.9

    /// Renders into a CIImage of `pxWidth` body width; origin = canvas bottom-left; `bodyCenter` returns the body centre inside the image.
    static func render(pxWidth w: CGFloat, hat: MochiHat, dark: Bool, mouth: Bool, pose: Pose) -> (image: CIImage, bodyCenter: CGPoint)? {
        let cw = Int((w * canvasW).rounded(.up)), ch = Int((w * canvasH).rounded(.up))
        guard cw > 4, ch > 4 else { return nil }
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let c = CGContext(data: nil, width: cw, height: ch, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        c.setAllowsAntialiasing(true); c.setShouldAntialias(true)
        let ink: CGFloat = dark ? 0.04 : 1, paper: CGFloat = 1 - ink
        func col(_ g: CGFloat, _ a: CGFloat = 1) -> CGColor { CGColor(colorSpace: cs, components: [g, g, g, a])! }
        // body sits at 40% of the canvas height so a hat fits above and a hop is allowed.
        let centre = CGPoint(x: CGFloat(cw) / 2, y: CGFloat(ch) * 0.36)
        c.translateBy(x: centre.x, y: centre.y)
        c.rotate(by: CGFloat(pose.tilt))
        c.scaleBy(x: CGFloat(2 - pose.squash), y: CGFloat(pose.squash))
        let h = w * 0.78
        c.addPath(CGPath(roundedRect: CGRect(x: -w / 2, y: -h / 2, width: w, height: h), cornerWidth: h * 0.44, cornerHeight: h * 0.44, transform: nil))
        c.setFillColor(col(ink)); c.fillPath()
        // eyes
        c.setStrokeColor(col(paper)); c.setFillColor(col(paper)); c.setLineCap(.round); c.setLineWidth(w * 0.055)
        let happy = pose.happy || pose.level > 0.8
        for sx in [-1.0, 1.0] {
            let ex = CGFloat(sx) * w * 0.17 + CGFloat(pose.look) * w * 0.04, ey = h * 0.06
            if happy {
                c.move(to: CGPoint(x: ex - w * 0.075, y: ey - w * 0.02))
                c.addQuadCurve(to: CGPoint(x: ex + w * 0.075, y: ey - w * 0.02), control: CGPoint(x: ex, y: ey + w * 0.09))
                c.strokePath()
            } else {
                let eh = pose.blink ? w * 0.012 : w * (0.105 + 0.03 * CGFloat(min(pose.level, 1))), ew = w * 0.062
                c.fillEllipse(in: CGRect(x: ex - ew / 2, y: ey - eh / 2, width: ew, height: eh))
            }
        }
        // mouth: a small dark-on-light oval that opens with the voice
        if mouth {
            let open = CGFloat(min(max(pose.level, 0), 1))
            if open > 0.06 {
                let mw = w * (0.075 + 0.05 * open), mh = w * (0.02 + 0.115 * open)
                c.setFillColor(col(paper))
                c.fillEllipse(in: CGRect(x: -mw / 2, y: -h * 0.2 - mh / 2, width: mw, height: mh))
            } else {
                c.setStrokeColor(col(paper)); c.setLineWidth(w * 0.03)
                c.move(to: CGPoint(x: -w * 0.045, y: -h * 0.2)); c.addQuadCurve(to: CGPoint(x: w * 0.045, y: -h * 0.2), control: CGPoint(x: 0, y: -h * 0.2 - w * 0.03)); c.strokePath()
            }
        }
        // hat: fill = paper, outline = ink (reads on any background colour)
        let top = h / 2
        c.setFillColor(col(paper)); c.setStrokeColor(col(ink)); c.setLineWidth(max(2, w * 0.022)); c.setLineJoin(.round)
        switch hat {
        case .none: break
        case .witch:
            let cone = CGMutablePath()
            cone.move(to: CGPoint(x: -w * 0.28, y: top + w * 0.03))
            cone.addCurve(to: CGPoint(x: w * 0.22, y: top + w * 0.62), control1: CGPoint(x: -w * 0.12, y: top + w * 0.3), control2: CGPoint(x: w * 0.02, y: top + w * 0.55))
            cone.addCurve(to: CGPoint(x: w * 0.27, y: top + w * 0.03), control1: CGPoint(x: w * 0.12, y: top + w * 0.4), control2: CGPoint(x: w * 0.2, y: top + w * 0.25))
            cone.closeSubpath()
            c.addPath(cone); c.drawPath(using: .fillStroke)
            c.saveGState(); c.addPath(cone); c.clip(); c.setFillColor(col(ink)); c.fill(CGRect(x: -w, y: top + w * 0.07, width: w * 2, height: w * 0.065)); c.restoreGState()
            c.addPath(cone); c.strokePath()
            c.setFillColor(col(paper)); c.addEllipse(in: CGRect(x: -w * 0.48, y: top - w * 0.06, width: w * 0.96, height: w * 0.16)); c.drawPath(using: .fillStroke)
        case .party:
            let p = CGMutablePath(); p.move(to: CGPoint(x: -w * 0.2, y: top - w * 0.02)); p.addLine(to: CGPoint(x: w * 0.04, y: top + w * 0.5)); p.addLine(to: CGPoint(x: w * 0.22, y: top - w * 0.02)); p.closeSubpath()
            c.addPath(p); c.drawPath(using: .fillStroke)
            c.addEllipse(in: CGRect(x: w * 0.04 - w * 0.07, y: top + w * 0.47, width: w * 0.14, height: w * 0.14)); c.drawPath(using: .fillStroke)
        case .crown:
            let p = CGMutablePath(); p.move(to: CGPoint(x: -w * 0.26, y: top - w * 0.02)); p.addLine(to: CGPoint(x: -w * 0.28, y: top + w * 0.24))
            p.addLine(to: CGPoint(x: -w * 0.13, y: top + w * 0.11)); p.addLine(to: CGPoint(x: 0, y: top + w * 0.3)); p.addLine(to: CGPoint(x: w * 0.13, y: top + w * 0.11))
            p.addLine(to: CGPoint(x: w * 0.28, y: top + w * 0.24)); p.addLine(to: CGPoint(x: w * 0.26, y: top - w * 0.02)); p.closeSubpath()
            c.addPath(p); c.drawPath(using: .fillStroke)
        case .beanie:
            let p = CGMutablePath(); p.addArc(center: CGPoint(x: 0, y: top - w * 0.02), radius: w * 0.3, startAngle: 0, endAngle: .pi, clockwise: false); p.closeSubpath()
            c.addPath(p); c.drawPath(using: .fillStroke)
            c.addEllipse(in: CGRect(x: -w * 0.07, y: top + w * 0.25, width: w * 0.14, height: w * 0.14)); c.drawPath(using: .fillStroke)
            c.addPath(CGPath(roundedRect: CGRect(x: -w * 0.34, y: top - w * 0.07, width: w * 0.68, height: w * 0.11), cornerWidth: w * 0.05, cornerHeight: w * 0.05, transform: nil)); c.drawPath(using: .fillStroke)
        }
        guard let img = c.makeImage() else { return nil }
        return (CIImage(cgImage: img), centre)
    }
}
