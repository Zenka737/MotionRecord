import Foundation
import CoreGraphics

/// One raw window observation (global top-left points, host clock). Written only when something changed.
struct RawWindowSample {
    var host: Double
    var id: Int
    var app: String
    var title: String
    var pid: Int32
    var x: Double, y: Double, w: Double, h: Double
    var z: Int
    var visible: Bool
}

/// Polls the on-screen window list (~30 Hz) and records changes. Best effort: never throws.
final class WindowTracker: @unchecked Sendable {
    static let maxTracks = 200
    static let maxRawSamples = 200_000

    private let queue = DispatchQueue(label: "motionrecord.windowtracker", qos: .utility)
    private var timer: DispatchSourceTimer?
    private let lock = NSLock()
    private var raw: [RawWindowSample] = []
    private var known: [Int: RawWindowSample] = [:]   // last recorded state per id
    private var seenIDs = Set<Int>()
    private var displayBounds = CGRect.zero
    private let ownPID = getpid()
    private static let skipOwners: Set<String> = ["Window Server", "Dock", "Control Center", "Notification Center"]

    func start(displayID: CGDirectDisplayID) {
        displayBounds = CGDisplayBounds(displayID)
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: .milliseconds(33), leeway: .milliseconds(5))
        t.setEventHandler { [weak self] in self?.poll() }
        timer = t
        t.resume()
    }

    func stop() -> [RawWindowSample] {
        timer?.cancel()
        timer = nil
        return queue.sync {
            lock.lock(); defer { lock.unlock() }
            return raw
        }
    }

    private func r05(_ v: Double) -> Double { (v * 2).rounded() / 2 }

    private func poll() {
        let host = HostClock.now()
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return }
        var current: [Int: RawWindowSample] = [:]
        var z = 0
        for info in list {
            guard let id = (info[kCGWindowNumber as String] as? NSNumber)?.intValue,
                  (info[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  let pid = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value, pid != ownPID,
                  let bd = info[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bd as CFDictionary) else { continue }
            let alpha = (info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1
            let app = info[kCGWindowOwnerName as String] as? String ?? ""
            if alpha <= 0.05 || Self.skipOwners.contains(app) { continue }
            if rect.isEmpty || rect.width < 120 || rect.height < 80 { continue }
            let clipped = rect.intersection(displayBounds)
            if clipped.isNull || clipped.isEmpty { continue }
            let title = info[kCGWindowName as String] as? String ?? ""
            current[id] = RawWindowSample(host: host, id: id, app: app, title: title, pid: pid,
                                          x: r05(rect.minX), y: r05(rect.minY), w: r05(rect.width), h: r05(rect.height),
                                          z: z, visible: true)
            z += 1
        }
        lock.lock(); defer { lock.unlock() }
        guard raw.count < Self.maxRawSamples else { return }
        for (id, s) in current {
            if let k = known[id], k.visible, k.x == s.x, k.y == s.y, k.w == s.w, k.h == s.h, k.z == s.z { continue }
            if known[id] == nil {
                if seenIDs.count >= Self.maxTracks { continue }
                seenIDs.insert(id)
            }
            known[id] = s
            raw.append(s)
        }
        for (id, k) in known where k.visible && current[id] == nil {
            var gone = k
            gone.host = host
            gone.visible = false
            known[id] = gone
            raw.append(gone)
        }
    }
}

extension InputTimeline {
    /// Converts raw window observations to display-local, video-relative tracks.
    /// Rules: rects are shifted by displayOrigin and clamped to the display; windows not intersecting it count as
    /// not visible; observations before t0 collapse into one sample at t=0; after `duration` they are dropped;
    /// moving samples closer than 16 ms replace the previous one; tracks never visible in range are dropped.
    static func windowTracks(raw: [RawWindowSample], displayOrigin: CGPoint, pointSize: CGSize,
                             t0: Double, duration: Double,
                             maxTracks: Int = 200, maxSamples: Int = 20_000) -> [WindowTrack] {
        var order: [Int] = []
        var grouped: [Int: [RawWindowSample]] = [:]
        for r in raw.sorted(by: { $0.host < $1.host }) {
            if grouped[r.id] == nil { order.append(r.id) }
            grouped[r.id, default: []].append(r)
        }
        var tracks: [WindowTrack] = []
        for id in order {
            guard tracks.count < maxTracks, let rs = grouped[id] else { break }
            var samples: [WindowSample] = []
            var before: WindowSample?
            for r in rs {
                let t = r.host - t0
                if t > duration { break }
                var vis = r.visible
                let ox = r.x - Double(displayOrigin.x), oy = r.y - Double(displayOrigin.y)
                let x0 = max(ox, 0), y0 = max(oy, 0)
                let x1 = min(ox + r.w, Double(pointSize.width)), y1 = min(oy + r.h, Double(pointSize.height))
                if x1 <= x0 || y1 <= y0 { vis = false }
                let s = WindowSample(t: max(t, 0), x: x0, y: y0, w: max(x1 - x0, 0), h: max(y1 - y0, 0), z: r.z, visible: vis)
                if t < 0 { before = s; continue }
                if samples.isEmpty, let b = before, t > 0, b.visible {
                    var seed = b; seed.t = 0
                    samples.append(seed)
                }
                if let last = samples.last {
                    if !last.visible && !s.visible { continue }
                    if s.visible && last.visible && s.t - last.t < 0.016 && samples.count > 1 {
                        samples[samples.count - 1] = s
                        continue
                    }
                }
                if samples.isEmpty && !s.visible { continue }
                if samples.count >= maxSamples { break }
                samples.append(s)
            }
            if samples.isEmpty, let b = before, b.visible { samples = [b] }
            if samples.contains(where: { $0.visible }) {
                let f = rs[0]
                tracks.append(WindowTrack(id: id, app: f.app, title: f.title, pid: f.pid, samples: samples))
            }
        }
        return tracks
    }
}
