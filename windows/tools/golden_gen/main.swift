import Foundation
import CoreGraphics

// Generates golden values from the ORIGINAL macOS Swift logic; C# tests must reproduce them.
func r(_ x: Double) -> Double { (x * 1e9).rounded() / 1e9 }

var samples: [CursorSample] = []
var t = 0.0
while t <= 6.0 {
    let x = 960 + 700 * sin(t * 1.3) + (t > 3 ? 120 : 0)
    let y = 540 + 300 * cos(t * 0.9)
    samples.append(CursorSample(t: t, x: x, y: y))
    t += 1.0 / 120
}
let clicks: [ClickEvent] = [
    ClickEvent(t: 1.0, x: 400, y: 300, button: 0, isDown: true),
    ClickEvent(t: 1.1, x: 400, y: 300, button: 0, isDown: false),
    ClickEvent(t: 1.9, x: 520, y: 380, button: 0, isDown: true),
    ClickEvent(t: 2.0, x: 520, y: 380, button: 0, isDown: false),
    ClickEvent(t: 4.5, x: 1500, y: 800, button: 0, isDown: true),
    ClickEvent(t: 4.7, x: 1500, y: 800, button: 0, isDown: false),
]
let size = CGSize(width: 1920, height: 1080)
var out: [String: Any] = [:]
out["samples"] = samples.map { [$0.t, $0.x, $0.y] }
out["clicks"] = clicks.map { [$0.t, $0.x, $0.y, Double($0.button), $0.isDown ? 1.0 : 0.0] }

var smoothCases: [[String: Any]] = []
for s in [0.0, 0.5, 1.0] {
    let p = CursorSmoother.smooth(samples: samples, clicks: clicks, duration: 6, smoothing: s, fallback: CGPoint(x: 5, y: 6))
    let ts = [0.0, 0.5, 1.0, 1.05, 1.9, 2.5, 3.3, 4.5, 5.9]
    smoothCases.append(["smoothing": s, "count": p.xs.count, "tau": CursorSmoother.timeConstant(forSmoothing: s),
        "points": ts.map { let q = p.position(at: $0); return [$0, r(q.x), r(q.y)] }])
}
out["smooth"] = smoothCases

let ct = ClickTimeline(clicks: clicks)
let cts = [0.5, 1.0, 1.03, 1.1, 1.2, 1.5, 2.0, 4.6, 4.8, 5.5]
out["pressAmount"] = cts.map { [$0, r(ct.pressAmount(at: $0))] }
out["clickScale"] = cts.map { [$0, r(ct.clickScale(at: $0, shrink: 0.78, duration: 0.14))] }

var rs = RenderSettings()
let params = CameraParams(rs)
let pers = CameraPlanner.periods(clicks: clicks, pointSize: size, params: params)
out["periods"] = pers.map { [r($0.start), r($0.holdEnd), r($0.outEnd), r(Double($0.focus.x)), r(Double($0.focus.y))] }
let manual = [ZoomRegion(start: 3.0, end: 4.0, scale: 2.5, focusX: 0.3, focusY: 0.6, followCursor: false)]
let planned = CameraPlanner.plan(autoClicks: clicks, manual: manual, pointSize: size, params: params, autoZoom: true)
out["planned"] = planned.map { [r($0.start), r($0.holdEnd), r($0.outEnd), r(Double($0.focus.x)), r(Double($0.focus.y)), r($0.scale), $0.manual ? 1.0 : 0.0] }
let path = CursorSmoother.smooth(samples: samples, clicks: clicks, duration: 6, smoothing: rs.cursorSmoothing, fallback: .zero)
let track = CameraPlanner.buildTrack(periods: pers, cursorAt: { path.position(at: $0) }, pointSize: size, params: params, duration: 6)
out["track"] = [0.0, 0.7, 1.0, 1.5, 2.5, 3.0, 4.6, 5.9].map { let s = track.sample(at: $0); return [$0, r(s.cx), r(s.cy), r(s.z)] }
let track2 = CameraPlanner.buildTrack(periods: planned, cursorAt: { path.position(at: $0) }, pointSize: size, params: params, duration: 6)
out["track2"] = [0.0, 1.0, 3.2, 3.6, 4.0, 4.6, 5.9].map { let s = track2.sample(at: $0); return [$0, r(s.cx), r(s.cy), r(s.z)] }

var proj = EditProject()
proj.segments = [ClipSegment(sourceStart: 0, sourceEnd: 2), ClipSegment(sourceStart: 3, sourceEnd: 5, speed: 2), ClipSegment(sourceStart: 5, sourceEnd: 6, speed: 0.5)]
out["outDur"] = proj.outputDuration(sourceDuration: 6)
out["sourceForOutput"] = [0.0, 1.5, 2.0, 2.5, 3.0, 3.01, 5.0, 99.0].map { [$0, r(proj.sourceTime(forOutput: $0, sourceDuration: 6))] }
out["outputForSource"] = [0.0, 1.5, 2.5, 3.0, 4.0, 5.0, 5.5, 6.0].map { s -> [Double] in
    if let o = proj.outputTime(forSource: s, sourceDuration: 6) { return [s, r(o), 1] } else { return [s, 0, 0] } }
out["typed"] = [0.0, 0.2, 0.5, 1.0, 2.0].map { tt -> [Double] in
    var o = TextOverlay(start: 0, end: 2, text: "Hello world"); o.typewriter = true
    return [tt, Double(o.typedCount(at: tt)), r(o.effectiveTypeSpeed)] }
let d = try JSONSerialization.data(withJSONObject: out, options: [.sortedKeys, .prettyPrinted])
print(String(data: d, encoding: .utf8)!)
