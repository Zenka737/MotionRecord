import Foundation
import CoreGraphics
import CoreMedia

// Pure time/space conversion helpers for input tracking (no AppKit, unit-testable).

/// Host-time clock in seconds. This is the same clock SCStream uses for sample PTS
/// (CMClockGetHostTimeClock) and equals CACurrentMediaTime() (mach_absolute_time based).
enum HostClock {
    @inline(__always)
    static func now() -> Double { CMClockGetTime(CMClockGetHostTimeClock()).seconds }
}

struct RawCursorSample {
    var host: Double   // host clock seconds
    var x: Double      // global top-left points
    var y: Double
}

struct RawClick {
    var host: Double
    var x: Double      // global top-left points
    var y: Double
    var button: Int
    var isDown: Bool
}

enum InputTimeline {
    /// Converts raw host-clock cursor samples to display-local, video-relative samples.
    /// - displayOrigin: CGDisplayBounds(display).origin (global top-left points)
    /// - t0: PTS seconds of the first video frame; duration: video duration in seconds.
    /// Rules: positions clamped to the display; samples before t0 are collapsed into one sample at t=0;
    /// samples after `duration` are dropped; runs of identical positions keep only first+last sample;
    /// a sample is guaranteed at t=0 and at t=duration (when any raw samples exist).
    static func cursorTrack(raw: [RawCursorSample], displayOrigin: CGPoint, pointSize: CGSize,
                            t0: Double, duration: Double) -> [CursorSample] {
        guard !raw.isEmpty else { return [] }
        var out: [CursorSample] = []
        out.reserveCapacity(raw.count / 2)
        var lastBefore: CursorSample?

        func append(_ s: CursorSample) {
            if let last = out.last, last.x == s.x, last.y == s.y {
                if out.count >= 2, out[out.count - 2].x == s.x, out[out.count - 2].y == s.y {
                    out[out.count - 1] = s          // extend a stationary run: keep first + last
                } else {
                    out.append(s)
                }
            } else {
                out.append(s)
            }
        }

        for r in raw {
            let t = r.host - t0
            let x = min(max(r.x - Double(displayOrigin.x), 0), Double(pointSize.width))
            let y = min(max(r.y - Double(displayOrigin.y), 0), Double(pointSize.height))
            if t < 0 {
                lastBefore = CursorSample(t: 0, x: x, y: y)
                continue
            }
            if t > duration { break }
            if out.isEmpty, t > 0 {
                // guarantee a sample at t = 0
                let seed = lastBefore ?? CursorSample(t: 0, x: x, y: y)
                append(seed)
            }
            append(CursorSample(t: t, x: x, y: y))
        }
        if out.isEmpty, let lb = lastBefore { out.append(lb) }   // all samples were before t0
        if let last = out.last, last.t < duration {
            append(CursorSample(t: duration, x: last.x, y: last.y))
        }
        return out
    }

    /// Converts raw clicks. Clicks before t0 or after `duration` are dropped.
    static func clickEvents(raw: [RawClick], displayOrigin: CGPoint, pointSize: CGSize,
                            t0: Double, duration: Double) -> [ClickEvent] {
        raw.compactMap { c in
            let t = c.host - t0
            guard t >= 0, t <= duration else { return nil }
            let x = min(max(c.x - Double(displayOrigin.x), 0), Double(pointSize.width))
            let y = min(max(c.y - Double(displayOrigin.y), 0), Double(pointSize.height))
            return ClickEvent(t: t, x: x, y: y, button: c.button, isDown: c.isDown)
        }.sorted { $0.t < $1.t }
    }
}
