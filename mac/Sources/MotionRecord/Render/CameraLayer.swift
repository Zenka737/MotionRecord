import Foundation
import CoreGraphics
import CoreImage

/// Shape outlines for the webcam cutout. Every shape is a closed 128-point polyline in the UNIT rect
/// (origin top-left, y down), point i at angle 2*pi*i/128 clockwise from "right", so shapes can be
/// morphed point-wise.
enum CameraOutlines {
    static let count = 128

    /// `pw`/`ph` = pixel size the outline will be stretched to (only used for rounded-rect corner radii).
    static func outline(shape: CameraShape, cornerRadius: Double, pw: Double, ph: Double) -> [CGPoint] {
        var pts: [CGPoint] = []
        pts.reserveCapacity(count)
        func radial(_ r: (Double) -> Double) {
            for i in 0..<count {
                let th = 2 * Double.pi * Double(i) / Double(count)
                let rr = r(th)
                pts.append(CGPoint(x: 0.5 + rr * cos(th), y: 0.5 + rr * sin(th)))
            }
        }
        switch shape {
        case .circle:
            radial { _ in 0.5 }
        case .squircle:
            radial { th in 0.5 / pow(pow(abs(cos(th)), 4) + pow(abs(sin(th)), 4), 0.25) }
        case .hexagon:
            let apothem = 0.5 * cos(Double.pi / 6)
            radial { th in
                let a = th.truncatingRemainder(dividingBy: Double.pi / 3) - Double.pi / 6
                return apothem / cos(a)
            }
        case .star:
            radial { th in
                let seg = 2 * Double.pi / 5
                var a = (th + Double.pi / 2).truncatingRemainder(dividingBy: seg)
                if a < 0 { a += seg }
                let f = abs(1 - 2 * a / seg)   // 1 at a tip, 0 at an inner vertex
                return 0.2 + 0.3 * f
            }
        case .blob:
            radial { th in 0.5 * (0.86 + 0.07 * sin(3 * th + 0.6) + 0.05 * sin(5 * th + 1.9)) }
        case .heart:
            var raw: [CGPoint] = []
            for i in 0..<count {
                let t = Double.pi / 2 + 2 * Double.pi * Double(i) / Double(count)
                let x = 16 * pow(sin(t), 3)
                let y = 13 * cos(t) - 5 * cos(2 * t) - 2 * cos(3 * t) - cos(4 * t)
                raw.append(CGPoint(x: x, y: -y))
            }
            let minX = raw.map { $0.x }.min()!, maxX = raw.map { $0.x }.max()!
            let minY = raw.map { $0.y }.min()!, maxY = raw.map { $0.y }.max()!
            pts = raw.map { CGPoint(x: ($0.x - minX) / (maxX - minX), y: ($0.y - minY) / (maxY - minY)) }
        case .rectangle, .roundedRect:
            var rx = 0.0, ry = 0.0
            if shape == .roundedRect {
                let rad = min(max(cornerRadius, 0), 1) * 0.5 * min(pw, ph)
                rx = rad / max(pw, 1); ry = rad / max(ph, 1)
            }
            for i in 0..<count {
                let th = 2 * Double.pi * Double(i) / Double(count)
                let dx = cos(th), dy = sin(th)
                var t = 0.5 / max(abs(dx), abs(dy))
                if rx > 1e-6, ry > 1e-6 {
                    let hx = t * abs(dx), hy = t * abs(dy)
                    if hx > 0.5 - rx && hy > 0.5 - ry {
                        let ex = (dx < 0 ? -1.0 : 1.0) * (0.5 - rx), ey = (dy < 0 ? -1.0 : 1.0) * (0.5 - ry)
                        let A = dx * dx / (rx * rx) + dy * dy / (ry * ry)
                        let B = dx * ex / (rx * rx) + dy * ey / (ry * ry)
                        let C = ex * ex / (rx * rx) + ey * ey / (ry * ry) - 1
                        let disc = max(B * B - A * C, 0)
                        t = (B + sqrt(disc)) / A
                    }
                }
                pts.append(CGPoint(x: 0.5 + t * dx, y: 0.5 + t * dy))
            }
        }
        return pts
    }

    static func isSquareShape(_ s: CameraShape) -> Bool { !(s == .rectangle || s == .roundedRect) }
}

/// Webcam cutout layer: keyframe interpolation, morphing mask, border, shadow.
final class CameraLayer: @unchecked Sendable {
    struct KF {
        var k: CameraKeyframe
        var rect: CGRect        // effective rect in output px, top-left origin
        var outline: [CGPoint]
        var full: Bool
        var color: (Double, Double, Double)
    }
    struct Bundle { var mask: CIImage; var shadow: CIImage; var ring: CIImage?; var bounds: CGRect }

    let outW: CGFloat, outH: CGFloat, unit: CGFloat
    let mirror: Bool
    let kfs: [KF]
    private let lock = NSLock()
    private var cache: [Int: Bundle] = [:]

    init(settings: CameraSettings, outSize: CGSize) {
        outW = outSize.width; outH = outSize.height
        unit = min(outSize.width, outSize.height) / 1080
        mirror = settings.mirror
        var src = settings.keyframes.sorted { $0.t < $1.t }
        if src.isEmpty { src = [CameraKeyframe(t: 0)] }
        let W = outSize.width, H = outSize.height
        kfs = src.map { k in
            var r = CGRect(x: k.x * W, y: k.y * H, width: k.w * W, height: k.h * H)
            if CameraOutlines.isSquareShape(k.shape) {
                let side = min(r.width, r.height)
                r = CGRect(x: r.midX - side / 2, y: r.midY - side / 2, width: side, height: side)
            }
            r.size.width = max(r.width, 2); r.size.height = max(r.height, 2)
            let full = k.shape == .rectangle && k.x <= 0.001 && k.y <= 0.001 && k.w >= 0.999 && k.h >= 0.999 && k.opacity >= 0.999
            if full { r = CGRect(x: 0, y: 0, width: W, height: H) }
            let col = parseHexColor(k.borderColorHex, fallback: (1, 1, 1))
            return KF(k: k, rect: r,
                      outline: CameraOutlines.outline(shape: k.shape, cornerRadius: k.cornerRadius, pw: r.width, ph: r.height),
                      full: full, color: col)
        }
    }

    private func locate(_ t: Double) -> (Int, Int, Double) {
        if t <= kfs[0].k.t { return (0, 0, 0) }
        if t >= kfs[kfs.count - 1].k.t { return (kfs.count - 1, kfs.count - 1, 0) }
        var i = 0
        while i + 1 < kfs.count - 1 && kfs[i + 1].k.t <= t { i += 1 }
        let a = kfs[i].k.t, b = kfs[i + 1].k.t
        let u = Easing.smootherstep((t - a) / max(b - a, 1e-6))
        return (i, i + 1, u)
    }

    /// Returns the premultiplied camera layer (to composite OVER everything else except text) and whether
    /// it fully covers the canvas.
    func render(camera cam0: CIImage, t: Double) -> (layer: CIImage, full: Bool)? {
        let (ia, ib, u0) = locate(t)
        let uq = Int((u0 * 600).rounded())
        let u = Double(uq) / 600
        let a = kfs[ia], b = kfs[ib]
        func L(_ x: Double, _ y: Double) -> Double { x + (y - x) * u }
        let rect = CGRect(x: L(a.rect.minX, b.rect.minX), y: L(a.rect.minY, b.rect.minY),
                          width: L(a.rect.width, b.rect.width), height: L(a.rect.height, b.rect.height))
        let opacity = L(a.k.opacity, b.k.opacity)
        let zoom = max(1, L(a.k.innerZoom, b.k.innerZoom))
        let full = uq == 0 ? a.full : (uq == 600 ? b.full : (a.full && b.full))
        if opacity <= 0.002 { return nil }

        let key = ia * 100_000 + ib * 1000 + uq
        lock.lock(); var bundle = cache[key]; lock.unlock()
        if bundle == nil {
            bundle = buildBundle(a: a, b: b, u: u, rect: rect)
            lock.lock(); if cache.count > 40 { cache.removeAll() }; cache[key] = bundle; lock.unlock()
        }
        guard let bd = bundle else { return nil }

        // Place the camera frame: aspect-fill the rect, inner zoom, optional mirror.
        var cam = cam0
        if cam.extent.origin != .zero { cam = cam.transformed(by: CGAffineTransform(translationX: -cam.extent.minX, y: -cam.extent.minY)) }
        let cw = cam.extent.width, ch = cam.extent.height
        guard cw > 0, ch > 0 else { return nil }
        let s = max(rect.width / cw, rect.height / ch) * CGFloat(zoom)
        let cxp = rect.midX, cyp = outH - rect.midY
        var m = CGAffineTransform(translationX: -cw / 2, y: -ch / 2)
        m = m.concatenating(CGAffineTransform(scaleX: mirror ? -s : s, y: s))
        m = m.concatenating(CGAffineTransform(translationX: cxp, y: cyp))
        let placed = cam.transformed(by: m)
            .applyingFilter("CISourceInCompositing", parameters: [kCIInputBackgroundImageKey: bd.mask])

        var shadow = bd.shadow
        let sa = (a.k.shadow ? 1.0 - u : 0) + (b.k.shadow ? u : 0)
        if sa < 0.999 {
            shadow = shadow.applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: CGFloat(sa))])
        }
        var layer = placed.composited(over: sa > 0.01 ? shadow : CIImage.empty())
        if let ring = bd.ring { layer = ring.composited(over: layer) }
        if opacity < 0.999 {
            layer = layer.applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: CGFloat(opacity))])
        }
        return (layer, full)
    }

    private func buildBundle(a: KF, b: KF, u: Double, rect: CGRect) -> Bundle? {
        let bw = CGFloat(a.k.borderWidth + (b.k.borderWidth - a.k.borderWidth) * u) * unit
        let margin = ceil(max(bw, 0) + 110 * unit)
        let w = Int(ceil(rect.width + 2 * margin)), h = Int(ceil(rect.height + 2 * margin))
        guard w > 0, h > 0, w < 12000, h < 12000 else { return nil }
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        func mk() -> CGContext? {
            CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        }
        guard let mctx = mk(), let sctx = mk(), let rctx = mk() else { return nil }
        let path = CGMutablePath()
        for i in 0..<CameraOutlines.count {
            let p0 = a.outline[i], p1 = b.outline[i]
            let ux = Double(p0.x) + (Double(p1.x) - Double(p0.x)) * u
            let uy = Double(p0.y) + (Double(p1.y) - Double(p0.y)) * u
            let p = CGPoint(x: margin + CGFloat(ux) * rect.width, y: margin + CGFloat(1 - uy) * rect.height)
            if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
        }
        path.closeSubpath()

        mctx.setFillColor(CGColor(colorSpace: cs, components: [1, 1, 1, 1])!)
        mctx.addPath(path); mctx.fillPath()

        let big = CGFloat(w) + 400
        sctx.saveGState()
        sctx.setShadow(offset: CGSize(width: -big, height: -16 * unit), blur: 46 * unit,
                       color: CGColor(colorSpace: cs, components: [0, 0, 0, 0.6])!)
        sctx.translateBy(x: big, y: 0)
        sctx.addPath(path)
        sctx.setFillColor(CGColor(colorSpace: cs, components: [0, 0, 0, 1])!)
        sctx.fillPath()
        sctx.restoreGState()

        var ring: CIImage?
        if bw >= 0.5 {
            let c0 = a.color, c1 = b.color
            let col = (c0.0 + (c1.0 - c0.0) * u, c0.1 + (c1.1 - c0.1) * u, c0.2 + (c1.2 - c0.2) * u)
            rctx.setStrokeColor(CGColor(colorSpace: cs, components: [col.0, col.1, col.2, 1])!)
            rctx.setLineWidth(bw * 2)
            rctx.setLineJoin(.round)
            // Clip to the OUTSIDE-and-inside band: draw the full stroke, then keep only half by clipping to
            // the path's even-odd complement? Simpler: stroke centered on the edge with width bw*2 and erase inside.
            rctx.addPath(path); rctx.strokePath()
            rctx.saveGState()
            rctx.setBlendMode(.destinationOut)
            rctx.addPath(path); rctx.setFillColor(CGColor(colorSpace: cs, components: [0, 0, 0, 1])!); rctx.fillPath()
            rctx.restoreGState()
            // Border grows outward; draw it also over the inner edge by a small overlap so no AA gap appears.
            if let img = rctx.makeImage() { ring = CIImage(cgImage: img) }
        }

        let ox = rect.minX - margin, oy = outH - rect.maxY - margin
        let tr = CGAffineTransform(translationX: ox, y: oy)
        guard let mi = mctx.makeImage(), let si = sctx.makeImage() else { return nil }
        return Bundle(mask: CIImage(cgImage: mi).transformed(by: tr), shadow: CIImage(cgImage: si).transformed(by: tr),
                      ring: ring?.transformed(by: tr), bounds: CGRect(x: ox, y: oy, width: CGFloat(w), height: CGFloat(h)))
    }
}
