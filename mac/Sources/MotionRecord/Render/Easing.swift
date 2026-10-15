import Foundation

// Pure math helpers (no AVFoundation / CoreImage dependency).
enum Easing {
    @inline(__always) static func clamp01(_ x: Double) -> Double { min(max(x, 0), 1) }

    /// Ken Perlin's smootherstep: C2-continuous ease-in-out.
    @inline(__always) static func smootherstep(_ x: Double) -> Double {
        let t = clamp01(x)
        return t * t * t * (t * (t * 6 - 15) + 10)
    }

    @inline(__always) static func smoothstep(_ x: Double) -> Double {
        let t = clamp01(x)
        return t * t * (3 - 2 * t)
    }

    @inline(__always) static func easeOutCubic(_ x: Double) -> Double {
        let t = 1 - clamp01(x)
        return 1 - t * t * t
    }

    @inline(__always) static func lerp(_ a: Double, _ b: Double, _ t: Double) -> Double { a + (b - a) * t }
}
