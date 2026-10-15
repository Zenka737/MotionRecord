import Foundation
import CoreGraphics

struct CameraParams {
    var zoomScale: Double
    var zoomDuration: Double
    var zoomHold: Double
    var cameraSmoothing: Double

    init(_ s: RenderSettings) {
        zoomScale = max(1.0, s.zoomScale)
        zoomDuration = max(0.1, s.zoomDuration)
        zoomHold = max(0.1, s.zoomHold)
        cameraSmoothing = Easing.clamp01(s.cameraSmoothing)
    }
}

/// One continuous zoomed-in period (a cluster of nearby-in-time clicks).
struct ZoomPeriod {
    var start: Double      // zoom-in ramp begins
    var holdEnd: Double    // zoom-out ramp begins
    var outEnd: Double     // zoom-out ramp ends
    var focus: CGPoint     // normalized (0...1, top-left origin) initial camera center
    var scale: Double = 0  // 0 = use CameraParams.zoomScale
    var ramp: Double = 0   // 0 = use CameraParams.zoomDuration
    var follow: Bool = true
    var manual: Bool = false
}

/// Precomputed, random-access camera track. cx/cy are normalized (0...1, top-left origin) and are
/// already clamped so the view rectangle stays inside the frame.
struct CameraTrack {
    let hz: Double
    let cx: [Double]
    let cy: [Double]
    let z: [Double]

    static let identity = CameraTrack(hz: 1, cx: [0.5, 0.5], cy: [0.5, 0.5], z: [1, 1])

    func sample(at t: Double) -> (cx: Double, cy: Double, z: Double) {
        let f = min(max(t * hz, 0), Double(z.count - 1))
        let i = min(Int(f), z.count - 2)
        let a = f - Double(i)
        return (cx[i] * (1 - a) + cx[i + 1] * a, cy[i] * (1 - a) + cy[i + 1] * a, z[i] * (1 - a) + z[i + 1] * a)
    }

    var isIdentity: Bool { z.allSatisfy { $0 <= 1.0000001 } }
}

enum CameraPlanner {
    static let hz: Double = 240

    /// How far before the click the zoom-in begins (so the click happens as the zoom settles).
    static func lead(_ p: CameraParams) -> Double { min(0.35, p.zoomDuration * 0.5) }

    static func periods(clicks: [ClickEvent], pointSize: CGSize, params p: CameraParams) -> [ZoomPeriod] {
        let downs = clicks.filter { $0.isDown }.sorted { $0.t < $1.t }
        guard !downs.isEmpty, pointSize.width > 0, pointSize.height > 0 else { return [] }
        let ld = lead(p)
        func norm(_ c: ClickEvent) -> CGPoint { CGPoint(x: c.x / pointSize.width, y: c.y / pointSize.height) }

        var groups: [[ClickEvent]] = []
        var curEnd = -Double.infinity
        for c in downs {
            let start = max(0, c.t - ld)
            // Merge when there is not enough room to fully zoom out and back in.
            if !groups.isEmpty && start < curEnd + p.zoomDuration {
                groups[groups.count - 1].append(c)
            } else {
                groups.append([c])
            }
            curEnd = max(c.t + p.zoomHold, max(0, groups[groups.count - 1][0].t - ld) + p.zoomDuration)
        }
        return groups.map { g in
            let first = g[0], last = g[g.count - 1]
            let start = max(0, first.t - ld)
            let holdEnd = max(last.t + p.zoomHold, start + p.zoomDuration)
            // Focus = centroid of the first sub-cluster (close in time and space).
            let f0 = norm(first)
            let near = g.filter { $0.t - first.t < p.zoomHold && hypot(norm($0).x - f0.x, norm($0).y - f0.y) < 0.25 }
            let fx = near.map { norm($0).x }.reduce(0, +) / Double(near.count)
            let fy = near.map { norm($0).y }.reduce(0, +) / Double(near.count)
            return ZoomPeriod(start: start, holdEnd: holdEnd, outEnd: holdEnd + p.zoomDuration, focus: CGPoint(x: fx, y: fy))
        }
    }

    /// Zoom progress 0...1 (eased) for a period at time t.
    static func progress(_ per: ZoomPeriod, at t: Double, params p: CameraParams) -> Double {
        let ramp = max(per.ramp > 0 ? per.ramp : p.zoomDuration, 0.02)
        if t <= per.start { return 0 }
        if t < per.holdEnd {
            return Easing.smootherstep((t - per.start) / ramp)
        }
        if t >= per.outEnd { return 0 }
        // Out ramp, but never exceed the in-ramp value if the period was extremely short.
        let inV = Easing.smootherstep((per.holdEnd - per.start) / ramp)
        return inV * (1 - Easing.smootherstep((t - per.holdEnd) / ramp))
    }

    static func clampCenter(_ c: Double, zoom: Double) -> Double {
        let h = 0.5 / max(zoom, 1)
        return min(max(c, h), 1 - h)
    }

    /// Merges auto periods (from clicks in OUTPUT time) with manual regions (manual wins on overlap).
    static func plan(autoClicks: [ClickEvent], manual: [ZoomRegion], pointSize: CGSize,
                     params p: CameraParams, autoZoom: Bool) -> [ZoomPeriod] {
        var man: [ZoomPeriod] = []
        for r in manual where r.end - r.start > 0.05 && r.scale > 1.001 {
            let ramp = min(p.zoomDuration, (r.end - r.start) / 2)
            man.append(ZoomPeriod(start: max(0, r.start), holdEnd: r.end - ramp, outEnd: r.end,
                                  focus: CGPoint(x: Easing.clamp01(r.focusX), y: Easing.clamp01(r.focusY)),
                                  scale: r.scale, ramp: ramp, follow: r.followCursor, manual: true))
        }
        var auto: [ZoomPeriod] = []
        if autoZoom && p.zoomScale > 1.001 {
            auto = periods(clicks: autoClicks, pointSize: pointSize, params: p).filter { a in
                !man.contains { a.start < $0.outEnd && a.outEnd > $0.start }
            }
        }
        var all = (man + auto).sorted { $0.start < $1.start }
        var i = 0
        while i + 1 < all.count {
            if all[i + 1].start < all[i].outEnd {
                all[i].outEnd = all[i + 1].start
                all[i].holdEnd = min(all[i].holdEnd, all[i].outEnd)
                if all[i].outEnd - all[i].start < 0.05 { all.remove(at: i); continue }
            }
            i += 1
        }
        return all
    }

    /// Camera track in the time domain of `periods` (OUTPUT time). `cursorAt` gives the smoothed cursor
    /// position (points) at an output time, or nil when there is no cursor data.
    static func buildTrack(periods pers: [ZoomPeriod], cursorAt: (Double) -> CGPoint?, pointSize: CGSize,
                           params p: CameraParams, duration: Double) -> CameraTrack {
        let n = Int(ceil(max(duration, 0.01) * hz)) + 2
        let dt = 1.0 / hz
        guard !pers.isEmpty, pointSize.width > 0, pointSize.height > 0 else {
            return CameraTrack(hz: hz, cx: [Double](repeating: 0.5, count: n), cy: [Double](repeating: 0.5, count: n),
                               z: [Double](repeating: 1, count: n))
        }
        // Spring stiffness: cameraSmoothing 0 -> snappy (tau .05 s), 1 -> floaty (tau .45 s).
        let tau = 0.05 + 0.40 * p.cameraSmoothing
        let omega = 1.0 / tau

        var cxs = [Double](repeating: 0.5, count: n)
        var cys = [Double](repeating: 0.5, count: n)
        var zs = [Double](repeating: 1, count: n)

        var tcx = 0.5, tcy = 0.5
        var ccx = 0.5, ccy = 0.5
        var vx = 0.0, vy = 0.0
        var activeIdx = -1
        var pi = 0

        for i in 0..<n {
            let t = Double(i) * dt
            while pi < pers.count && t >= pers[pi].outEnd { pi += 1 }
            var f = 0.0
            var scale = p.zoomScale
            if pi < pers.count && t >= pers[pi].start {
                let per = pers[pi]
                scale = per.scale > 1.001 ? per.scale : p.zoomScale
                let hv = 0.5 / scale
                let dead = 0.45 * hv
                f = progress(per, at: t, params: p)
                if activeIdx != pi {
                    activeIdx = pi
                    tcx = clampCenter(Double(per.focus.x), zoom: scale)
                    tcy = clampCenter(Double(per.focus.y), zoom: scale)
                    ccx = tcx; ccy = tcy; vx = 0; vy = 0
                }
                if per.follow && t < per.holdEnd, let c = cursorAt(t) {
                    let nx = Double(c.x) / Double(pointSize.width), ny = Double(c.y) / Double(pointSize.height)
                    if nx - tcx > dead { tcx = nx - dead } else if tcx - nx > dead { tcx = nx + dead }
                    if ny - tcy > dead { tcy = ny - dead } else if tcy - ny > dead { tcy = ny + dead }
                    tcx = clampCenter(tcx, zoom: scale)
                    tcy = clampCenter(tcy, zoom: scale)
                }
                let ax = omega * omega * (tcx - ccx) - 2 * omega * vx
                let ay = omega * omega * (tcy - ccy) - 2 * omega * vy
                vx += ax * dt; vy += ay * dt
                ccx += vx * dt; ccy += vy * dt
            }
            let zoom = 1 + (scale - 1) * f
            zs[i] = zoom
            cxs[i] = clampCenter(Easing.lerp(0.5, ccx, f), zoom: zoom)
            cys[i] = clampCenter(Easing.lerp(0.5, ccy, f), zoom: zoom)
        }
        return CameraTrack(hz: hz, cx: cxs, cy: cys, z: zs)
    }
}
