import Foundation
import AVFoundation
import CoreGraphics

/// Single point where the editor talks to the render layer.
enum RenderBridge {
    static func prepare(session: RecordingSession, project: EditProject) async throws -> PreparedComposition {
        try await VideoRenderer.prepare(session: session, project: project)
    }

    static func export(session: RecordingSession, project: EditProject, to url: URL,
                       progress: @escaping @Sendable (Double) -> Void) async throws {
        try await VideoRenderer.export(session: session, project: project, to: url, progress: progress)
    }

    /// Evenly spaced SOURCE-time thumbnails.
    static func thumbnails(session: RecordingSession, count: Int, size: CGSize) async -> [CGImage] {
        await VideoRenderer.thumbnails(session: session, count: count, size: size)
    }

    /// Suggested auto zooms in OUTPUT time.
    static func autoZoomSuggestions(session: RecordingSession, project: EditProject) -> [ZoomRegion] {
        VideoRenderer.autoZoomSuggestions(session: session, project: project)
    }

    /// Duration + coarse peak waveform (0...1) of an audio (or video) file.
    /// Uses AVAudioFile (Swift errors) instead of AVAssetReader (throws uncatchable ObjC exceptions).
    static func audioInfo(url: URL) async -> (duration: Double, waveform: [Float])? {
        let asset = AVURLAsset(url: url)
        let assetDur = (try? await asset.load(.duration).seconds) ?? 0
        return await Task.detached(priority: .utility) { () -> (Double, [Float])? in
            guard let file = try? AVAudioFile(forReading: url) else {
                return assetDur.isFinite && assetDur > 0 ? (assetDur, []) : nil
            }
            let sr = file.processingFormat.sampleRate
            let frames = file.length
            guard sr > 0, frames > 0 else { return nil }
            let dur = Double(frames) / sr
            let bins = min(1200, max(60, Int(dur * 25)))
            var peaks = [Float](repeating: 0, count: bins)
            let chunk: AVAudioFrameCount = 32768
            guard let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: chunk) else { return (dur, []) }
            var pos: Int64 = 0
            while pos < frames {
                do { try file.read(into: buf, frameCount: chunk) } catch { break }
                let n = Int(buf.frameLength)
                if n == 0 { break }
                guard let ch = buf.floatChannelData else { break }
                let c0 = ch[0]
                for i in 0..<n {
                    let bi = min(Int(Double(pos + Int64(i)) / Double(frames) * Double(bins)), bins - 1)
                    let a = abs(c0[i])
                    if a > peaks[bi] { peaks[bi] = a }
                }
                pos += Int64(n)
            }
            let mx = max(peaks.max() ?? 1, 0.05)
            return (dur, peaks.map { min($0 / mx, 1) })
        }.value
    }

    // MARK: Windows (thin wrappers over meta.windows; switch to WindowQueries when it lands)

    static func lifetime(of track: WindowTrack, meta: RecordingMetadata) -> ClosedRange<Double> {
        WindowQueries.lifetime(of: track, meta: meta)
    }

    /// Last sample at or before `t` (nil before the first sample).
    private static func sample(of track: WindowTrack, at t: Double) -> WindowSample? {
        var lo = 0, hi = track.samples.count
        while lo < hi { let m = (lo + hi) / 2; if track.samples[m].t <= t { lo = m + 1 } else { hi = m } }
        return lo > 0 ? track.samples[lo - 1] : nil
    }

    static func rect(of track: WindowTrack, at t: Double) -> CGRect {
        guard let s = sample(of: track, at: t) ?? track.samples.first else { return .zero }
        return CGRect(x: s.x, y: s.y, width: s.w, height: s.h)
    }

    static func windows(at t: Double, in meta: RecordingMetadata) -> [(track: WindowTrack, rect: CGRect)] {
        WindowQueries.windows(at: t, in: meta)
    }

    static func topWindow(at t: Double, point: CGPoint, in meta: RecordingMetadata) -> WindowTrack? {
        windows(at: t, in: meta).first { $0.rect.contains(point) }?.track
    }
}
