import Foundation
import CoreGraphics

/// Uniformly sampled smoothed cursor path (positions in display POINTS, top-left origin).
struct SmoothedCursorPath {
    let hz: Double
    let xs: [Double]
    let ys: [Double]
    /// True when there was no cursor data at all (renderer should not draw a cursor).
    let isEmpty: Bool

    func position(at t: Double) -> CGPoint {
        guard xs.count > 1 else { return CGPoint(x: xs.first ?? 0, y: ys.first ?? 0) }
        let f = min(max(t * hz, 0), Double(xs.count - 1))
        let i = min(Int(f), xs.count - 2)
        let a = f - Double(i)
        return CGPoint(x: xs[i] * (1 - a) + xs[i + 1] * a, y: ys[i] * (1 - a) + ys[i + 1] * a)
    }
}

enum CursorSmoother {
    static let hz: Double = 240

    /// Maps cursorSmoothing 0...1 to the per-pass exponential time constant in seconds.
    static func timeConstant(forSmoothing s: Double) -> Double {
        let s = Easing.clamp01(s)
        return s * s * 0.10 + s * 0.10   // 0 ... 0.2 s (slightly non-linear: fine control at low values)
    }

    /// Zero-phase (forward+backward) low-pass of the dense raw samples, followed by a click-snap
    /// correction so the smoothed cursor lands EXACTLY on every click/release position at its timestamp.
    static func smooth(samples: [CursorSample], clicks: [ClickEvent], duration: Double,
                       smoothing: Double, fallback: CGPoint) -> SmoothedCursorPath {
        let raw = samples.sorted { $0.t < $1.t }
        var endT = duration
        if let l = raw.last { endT = max(endT, l.t) }
        if let l = clicks.map({ $0.t }).max() { endT = max(endT, l) }
        endT = max(endT, 0.01)
        let n = Int(ceil(endT * hz)) + 2
        let dt = 1.0 / hz

        var xs = [Double](repeating: fallback.x, count: n)
        var ys = [Double](repeating: fallback.y, count: n)
        if raw.isEmpty { return SmoothedCursorPath(hz: hz, xs: xs, ys: ys, isEmpty: true) }

        // Resample (linear) onto the uniform grid; clamp outside the raw range.
        var j = 0
        for i in 0..<n {
            let t = Double(i) * dt
            while j + 1 < raw.count && raw[j + 1].t <= t { j += 1 }
            if t <= raw[0].t { xs[i] = raw[0].x; ys[i] = raw[0].y; continue }
            if j + 1 >= raw.count { xs[i] = raw[raw.count - 1].x; ys[i] = raw[raw.count - 1].y; continue }
            let a = raw[j], b = raw[j + 1]
            let u = (t - a.t) / max(b.t - a.t, 1e-9)
            xs[i] = a.x + (b.x - a.x) * u
            ys[i] = a.y + (b.y - a.y) * u
        }

        let tau = timeConstant(forSmoothing: smoothing)
        if tau > 0.002 {
            // Two forward/backward cascades -> smooth (C2-ish), zero-lag kernel.
            let tp = tau * 0.65
            for _ in 0..<2 {
                xs = forwardBackward(xs, tau: tp, dt: dt)
                ys = forwardBackward(ys, tau: tp, dt: dt)
            }
        }

        // Snap to click positions with a smooth bump so clicks never visibly miss.
        let snaps = clicks.sorted { $0.t < $1.t }
        if !snaps.isEmpty {
            let halfWidth = 0.16 + tau * 0.8
            let wN = Int(halfWidth * hz)
            for _ in 0..<4 {
                for c in snaps {
                    let f = min(max(c.t * hz, 0), Double(n - 1))
                    let i0 = min(Int(f), n - 2)
                    let a = f - Double(i0)
                    let cx = xs[i0] * (1 - a) + xs[i0 + 1] * a
                    let cy = ys[i0] * (1 - a) + ys[i0 + 1] * a
                    let dx = c.x - cx, dy = c.y - cy
                    if abs(dx) < 1e-4 && abs(dy) < 1e-4 { continue }
                    let centerIdx = Int(f.rounded())
                    for k in max(0, centerIdx - wN)...min(n - 1, centerIdx + wN) {
                        let u = (Double(k) * dt - c.t) / halfWidth
                        if abs(u) >= 1 { continue }
                        let w = 0.5 * (1 + cos(Double.pi * u))
                        xs[k] += dx * w
                        ys[k] += dy * w
                    }
                }
            }
        }
        return SmoothedCursorPath(hz: hz, xs: xs, ys: ys, isEmpty: false)
    }

    static func forwardBackward(_ input: [Double], tau: Double, dt: Double) -> [Double] {
        guard input.count > 1 else { return input }
        let a = 1 - exp(-dt / tau)
        var out = input
        var y = input[0]
        for i in 0..<out.count { y += a * (out[i] - y); out[i] = y }
        y = out[out.count - 1]
        for i in stride(from: out.count - 1, through: 0, by: -1) { y += a * (out[i] - y); out[i] = y }
        return out
    }
}

/// Press / ripple timeline derived from click events (pure).
struct ClickTimeline {
    struct Press { var down: Double; var up: Double }
    let downs: [ClickEvent]
    let presses: [Press]

    init(clicks: [ClickEvent]) {
        let sorted = clicks.sorted { $0.t < $1.t }
        downs = sorted.filter { $0.isDown }
        var ps: [Press] = []
        for d in downs {
            let up = sorted.first { !$0.isDown && $0.button == d.button && $0.t >= d.t }?.t ?? (d.t + 0.12)
            ps.append(Press(down: d.t, up: max(up, d.t + 0.10)))
        }
        presses = ps
    }

    /// 0 = released, 1 = fully pressed (smoothly eased).
    func pressAmount(at t: Double) -> Double {
        var best = 0.0
        for p in presses {
            if t < p.down { break }
            if t > p.up + 0.2 { continue }
            let a = Easing.smoothstep((t - p.down) / 0.06)
            let r = 1 - Easing.smoothstep((t - p.up) / 0.14)
            best = max(best, a * r)
        }
        return best
    }

    /// Cursor scale multiplier from the click animation: eases down to `shrink` on mouse down, springs back
    /// (slight overshoot) on release.
    func clickScale(at t: Double, shrink: Double, duration: Double) -> Double {
        let D = max(duration, 0.03)
        let sh = min(max(shrink, 0.2), 1.5)
        for p in presses.reversed() where t >= p.down {
            let held = min(t, p.up)
            let v0 = 1 + (sh - 1) * Easing.easeOutCubic((held - p.down) / D)
            if t <= p.up { return v0 }
            let tau = t - p.up
            if tau > 0.6 { return 1 }
            let zeta = 0.4, omega = 40.0
            let wd = omega * (1 - zeta * zeta).squareRoot()
            let d = (v0 - 1) * exp(-zeta * omega * tau) * (cos(wd * tau) + zeta * omega / wd * sin(wd * tau))
            return 1 + d
        }
        return 1
    }
}
