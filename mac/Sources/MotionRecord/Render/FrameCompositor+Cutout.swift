import Foundation
import CoreGraphics
import CoreImage

/// Single-slot caches for the (usually constant) cut-out mask and shadow, so a steady cut-out costs nothing extra.
final class CutoutOverlayCache: @unchecked Sendable {
    private let lock = NSLock()
    private var maskKey = "", shadowKey = ""
    private var mask: CIImage?, shadow: CIImage?

    func mask(key: String, make: () -> CIImage) -> CIImage {
        lock.lock(); defer { lock.unlock() }
        if key == maskKey, let m = mask { return m }
        let m = make(); mask = m; maskKey = key
        return m
    }
    func shadow(key: String, make: () -> CIImage?) -> CIImage? {
        lock.lock(); defer { lock.unlock() }
        if key == shadowKey, let m = shadow { return m }
        let m = make(); shadow = m; shadowKey = key
        return m
    }
}

extension FrameCompositor {
    /// Zoom camera INSIDE a window cut-out (coordinates normalized to the window rect). Auto zoom is planned only from
    /// clicks inside the window rect at click time; manual regions use their focus if it falls inside the window.
    static func buildCutoutZoom(_ rt: CutoutRuntime, project: EditProject, meta: RecordingMetadata, map: SegmentMap,
                                cursor: SmoothedCursorPath, display: CGSize, params: CameraParams,
                                outDur: Double, sourceDuration: Double) -> CameraTrack? {
        let c = rt.cutout
        var clicks: [ClickEvent] = []
        for k in meta.clicks {
            guard let ot = project.outputTime(forSource: k.t, sourceDuration: sourceDuration), ot >= c.start, ot <= c.end else { continue }
            let wr = rt.path.rect(at: k.t)
            guard wr.contains(CGPoint(x: k.x, y: k.y)) else { continue }
            var kk = k; kk.t = ot
            kk.x = (k.x - wr.minX) / wr.width; kk.y = (k.y - wr.minY) / wr.height
            clicks.append(kk)
        }
        var manual: [ZoomRegion] = []
        for r in project.zoomRegions where r.start >= c.start - 0.001 && r.start <= c.end {
            var rr = r
            let wr = rt.path.rect(at: map.lookup(output: min(max(r.start, c.start), c.end)).src)
            let p = CGPoint(x: r.focusX * display.width, y: r.focusY * display.height)
            if wr.contains(p) { rr.focusX = (p.x - wr.minX) / wr.width; rr.focusY = (p.y - wr.minY) / wr.height }
            else { rr.focusX = 0.5; rr.focusY = 0.5 }
            manual.append(rr)
        }
        var params = params                       // snappier zoom inside a window cut-out
        params.zoomDuration = max(0.25, params.zoomDuration * 0.7)
        params.zoomHold = max(0.4, params.zoomHold * 0.85)
        let pers = CameraPlanner.plan(autoClicks: clicks, manual: manual, pointSize: CGSize(width: 1, height: 1),
                                      params: params, autoZoom: project.render.autoZoom)
            .compactMap { VideoRenderer.clampPeriod($0, to: outDur) }
        guard !pers.isEmpty else { return nil }
        return CameraPlanner.buildTrack(periods: pers, cursorAt: { t in
            let src = map.lookup(output: t).src
            guard !cursor.isEmpty else { return nil }
            let p = cursor.position(at: src), wr = rt.path.rect(at: src)
            return CGPoint(x: min(max((p.x - wr.minX) / wr.width, 0), 1), y: min(max((p.y - wr.minY) / wr.height, 0), 1))
        }, pointSize: CGSize(width: 1, height: 1), params: params, duration: outDur)
    }

    /// Rounded-rect mask covering `bbox` (integral, CI coords) with the (fractional) `dest` rect filled.
    static func makeDestMask(bbox: CGRect, dest: CGRect, radius: CGFloat) -> CIImage {
        let w = max(Int(bbox.width), 1), h = max(Int(bbox.height), 1)
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(colorSpace: cs, components: [1, 1, 1, 1])!)
        let r = min(max(radius, 0), min(dest.width, dest.height) / 2)
        ctx.addPath(CGPath(roundedRect: dest.offsetBy(dx: -bbox.minX, dy: -bbox.minY), cornerWidth: r, cornerHeight: r, transform: nil))
        ctx.fillPath()
        return CIImage(cgImage: ctx.makeImage()!).transformed(by: CGAffineTransform(translationX: bbox.minX, y: bbox.minY))
    }

    func makeDestShadow(dest: CGRect, radius: CGFloat, strength: Double) -> CIImage? {
        // The shadow is only visible outside the window: nothing to draw once the window covers the whole canvas.
        if dest.contains(outRect) { return nil }
        let unit = dest.width / 1920
        let margin = ceil(190 * unit) + 4
        let box = dest.insetBy(dx: -margin, dy: -margin).integral.intersection(outRect)
        guard !box.isNull, box.width >= 1, box.height >= 1 else { return nil }
        // The shadow is very soft, so it is drawn at quarter resolution and scaled up (≈16x cheaper per frame).
        let q: CGFloat = 0.25
        let w = max(Int(ceil(box.width * q)), 1), h = max(Int(ceil(box.height * q)), 1)
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let local = dest.offsetBy(dx: -box.minX, dy: -box.minY)
        let small = CGRect(x: local.minX * q, y: local.minY * q, width: local.width * q, height: local.height * q)
        FrameCompositor.drawShadow(ctx: ctx, cs: cs, content: small, radius: radius * q, style: style, strength: strength)
        guard let img = ctx.makeImage() else { return nil }
        let sx = box.width / CGFloat(w), sy = box.height / CGFloat(h)
        return CIImage(cgImage: img)
            .transformed(by: CGAffineTransform(scaleX: sx, y: sy).concatenating(CGAffineTransform(translationX: box.minX, y: box.minY)))
            .cropped(to: box)
    }

    /// Frame while at least one window cut-out is (partly) active: the viewport/destination rect/corner radius are
    /// interpolated from the (camera-zoomed) whole-screen look to the window look, so the window "pops out" of the screen.
    func renderCutout(source: CIImage, t: Double, srcT: Double,
                      m: (src: Double, speed: Double, segSrcStart: Double), active: [(index: Int, w: Double)]) -> CIImage {
        let cam = camera.sample(at: t)
        var look = WindowCutoutMath.screenLook(contentRect: contentRect, display: pointSize, cx: cam.cx, cy: cam.cy, zoom: cam.z,
                                               radiusPx: Double(baseRadiusPx), shadow: settings.shadow ? 1 : 0)
        for a in active {
            let rt = cutouts[a.index]
            var zoom: (cx: Double, cy: Double, z: Double)?
            if let zt = rt.zoom { let z = zt.sample(at: t); zoom = (z.cx, z.cy, z.z) }
            let wl = WindowCutoutMath.windowLook(rect: rt.path.rect(at: srcT), cutout: rt.cutout, outSize: outSize, zoom: zoom)
            look = CutoutLook.blend(look, wl, a.w)
        }
        if !settings.shadow { look.shadow = 0 }

        let dest = look.dest
        let k = CGFloat(look.scale)
        let ppx = srcW / max(pointSize.width, 1), ppy = srcH / max(pointSize.height, 1)
        let scx = k / ppx, scy = k / ppy
        let tx = dest.minX - look.src.minX * k
        let ty = dest.maxY + look.src.minY * k - srcH * scy

        var base = source
        if base.extent.origin != .zero {
            base = base.transformed(by: CGAffineTransform(translationX: -base.extent.minX, y: -base.extent.minY))
        }
        var img = base
        if abs(scx - 1) > 0.0005 || abs(scy - 1) > 0.0005 {
            let name = scy < 1 ? "CILanczosScaleTransform" : "CIBicubicScaleTransform"
            if let f = CIFilter(name: name) {
                f.setValue(img, forKey: kCIInputImageKey)
                f.setValue(scy, forKey: kCIInputScaleKey)
                f.setValue(scx / scy, forKey: kCIInputAspectRatioKey)
                img = f.outputImage ?? img.transformed(by: CGAffineTransform(scaleX: scx, y: scy))
            } else {
                img = img.transformed(by: CGAffineTransform(scaleX: scx, y: scy))
            }
        }
        img = img.transformed(by: CGAffineTransform(translationX: tx, y: ty))

        if drawCursor {
            let viewport = look.src
            let toOut: (CGPoint) -> CGPoint = { p in
                let sp = self.srcPixel(fromPoint: p)
                return CGPoint(x: sp.x * scx + tx, y: sp.y * scy + ty)
            }
            img = overlayCursor(on: img, srcT: srcT, m: m, toOut: toOut, outPxPerPoint: pxPerPointSrc * scx,
                                visibility: { WindowCutoutMath.visibility(of: $0, in: viewport) })
        }

        let bbox = dest.integral.intersection(outRect)
        let key = String(format: "%.2f,%.2f,%.2f,%.2f,%.2f", dest.minX, dest.minY, dest.width, dest.height, look.radiusPx)
        let maskImg = overlayCache.mask(key: key) {
            FrameCompositor.makeDestMask(bbox: bbox, dest: dest, radius: CGFloat(look.radiusPx))
        }
        let clipped = img.cropped(to: bbox)
            .applyingFilter("CISourceInCompositing", parameters: [kCIInputBackgroundImageKey: maskImg])
        var bg = plainBackdrop
        if style.cutoutScreenBackdrop {
            // The recorded screen itself (desktop wallpaper) stays behind the window, full-bleed.
            let fill = max(outSize.width / srcW, outSize.height / srcH)
            var wall = base.transformed(by: CGAffineTransform(scaleX: fill, y: fill))
            let e = wall.extent
            wall = wall.transformed(by: CGAffineTransform(translationX: (outSize.width - e.width) / 2 - e.minX,
                                                          y: (outSize.height - e.height) / 2 - e.minY)).cropped(to: outRect)
            bg = wall
        } else if blurredBackground { bg = plainBackdrop.composited(over: blurredBackdrop(from: base)) }
        if look.shadow > 0.01, style.shadowIntensity > 0.001,
           let sh = overlayCache.shadow(key: key + String(format: ",%.3f", look.shadow), make: {
               self.makeDestShadow(dest: dest, radius: CGFloat(look.radiusPx), strength: look.shadow) }) {
            bg = sh.composited(over: bg)
        }
        return clipped.composited(over: bg)
    }
}
