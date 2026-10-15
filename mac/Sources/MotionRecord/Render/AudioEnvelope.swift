import Foundation
import AVFoundation

/// Loudness over time of an audio file (0...1, already smoothed: fast attack, slower release).
/// Used to make Mochi hop and open his mouth in sync with a voice. Cached per file (path + size + mtime), because the
/// editor re-prepares the composition after every edit.
final class AudioEnvelope: @unchecked Sendable {
    static let hz = 50.0
    let values: [Float]
    var duration: Double { Double(values.count) / Self.hz }

    init(values: [Float]) { self.values = values }

    /// Linear interpolation; 0 outside the file.
    func value(at t: Double) -> Float {
        guard t >= 0, !values.isEmpty else { return 0 }
        let f = t * Self.hz
        let i = Int(f)
        if i >= values.count { return 0 }
        let a = values[i], b = i + 1 < values.count ? values[i + 1] : a
        return a + (b - a) * Float(f - Double(i))
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [String: AudioEnvelope] = [:]

    static func load(url: URL) -> AudioEnvelope? {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let key = "\(url.path)|\((attrs?[.size] as? NSNumber)?.intValue ?? 0)|\((attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)"
        lock.lock(); if let c = cache[key] { lock.unlock(); return c }; lock.unlock()
        guard let e = compute(url: url) else { return nil }
        lock.lock(); cache[key] = e; if cache.count > 24 { cache.removeAll(keepingCapacity: true); cache[key] = e }; lock.unlock()
        return e
    }

    /// RMS per 20 ms window -> dB -> noise gate -> relative to the loud (95th percentile) level -> attack / release.
    static func compute(url: URL) -> AudioEnvelope? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let sr = file.processingFormat.sampleRate
        guard sr > 0, file.length > 0 else { return nil }
        let win = max(1, Int(sr / hz))
        let chunk: AVAudioFrameCount = AVAudioFrameCount(win * 64)
        guard let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: chunk) else { return nil }
        var rms: [Float] = []
        rms.reserveCapacity(Int(Double(file.length) / sr * hz) + 8)
        var acc: Double = 0, cnt = 0
        let channels = Int(file.processingFormat.channelCount)
        while file.framePosition < file.length {
            do { try file.read(into: buf, frameCount: chunk) } catch { break }
            let n = Int(buf.frameLength); if n == 0 { break }
            guard let ch = buf.floatChannelData else { break }
            for i in 0..<n {
                var v: Float = 0
                for c in 0..<channels { v += abs(ch[c][i]) }
                v /= Float(channels)
                acc += Double(v * v); cnt += 1
                if cnt == win { rms.append(Float(sqrt(acc / Double(cnt)))); acc = 0; cnt = 0 }
            }
        }
        if cnt > 0 { rms.append(Float(sqrt(acc / Double(cnt)))) }
        guard !rms.isEmpty else { return nil }
        let db = rms.map { 20 * log10(max($0, 1e-5)) }
        let sorted = db.sorted()
        let floorDB = max(sorted[Int(Double(sorted.count - 1) * 0.1)] + 6, -58)      // noise floor + margin
        let topDB = max(sorted[Int(Double(sorted.count - 1) * 0.95)], floorDB + 12)
        var out = [Float](repeating: 0, count: db.count)
        var y: Float = 0
        let atk: Float = 1 - exp(-1 / Float(hz * 0.03)), rel: Float = 1 - exp(-1 / Float(hz * 0.14))
        for i in 0..<db.count {
            var x = (db[i] - floorDB) / (topDB - floorDB)
            x = min(max(x, 0), 1.15)
            y += (x - y) * (x > y ? atk : rel)
            out[i] = y
        }
        return AudioEnvelope(values: out)
    }
}
