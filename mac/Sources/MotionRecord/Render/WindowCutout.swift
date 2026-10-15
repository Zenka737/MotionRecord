import Foundation
import CoreGraphics

// Pure logic for the "window cut-out" feature (no CoreImage / AVFoundation). Everything is deterministic and
// random-access, like the camera track.

/// Geometry of one frame state: which part of the display (POINTS, origin top-left) is shown, and where it is
/// drawn on the canvas (pixels, CoreImage coordinates = origin BOTTOM-left). Uniform scale, so the content is never stretched.
struct CutoutLook: Equatable {
    var src: CGRect          // viewport in display points, top-left origin
    var scale: Double        // canvas px per display point
    var center: CGPoint      // destination center, canvas px, bottom-left origin
    var radiusPx: Double     // corner radius in canvas px
    var shadow: Double       // 0...1 multiplier of the shadow strength

    var dest: CGRect {
        let w = src.width * scale, h = src.height * scale
        return CGRect(x: center.x - w / 2, y: center.y - h / 2, width: w, height: h)
    }

    static func blend(_ a: CutoutLook, _ b: CutoutLook, _ w: Double) -> CutoutLook {
        let k = Easing.clamp01(w)
        func l(_ x: CGFloat, _ y: CGFloat) -> CGFloat { x + (y - x) * CGFloat(k) }
        return CutoutLook(src: CGRect(x: l(a.src.minX, b.src.minX), y: l(a.src.minY, b.src.minY),
                                      width: l(a.src.width, b.src.width), height: l(a.src.height, b.src.height)),
                          scale: Easing.lerp(a.scale, b.scale, k),
                          center: CGPoint(x: l(a.center.x, b.center.x), y: l(a.center.y, b.center.y)),
                          radiusPx: Easing.lerp(a.radiusPx, b.radiusPx, k),
                          shadow: Easing.lerp(a.shadow, b.shadow, k))
    }
}

/// Smoothed, uniformly sampled window rect path in SOURCE time (display points, top-left origin).
struct WindowRectPath {
    let hz: Double
    let xs: [Double], ys: [Double], ws: [Double], hs: [Double]

    func rect(at t: Double) -> CGRect {
        guard xs.count > 1 else { return CGRect(x: xs.first ?? 0, y: ys.first ?? 0, width: ws.first ?? 1, height: hs.first ?? 1) }
        let f = min(max(t * hz, 0), Double(xs.count - 1))
        let i = min(Int(f), xs.count - 2)
        let a = f - Double(i)
        func m(_ v: [Double]) -> Double { v[i] * (1 - a) + v[i + 1] * a }
        return CGRect(x: m(xs), y: m(ys), width: m(ws), height: m(hs))
    }
}

enum WindowCutoutMath {
    static let pathHz = 120.0
    static let minSide: Double = 24     // points; windows smaller than this are not cut out

    // MARK: window rect

    @inline(__always) static func rect(_ s: WindowSample) -> CGRect { CGRect(x: s.x, y: s.y, width: s.w, height: s.h) }

    /// Index of the last sample with t <= `t`, nil when `t` is before the first sample.
    static func sampleIndex(_ ss: [WindowSample], at t: Double) -> Int? {
        guard let first = ss.first, t >= first.t else { return nil }
        var lo = 0, hi = ss.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if ss[mid].t <= t { lo = mid } else { hi = mid - 1 }
        }
        return lo
    }

    /// Is the window on screen at source time t?
    static func isVisible(_ track: WindowTrack, at t: Double) -> Bool {
        guard let i = sampleIndex(track.samples, at: t) else { return false }
        return track.samples[i].visible
    }

    /// Raw (unsmoothed, unclamped) rect at source time `t`. Between two visible samples the move happens during
    /// the last `moveWindow` seconds before the later sample (samples are written only on change, so a long gap means
    /// "stood still, then moved"). While the window is not visible the last known rect is held; before the first
    /// sample the first visible rect is used. nil only if the track never was visible.
    static func rawRect(of track: WindowTrack, at t: Double) -> CGRect? {
        let ss = track.samples
        guard !ss.isEmpty else { return nil }
        guard let i = sampleIndex(ss, at: t) else {
            return ss.first(where: { $0.visible }).map(rect)
        }
        if ss[i].visible {
            if i + 1 < ss.count, ss[i + 1].visible {
                let t0 = ss[i].t, t1 = ss[i + 1].t
                let d = min(max(t1 - t0, 1e-6), 0.12)
                let u = Easing.clamp01((t - (t1 - d)) / d)
                let a = rect(ss[i]), b = rect(ss[i + 1])
                let uu = CGFloat(u)
                return CGRect(x: a.minX + (b.minX - a.minX) * uu, y: a.minY + (b.minY - a.minY) * uu,
                              width: a.width + (b.width - a.width) * uu, height: a.height + (b.height - a.height) * uu)
            }
            return rect(ss[i])
        }
        var j = i - 1
        while j >= 0 && !ss[j].visible { j -= 1 }
        if j >= 0 { return rect(ss[j]) }
        return ss.first(where: { $0.visible }).map(rect)
    }

    /// Clamp a rect to the display (points). Returns nil if nothing usable remains.
    static func clamp(_ r: CGRect, display: CGSize) -> CGRect? {
        let d = CGRect(x: 0, y: 0, width: display.width, height: display.height)
        let c = r.standardized.intersection(d)
        guard !c.isNull, c.width >= minSide, c.height >= minSide else { return nil }
        return c
    }

    /// Dense smoothed path for a track over [0, duration] (source seconds). Hold/clamp rules from `rawRect`/`clamp`.
    static func buildPath(track: WindowTrack, display: CGSize, duration: Double, smoothingTau: Double = 0.05) -> WindowRectPath? {
        guard rawRect(of: track, at: 0) != nil else { return nil }
        let n = Int(ceil(max(duration, 0.01) * pathHz)) + 2
        let dt = 1.0 / pathHz
        var xs = [Double](repeating: 0, count: n), ys = xs, ws = xs, hs = xs
        let full = CGRect(origin: .zero, size: display)
        var last = full
        for i in 0..<n {
            let t = Double(i) * dt
            if let r = rawRect(of: track, at: t), let c = clamp(r, display: display) { last = c }
            xs[i] = last.minX; ys[i] = last.minY; ws[i] = last.width; hs[i] = last.height
        }
        if smoothingTau > 0.002 {
            for _ in 0..<2 {
                xs = CursorSmoother.forwardBackward(xs, tau: smoothingTau, dt: dt)
                ys = CursorSmoother.forwardBackward(ys, tau: smoothingTau, dt: dt)
                ws = CursorSmoother.forwardBackward(ws, tau: smoothingTau, dt: dt)
                hs = CursorSmoother.forwardBackward(hs, tau: smoothingTau, dt: dt)
            }
        }
        return WindowRectPath(hz: pathHz, xs: xs, ys: ys, ws: ws, hs: hs)
    }

    // MARK: cutout factor

    /// Effective ramp length of a cutout (never more than half its length).
    static func ramp(_ c: WindowCutout) -> Double { min(max(c.transition, 0), max(c.end - c.start, 0) / 2) }

    /// 0 (whole screen) ... 1 (window only) at OUTPUT time t for one cutout.
    static func factor(_ c: WindowCutout, at t: Double) -> Double {
        guard c.end > c.start, t >= c.start, t <= c.end else { return 0 }
        let r = ramp(c)
        if r < 1e-4 { return 1 }
        return Easing.smootherstep(min((t - c.start) / r, (c.end - t) / r))
    }

    /// Active cutouts (factor > 0) sorted by start (later start = applied last = wins).
    static func active(_ cutouts: [WindowCutout], at t: Double) -> [(index: Int, w: Double)] {
        var r: [(Int, Double)] = []
        for (i, c) in cutouts.enumerated() {
            let w = factor(c, at: t)
            if w > 0.0005 { r.append((i, w)) }
        }
        return r.sorted { cutouts[$0.0].start < cutouts[$1.0].start }.map { (index: $0.0, w: $0.1) }
    }

    // MARK: looks

    /// Whole-screen content rect on the canvas (CI coordinates, bottom-left origin). Same math as the compositor.
    static func contentRect(outSize: CGSize, srcSize: CGSize, padding: Double) -> CGRect {
        let outW = outSize.width, outH = outSize.height
        let k = 1 - 2 * min(max(padding, 0), 0.3)
        var cw = (outW * k).rounded()
        var ch = (cw * srcSize.height / srcSize.width).rounded()
        if ch > outH * k + 1 { ch = (outH * k).rounded(); cw = (ch * srcSize.width / srcSize.height).rounded() }
        let cx = ((outW - cw) / 2).rounded(), cy = ((outH - ch) / 2).rounded()
        return CGRect(x: cx, y: cy, width: max(cw, 2), height: max(ch, 2))
    }

    /// Look of the normal screen (optionally zoomed by the camera: normalized center, zoom >= 1).
    static func screenLook(contentRect: CGRect, display: CGSize, cx: Double = 0.5, cy: Double = 0.5, zoom: Double = 1,
                           radiusPx: Double, shadow: Double) -> CutoutLook {
        let z = max(zoom, 1)
        let w = display.width / z, h = display.height / z
        let src = CGRect(x: cx * display.width - w / 2, y: cy * display.height - h / 2, width: w, height: h)
        return CutoutLook(src: src, scale: Double(contentRect.width) / Double(w),
                          center: CGPoint(x: contentRect.midX, y: contentRect.midY), radiusPx: radiusPx, shadow: shadow)
    }

    /// Where (canvas px, bottom-left origin) the window is fitted when fully cut out: aspect preserved, centered,
    /// inside the canvas minus `padding` * canvas width on every side.
    static func windowDest(rect: CGRect, padding: Double, outSize: CGSize) -> (center: CGPoint, scale: Double) {
        let pad = min(max(padding, 0), 0.2) * Double(outSize.width)
        let bw = max(Double(outSize.width) - 2 * pad, 8), bh = max(Double(outSize.height) - 2 * pad, 8)
        let s = min(bw / Double(max(rect.width, 1)), bh / Double(max(rect.height, 1)))
        return (CGPoint(x: outSize.width / 2, y: outSize.height / 2), s)
    }

    /// `zoom` = (cx, cy normalized WITHIN the window rect, zoom >= 1): the viewport is a crop inside the window,
    /// the destination rect stays the same (window fitted on the canvas).
    static func windowLook(rect: CGRect, cutout c: WindowCutout, outSize: CGSize,
                           zoom: (cx: Double, cy: Double, z: Double)? = nil) -> CutoutLook {
        let d = windowDest(rect: rect, padding: c.padding, outSize: outSize)
        // Chroma-key style zoom: the whole window (its own shape, rounded corners and shadow) is magnified like a normal
        // camera zoom around the zoom point; everything that is not the window is just the background, so the background
        // never covers the window and the picture is never cropped by a fixed frame.
        var sc = d.scale
        var center = d.center
        if let zm = zoom, zm.z > 1.0001 {
            let z = zm.z
            sc = d.scale * z
            let w = Double(rect.width) * sc, h = Double(rect.height) * sc
            // Put the zoom point (normalized inside the window, top-left origin) at the canvas center.
            var cx = Double(d.center.x) - (zm.cx - 0.5) * w
            var cy = Double(d.center.y) + (zm.cy - 0.5) * h
            // While the magnified window is larger than the canvas it always covers it (no background sliver at its edges).
            let cw = Double(outSize.width), ch = Double(outSize.height)
            if w >= cw { cx = min(max(cx, cw - w / 2), w / 2) }
            if h >= ch { cy = min(max(cy, ch - h / 2), h / 2) }
            center = CGPoint(x: cx, y: cy)
        }
        return CutoutLook(src: rect, scale: sc, center: center,
                          radiusPx: max(0, c.cornerRadius) * sc, shadow: c.shadow ? 1 : 0)
    }

    /// Distance (points) from `p` to `r` (0 when inside).
    static func distance(from p: CGPoint, to r: CGRect) -> Double {
        let dx = max(r.minX - p.x, 0, p.x - r.maxX), dy = max(r.minY - p.y, 0, p.y - r.maxY)
        return Double(hypot(dx, dy))
    }

    /// Opacity of the cursor / ripples for a point relative to the visible viewport: 1 inside, fading out over `fade` points.
    static func visibility(of p: CGPoint, in viewport: CGRect, fade: Double = 36) -> Double {
        1 - Easing.smoothstep(distance(from: p, to: viewport) / fade)
    }

    // MARK: self check

    /// Returns a list of failure descriptions (empty = all good).
    static func selfCheck() -> [String] {
        var bad: [String] = []
        func chk(_ ok: Bool, _ s: String) { if !ok { bad.append(s) } }
        let tr = WindowTrack(id: 1, app: "A", title: "", pid: 1, samples: [
            WindowSample(t: 1, x: 100, y: 100, w: 400, h: 300, z: 0),
            WindowSample(t: 3, x: 300, y: 100, w: 400, h: 300, z: 0),
            WindowSample(t: 5, x: 300, y: 100, w: 400, h: 300, z: 0, visible: false),
            WindowSample(t: 7, x: 0, y: 0, w: 10, h: 10, z: 1, visible: true)])
        chk(rawRect(of: tr, at: 0)?.minX == 100, "before first holds first")
        chk(rawRect(of: tr, at: 2)?.minX == 100, "still until move window")
        chk(abs((rawRect(of: tr, at: 2.999)?.minX ?? 0) - 300) < 2, "moved by end of window")
        chk(rawRect(of: tr, at: 3.5)?.minX == 300, "after move")
        chk(rawRect(of: tr, at: 6)?.minX == 300 && !isVisible(tr, at: 6), "hold last rect while hidden")
        chk(isVisible(tr, at: 2) && !isVisible(tr, at: 0.5), "visibility")
        chk(clamp(CGRect(x: -50, y: -50, width: 200, height: 200), display: CGSize(width: 960, height: 540)) == CGRect(x: 0, y: 0, width: 150, height: 150), "clamp")
        let c = WindowCutout(start: 2, end: 6, windowID: 1, transition: 1)
        chk(factor(c, at: 1.9) == 0 && factor(c, at: 2) < 0.01 && abs(factor(c, at: 2.5) - 0.5) < 1e-9 && factor(c, at: 4) == 1
            && abs(factor(c, at: 5.5) - 0.5) < 1e-9 && factor(c, at: 6.1) == 0, "cutout factor")
        let short = WindowCutout(start: 0, end: 1, windowID: 1, transition: 5)
        chk(abs(factor(short, at: 0.5) - 1) < 1e-9 && factor(short, at: 0.25) < 1, "ramp capped at half")
        var late = c; late.start = 3; late.end = 8
        chk(active([c, late], at: 4).map { $0.index } == [0, 1], "nested order by start")
        let out = CGSize(width: 1920, height: 1080), disp = CGSize(width: 960, height: 540)
        let cr = contentRect(outSize: out, srcSize: CGSize(width: 1920, height: 1080), padding: 0.05)
        let a = screenLook(contentRect: cr, display: disp, radiusPx: 30, shadow: 1)
        let b = windowLook(rect: CGRect(x: 100, y: 100, width: 400, height: 300), cutout: c, outSize: out)
        chk(CutoutLook.blend(a, b, 0) == a && CutoutLook.blend(a, b, 1) == b, "blend endpoints")
        chk(abs(a.dest.width - cr.width) < 1e-6 && abs(a.dest.minX - cr.minX) < 1e-6, "screen look dest == content rect")
        let bd = b.dest
        chk(abs(bd.midX - 960) < 1e-6 && abs(bd.midY - 540) < 1e-6 && bd.height <= 1080 * 1.0001 && abs(bd.width / bd.height - 4.0 / 3) < 1e-9, "window dest centered, aspect kept")
        chk(abs(visibility(of: CGPoint(x: 50, y: 50), in: CGRect(x: 0, y: 0, width: 100, height: 100)) - 1) < 1e-9
            && visibility(of: CGPoint(x: 200, y: 50), in: CGRect(x: 0, y: 0, width: 100, height: 100)) == 0, "cursor visibility")
        return bad
    }
}
