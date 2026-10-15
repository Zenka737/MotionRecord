import Foundation
import AVFoundation
import CoreImage
import ImageIO
import UniformTypeIdentifiers

struct PreparedComposition {
    var asset: AVAsset
    var videoComposition: AVVideoComposition
    var renderSize: CGSize
    /// Output (edited) duration in seconds.
    var outputDuration: Double = 0
    var audioMix: AVAudioMix? = nil
    /// The frame compositor behind the composition (editor overlays use its camera geometry).
    var frames: FrameCompositor? = nil
}

enum RenderError: LocalizedError {
    case noVideoTrack
    case exportFailed(String)
    var errorDescription: String? {
        switch self {
        case .noVideoTrack: return "The recording contains no video track."
        case .exportFailed(let m): return "Export failed: \(m)"
        }
    }
}

enum VideoRenderer {
    /// One GPU-backed CIContext shared by preview and export.
    static let sharedContext: CIContext = {
        CIContext(options: [.cacheIntermediates: false, .priorityRequestLow: false])
    }()

    // MARK: Legacy wrappers

    static func prepare(session: RecordingSession, settings: RenderSettings) async throws -> PreparedComposition {
        var p = EditProject(); p.render = settings
        return try await prepare(session: session, project: p)
    }

    static func export(session: RecordingSession, settings: RenderSettings, to url: URL,
                       progress: @escaping @Sendable (Double) -> Void) async throws {
        var p = EditProject(); p.render = settings
        switch url.pathExtension.lowercased() {
        case "mov": p.exportFormat = .mov
        case "gif": p.exportFormat = .gif
        default: p.exportFormat = .mp4HEVC
        }
        try await export(session: session, project: p, to: url, progress: progress)
    }

    static let availableCursorStyles: [String] = CursorSprite.styles

    /// Cursor image (hotspot at the image's `hotspot`-less top-left is NOT guaranteed: for previews only) rendered
    /// at `pixelsPerPoint` using the style in `settings`.
    static func cursorSpriteImage(settings: RenderSettings, pixelsPerPoint: CGFloat) -> CGImage? {
        CursorSprite.makeLevel(pxPerPoint: max(pixelsPerPoint, 0.5), design: CursorSprite.design(for: settings)).cg
    }

    // MARK: Geometry

    /// Canvas (output) size for a project given the oriented source size.
    static func canvasSize(source: CGSize, project: EditProject, maxWidth: CGFloat? = nil) -> CGSize {
        let ratio = CGFloat(project.style.aspect.ratio ?? Double(source.width / max(source.height, 1)))
        var h: CGFloat, w: CGFloat
        if project.render.outputHeight > 0 {
            h = CGFloat(project.render.outputHeight); w = h * ratio
        } else if ratio < 1 {
            w = 1080; h = w / ratio
        } else {
            h = source.height; w = h * ratio
        }
        if let m = maxWidth, w > m { h = h * m / w; w = m }
        w = max((w / 2).rounded() * 2, 2); h = max((h / 2).rounded() * 2, 2)
        return CGSize(width: w, height: h)
    }

    /// Zoom periods (OUTPUT time) = auto (from clicks) merged with manual regions.
    static func zoomPeriods(session: RecordingSession, project: EditProject, sourceDuration: Double,
                            pointSize: CGSize, includeManual: Bool) -> [ZoomPeriod] {
        let params = CameraParams(project.render)
        var clicks: [ClickEvent] = []
        for c in session.meta.clicks {
            if let ot = project.outputTime(forSource: c.t, sourceDuration: sourceDuration) {
                var cc = c; cc.t = ot; clicks.append(cc)
            }
        }
        let outDur = project.outputDuration(sourceDuration: sourceDuration)
        return CameraPlanner.plan(autoClicks: clicks, manual: includeManual ? project.zoomRegions : [],
                                  pointSize: pointSize, params: params, autoZoom: project.render.autoZoom)
            .compactMap { clampPeriod($0, to: outDur) }
    }

    /// Clamp a zoom period to the output duration (nil if it starts at/after the end).
    static func clampPeriod(_ per: ZoomPeriod, to outDur: Double) -> ZoomPeriod? {
        guard per.start < outDur - 0.05 else { return nil }
        var p = per
        p.outEnd = min(p.outEnd, outDur)
        p.holdEnd = min(p.holdEnd, p.outEnd)
        return p
    }

    /// Auto-planned zoom periods in OUTPUT time (for showing on the timeline / converting to manual regions).
    /// Independent of `render.autoZoom` (always computed) and of existing manual regions.
    static func autoZoomSuggestions(session: RecordingSession, project: EditProject) -> [ZoomRegion] {
        var p = project
        p.render.autoZoom = true
        p.zoomRegions = []
        let sd = max(session.meta.duration, 0.01)
        let pt = CGSize(width: session.meta.pointWidth > 0 ? session.meta.pointWidth : Double(session.meta.width),
                        height: session.meta.pointHeight > 0 ? session.meta.pointHeight : Double(session.meta.height))
        let params = CameraParams(p.render)
        return zoomPeriods(session: session, project: p, sourceDuration: sd, pointSize: pt, includeManual: false).map {
            ZoomRegion(start: $0.start, end: $0.outEnd, scale: params.zoomScale,
                       focusX: Double($0.focus.x), focusY: Double($0.focus.y), followCursor: true)
        }
    }

    // MARK: Thumbnails

    /// Evenly spaced thumbnails of the SOURCE video (for the timeline filmstrip). `size` is the max size.
    static func thumbnails(session: RecordingSession, count: Int, size: CGSize) async -> [CGImage] {
        guard count > 0 else { return [] }
        let asset = AVURLAsset(url: session.videoURL)
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = size
        gen.requestedTimeToleranceBefore = CMTime(seconds: 0.5, preferredTimescale: 600)
        gen.requestedTimeToleranceAfter = CMTime(seconds: 0.5, preferredTimescale: 600)
        var dur = session.meta.duration
        if let d = try? await asset.load(.duration).seconds, d.isFinite, d > 0 { dur = d }
        var result: [CGImage] = []
        for i in 0..<count {
            let t = dur * (Double(i) + 0.5) / Double(count)
            if let (img, _) = try? await gen.image(at: CMTime(seconds: t, preferredTimescale: 600)) {
                result.append(img)
            } else if let last = result.last {
                result.append(last)
            }
        }
        return result
    }

    // MARK: Prepare

    static func prepare(session: RecordingSession, project: EditProject) async throws -> PreparedComposition {
        try await prepareInternal(session: session, project: project, maxWidth: nil, fpsOverride: nil)
    }

    /// Orientation helper: applies a track's preferredTransform (y-down space) to a CI image.
    static func oriented(_ img: CIImage, transform t: CGAffineTransform, naturalHeight h: CGFloat) -> CIImage {
        if t.isIdentity { return img }
        let flipIn = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: h)
        let flipOut = CGAffineTransform(scaleX: 1, y: -1)
        let r = img.transformed(by: flipIn.concatenating(t).concatenating(flipOut))
        return r.transformed(by: CGAffineTransform(translationX: -r.extent.minX, y: -r.extent.minY))
    }

    /// Unit-rect outline (y down) of a camera shape, for drag handles / shape pickers.
    static func cameraPreviewOutline(shape: CameraShape, cornerRadius: Double) -> CGPath {
        let pts = CameraOutlines.outline(shape: shape, cornerRadius: cornerRadius, pw: 1, ph: 1)
        let path = CGMutablePath()
        for (i, p) in pts.enumerated() { if i == 0 { path.move(to: p) } else { path.addLine(to: p) } }
        path.closeSubpath()
        return path
    }

    private static func prepareInternal(session: RecordingSession, project: EditProject, maxWidth: CGFloat?,
                                        fpsOverride: Double?) async throws -> PreparedComposition {
        let asset = AVURLAsset(url: session.videoURL)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw RenderError.noVideoTrack }
        let natural = try await track.load(.naturalSize)
        let transform = try await track.load(.preferredTransform)
        let nominalFPS = try await track.load(.nominalFrameRate)
        let trackRange = try await track.load(.timeRange)
        let trackStart = trackRange.start.seconds.isFinite ? trackRange.start.seconds : 0
        let audioTrack = try await asset.loadTracks(withMediaType: .audio).first

        // Webcam (optional)
        var camAsset: AVURLAsset?
        var camTrack: AVAssetTrack?
        var camTransform = CGAffineTransform.identity
        var camNatural = CGSize.zero
        var camRange = CMTimeRange.zero
        if project.camera.enabled, let name = session.meta.cameraFileName {
            let u = session.directory.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: u.path) {
                let ca = AVURLAsset(url: u)
                if let t = try? await ca.loadTracks(withMediaType: .video).first {
                    camAsset = ca; camTrack = t
                    camTransform = (try? await t.load(.preferredTransform)) ?? .identity
                    camNatural = (try? await t.load(.naturalSize)) ?? .zero
                    camRange = (try? await t.load(.timeRange)) ?? .zero
                }
            }
        }
        _ = camAsset

        let rect = CGRect(origin: .zero, size: natural).applying(transform)
        var srcW = abs(rect.width), srcH = abs(rect.height)
        if srcW < 1 || srcH < 1 { srcW = CGFloat(session.meta.width); srcH = CGFloat(session.meta.height) }
        let src = CGSize(width: srcW, height: srcH)
        let rotated = abs(transform.b) > 0.5

        let trackDur = trackRange.duration.seconds.isFinite && trackRange.duration.seconds > 0 ? trackRange.duration.seconds : session.meta.duration
        let sourceDuration = max(session.meta.duration, 0.01)
        let outSize = canvasSize(source: src, project: project, maxWidth: maxWidth)

        var pointSize = CGSize(width: session.meta.pointWidth > 0 ? session.meta.pointWidth : Double(srcW),
                               height: session.meta.pointHeight > 0 ? session.meta.pointHeight : Double(srcH))
        if session.meta.cursor.isEmpty && session.meta.clicks.isEmpty { pointSize = src }
        else if rotated { pointSize = CGSize(width: pointSize.height, height: pointSize.width) }

        // Composition: segments in output order, speed applied with scaleTimeRange (affects all tracks).
        let comp = AVMutableComposition()
        guard let cv = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else { throw RenderError.noVideoTrack }
        let cc: AVMutableCompositionTrack? = camTrack != nil ? comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) : nil
        let ca = audioTrack != nil ? comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) : nil
        let audioRange = try await audioTrack?.load(.timeRange)

        // Microphone (optional)
        var micTrack: AVAssetTrack?
        var micRange = CMTimeRange.zero
        var micURL: URL?
        if project.mic.enabled || project.mochi.enabled, let name = session.meta.micFileName {
            let u = session.directory.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: u.path) {
                micURL = u
                let ma = AVURLAsset(url: u)
                if let t = try? await ma.loadTracks(withMediaType: .audio).first {
                    micTrack = t
                    micRange = (try? await t.load(.timeRange)) ?? .zero
                }
            }
        }
        let tm: AVMutableCompositionTrack? = (micTrack != nil && project.mic.enabled)
            ? comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) : nil
        let ts: CMTimeScale = 60000
        var at = CMTime.zero
        var micInserted = false
        for s in project.effectiveSegments(sourceDuration: sourceDuration) {
            let a = max(0, s.sourceStart), b = min(s.sourceEnd, trackDur)
            guard b - a > 0.001 else { continue }
            let speed = max(s.speed, 0.01)
            let range = CMTimeRange(start: CMTime(seconds: trackStart + a, preferredTimescale: ts),
                                    duration: CMTime(seconds: b - a, preferredTimescale: ts))
            try cv.insertTimeRange(range, of: track, at: at)
            if let ca, let audioTrack, !s.isMuted, let ar = audioRange {
                let sub = range.intersection(ar)
                if sub.duration.seconds > 0.001 {
                    try? ca.insertTimeRange(sub, of: audioTrack, at: at + (sub.start - range.start))
                }
            }
            if let tm, let micTrack, !s.isMuted {
                // mic media time = micStart + (sourceTime - micOffset)
                let want = CMTimeRange(start: CMTime(seconds: micRange.start.seconds + a - session.meta.micOffset, preferredTimescale: ts),
                                       duration: range.duration)
                let sub = want.intersection(micRange)
                if sub.duration.seconds > 0.001,
                   (try? tm.insertTimeRange(sub, of: micTrack, at: at + (sub.start - want.start))) != nil { micInserted = true }
            }
            if let cc, let camTrack {
                // camera media time = camStart + (sourceTime - cameraOffset)
                let want = CMTimeRange(start: CMTime(seconds: camRange.start.seconds + a - session.meta.cameraOffset, preferredTimescale: ts),
                                       duration: range.duration)
                let sub = want.intersection(camRange)
                if sub.duration.seconds > 0.001 {
                    try? cc.insertTimeRange(sub, of: camTrack, at: at + (sub.start - want.start))
                }
            }
            let outDur = CMTime(seconds: (b - a) / speed, preferredTimescale: ts)
            if abs(speed - 1) > 0.0001 {
                comp.scaleTimeRange(CMTimeRange(start: at, duration: range.duration), toDuration: outDur)
            }
            at = at + outDur
        }
        let outputDuration = at.seconds
        guard outputDuration > 0 else { throw RenderError.noVideoTrack }
        // An empty audio track (mic outside the cut, or a failed insert) would make the export reader fail.
        if let tm, !micInserted { comp.removeTrack(tm) }

        // Audio mix: original audio volume + music/SFX clips with fades.
        var mixParams: [AVMutableAudioMixInputParameters] = []
        if let ca {
            let mp = AVMutableAudioMixInputParameters(track: ca)
            mp.setVolume(Float(min(max(project.originalVolume, 0), 2)), at: .zero)
            mp.audioTimePitchAlgorithm = .spectral
            mixParams.append(mp)
        }
        if let tm, micInserted {
            let mp = AVMutableAudioMixInputParameters(track: tm)
            mp.setVolume(Float(min(max(project.mic.volume, 0), 3)), at: .zero)
            mp.audioTimePitchAlgorithm = .spectral
            mixParams.append(mp)
        }
        for clip in project.audioClips where !clip.isMuted && clip.volume > 0 {
            let u = URL(fileURLWithPath: clip.filePath)
            let aa = AVURLAsset(url: u)
            guard let at0 = try? await aa.loadTracks(withMediaType: .audio).first,
                  let adur = try? await aa.load(.duration).seconds, adur > 0.01,
                  let tr = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else { continue }
            let s0 = min(max(clip.sourceStart, 0), adur)
            let s1 = min(max(clip.sourceEnd ?? adur, s0), adur)
            let len = s1 - s0
            guard len > 0.01 else { continue }
            let startOut = max(0, clip.outputStart)
            guard startOut < outputDuration else { continue }
            var pos = startOut
            let endLimit = clip.loopToFitVideo ? outputDuration : min(outputDuration, startOut + len)
            while pos < endLimit - 0.001 {
                let piece = min(len, endLimit - pos)
                try? tr.insertTimeRange(CMTimeRange(start: CMTime(seconds: s0, preferredTimescale: ts),
                                                    duration: CMTime(seconds: piece, preferredTimescale: ts)),
                                        of: at0, at: CMTime(seconds: pos, preferredTimescale: ts))
                pos += piece
            }
            let vol = Float(min(max(clip.volume, 0), 2))
            let mp = AVMutableAudioMixInputParameters(track: tr)
            let st = startOut, en = endLimit
            func T(_ x: Double) -> CMTime { CMTime(seconds: x, preferredTimescale: ts) }
            let fi = min(max(clip.fadeIn, 0), (en - st) / 2), fo = min(max(clip.fadeOut, 0), (en - st) / 2)
            if fi > 0.01 {
                mp.setVolumeRamp(fromStartVolume: 0, toEndVolume: vol, timeRange: CMTimeRange(start: T(st), duration: T(fi)))
            } else { mp.setVolume(vol, at: T(st)) }
            if fo > 0.01 {
                mp.setVolume(vol, at: T(st + fi))
                mp.setVolumeRamp(fromStartVolume: vol, toEndVolume: 0, timeRange: CMTimeRange(start: T(en - fo), duration: T(fo)))
            }
            mp.audioTimePitchAlgorithm = .spectral
            mixParams.append(mp)
        }
        var audioMix: AVMutableAudioMix?
        if !mixParams.isEmpty { let m = AVMutableAudioMix(); m.inputParameters = mixParams; audioMix = m }

        // Loudness curves that drive Mochi (only when he is on).
        var levels: MochiLevels?
        if project.mochi.enabled {
            let lv = MochiLevels()
            if project.mochi.reactMic, let micURL, let env = AudioEnvelope.load(url: micURL) { lv.mic = env; lv.micOffset = session.meta.micOffset - micRange.start.seconds }
            for clip in project.audioClips where !clip.isMuted {
                guard clip.isMusic ? project.mochi.reactMusic : project.mochi.reactVoice else { continue }
                if let env = AudioEnvelope.load(url: URL(fileURLWithPath: clip.filePath)) {
                    if clip.isMusic { lv.music.append(.init(clip: clip, env: env)) } else { lv.voice.append(.init(clip: clip, env: env)) }
                }
            }
            levels = lv
        }
        let compositor = FrameCompositor(config: .init(srcSize: src, outSize: outSize, pointSize: pointSize,
                                                       project: project, sourceDuration: sourceDuration,
                                                       hasCamera: cc != nil, levels: levels),
                                         session: session, ciContext: sharedContext)
        let instr = MRInstruction(timeRange: CMTimeRange(start: .zero, duration: comp.duration),
                                  screenID: cv.trackID, camID: cc?.trackID, frames: compositor,
                                  screenTransform: transform, screenNatural: natural,
                                  camTransform: camTransform, camNatural: camNatural)
        let vc = AVMutableVideoComposition()
        vc.customVideoCompositorClass = MRCompositor.self
        vc.instructions = [instr]
        vc.renderSize = outSize
        var fps = fpsOverride ?? Double(project.render.outputFPS)
        if fps <= 0 {
            // "As source": screen recordings are variable-rate (e.g. 109.09 measured from a 120 fps capture). Snap to a
            // standard rate and cap at 60, so players (QuickTime) don't choke on odd, very high frame rates.
            var src = Double(nominalFPS)
            if src <= 0 { src = Double(max(session.meta.fps, 30)) }
            let standard: [Double] = [24, 25, 30, 48, 50, 60]
            fps = src > 60 ? 60 : (standard.min(by: { abs($0 - src) < abs($1 - src) }) ?? 30)
        }
        fps = min(max(fps, 1), 240)
        if abs(fps - fps.rounded()) < 0.01 {
            vc.frameDuration = CMTime(value: 1, timescale: CMTimeScale(fps.rounded()))
        } else {
            vc.frameDuration = CMTime(value: CMTimeValue((60000.0 / fps).rounded()), timescale: 60000)
        }
        return PreparedComposition(asset: comp, videoComposition: vc, renderSize: outSize,
                                   outputDuration: outputDuration, audioMix: audioMix, frames: compositor)
    }

    // MARK: Audio info

    /// Duration + ~400 normalized peak values (0...1) for drawing a waveform.
    static func audioInfo(url: URL) async -> (duration: Double, waveform: [Float]) {
        let asset = AVURLAsset(url: url)
        let dur = (try? await asset.load(.duration).seconds) ?? 0
        guard dur.isFinite, dur > 0, let track = try? await asset.loadTracks(withMediaType: .audio).first,
              let reader = try? AVAssetReader(asset: asset) else { return (max(dur, 0), []) }
        let rate = 8000.0
        let out = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false])
        guard reader.canAdd(out) else { return (dur, []) }
        reader.add(out)
        guard reader.startReading() else { return (dur, []) }
        let bins = 400
        let total = dur * rate
        var peaks = [Float](repeating: 0, count: bins)
        var idx = 0.0
        while let sb = out.copyNextSampleBuffer() {
            guard let bb = CMSampleBufferGetDataBuffer(sb) else { continue }
            let n = CMBlockBufferGetDataLength(bb) / 2
            var data = [Int16](repeating: 0, count: n)
            _ = data.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(bb, atOffset: 0, dataLength: n * 2, destination: $0.baseAddress!) }
            for v in data {
                let bi = min(bins - 1, Int(idx / total * Double(bins)))
                let a = abs(Float(v)) / 32768
                if a > peaks[bi] { peaks[bi] = a }
                idx += 1
            }
        }
        let mx = peaks.max() ?? 0
        if mx > 0 { peaks = peaks.map { $0 / mx } }
        return (dur, peaks)
    }

    // MARK: Export

    static func export(session: RecordingSession, project: EditProject, to url: URL,
                       progress: @escaping @Sendable (Double) -> Void) async throws {
        try? FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if project.exportFormat == .gif {
            try await exportGIF(session: session, project: project, to: url, progress: progress)
            return
        }
        let prepared = try await prepareInternal(session: session, project: project, maxWidth: nil, fpsOverride: nil)
        let asset = prepared.asset
        let vcomp = prepared.videoComposition
        let size = prepared.renderSize
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        let duration = prepared.outputDuration
        let fps = vcomp.frameDuration.seconds > 0 ? 1.0 / vcomp.frameDuration.seconds : 60

        let fileType: AVFileType = project.exportFormat == .mov ? .mov : .mp4
        let codec: AVVideoCodecType = project.exportFormat == .mp4H264 ? .h264 : .hevc

        let reader = try AVAssetReader(asset: asset)
        let vOut = AVAssetReaderVideoCompositionOutput(videoTracks: videoTracks, videoSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ])
        vOut.videoComposition = vcomp
        vOut.alwaysCopiesSampleData = false
        guard reader.canAdd(vOut) else { throw RenderError.exportFailed("cannot add video output") }
        reader.add(vOut)

        let writer = try AVAssetWriter(outputURL: url, fileType: fileType)
        let pixels = size.width * size.height
        let bpp = codec == .h264 ? 0.22 : 0.12
        let bitrate = Int(min(max(pixels * fps * bpp, 6_000_000), codec == .h264 ? 60_000_000 : 40_000_000))
        var comp: [String: Any] = [
            AVVideoAverageBitRateKey: bitrate,
            AVVideoExpectedSourceFrameRateKey: Int(fps.rounded()),
            AVVideoMaxKeyFrameIntervalKey: Int(fps.rounded()) * 2,
            AVVideoAllowFrameReorderingKey: true,
            // Cap peaks (~1.6x average) so playback stays smooth on every player.
            "DataRateLimits": [Int(Double(bitrate) * 1.6 / 8), 1],
        ]
        if codec == .h264 { comp[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel }
        let vSettings: [String: Any] = [
            AVVideoCodecKey: codec,
            AVVideoWidthKey: Int(size.width),
            AVVideoHeightKey: Int(size.height),
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
            AVVideoCompressionPropertiesKey: comp,
        ]
        let vIn = AVAssetWriterInput(mediaType: .video, outputSettings: vSettings)
        vIn.expectsMediaDataInRealTime = false
        guard writer.canAdd(vIn) else { throw RenderError.exportFailed("cannot add video input") }
        writer.add(vIn)

        var aOut: AVAssetReaderOutput?
        var aIn: AVAssetWriterInput?
        if !audioTracks.isEmpty {
            let o = AVAssetReaderAudioMixOutput(audioTracks: audioTracks, audioSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48000, AVNumberOfChannelsKey: 2,
                AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
            ])
            o.audioMix = prepared.audioMix
            o.audioTimePitchAlgorithm = .spectral
            let i = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48000, AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 192_000,
            ])
            if reader.canAdd(o) && writer.canAdd(i) { reader.add(o); writer.add(i); aOut = o; aIn = i }
        }

        guard reader.startReading() else { throw RenderError.exportFailed(reader.error?.localizedDescription ?? "reader failed") }
        guard writer.startWriting() else { throw RenderError.exportFailed(writer.error?.localizedDescription ?? "writer failed") }
        writer.startSession(atSourceTime: .zero)
        progress(0)

        let pump = SamplePump(videoIn: vIn, videoOut: vOut, audioIn: aIn, audioOut: aOut, duration: duration, progress: progress)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                pump.start {
                    if Task.isCancelled { reader.cancelReading(); writer.cancelWriting(); c.resume(throwing: CancellationError()); return }
                    writer.finishWriting {
                        if writer.status == .completed { c.resume() }
                        else { c.resume(throwing: RenderError.exportFailed("\(writer.error.map { String(describing: $0) } ?? "writer status \(writer.status.rawValue)") | reader: \(reader.error.map { String(describing: $0) } ?? "-")")) }
                    }
                }
            }
        } onCancel: {
            pump.cancel()
            reader.cancelReading()
            writer.cancelWriting()
        }
        if reader.status == .failed { throw reader.error ?? RenderError.exportFailed("reader failed") }
        progress(1)
    }

    /// GIF: <= 12.5 fps (8 cs/frame), <= 720 px wide, memory bounded by shrinking when the clip is long.
    private static func exportGIF(session: RecordingSession, project: EditProject, to url: URL,
                                  progress: @escaping @Sendable (Double) -> Void) async throws {
        let gifFPS = 12.5
        let probe = try await prepareInternal(session: session, project: project, maxWidth: 720, fpsOverride: gifFPS)
        let frames = max(1, Int(probe.outputDuration * gifFPS))
        var maxW: CGFloat = 720
        let budget = 700.0 * 1_048_576
        let perFrame = Double(probe.renderSize.width * probe.renderSize.height * 4)
        if perFrame * Double(frames) > budget {
            maxW = max(240, 720 * CGFloat(sqrt(budget / (perFrame * Double(frames)))))
        }
        let prepared = maxW < 720 ? try await prepareInternal(session: session, project: project, maxWidth: maxW, fpsOverride: gifFPS) : probe
        let asset = prepared.asset
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let reader = try AVAssetReader(asset: asset)
        let out = AVAssetReaderVideoCompositionOutput(videoTracks: videoTracks, videoSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        out.videoComposition = prepared.videoComposition
        out.alwaysCopiesSampleData = false
        guard reader.canAdd(out) else { throw RenderError.exportFailed("cannot add video output") }
        reader.add(out)
        guard reader.startReading() else { throw RenderError.exportFailed(reader.error?.localizedDescription ?? "reader failed") }
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString, frames + 4, nil) else {
            throw RenderError.exportFailed("cannot create GIF")
        }
        CGImageDestinationSetProperties(dest, [kCGImagePropertyGIFDictionary as String: [kCGImagePropertyGIFLoopCount as String: 0]] as CFDictionary)
        let frameProps = [kCGImagePropertyGIFDictionary as String: [kCGImagePropertyGIFDelayTime as String: 0.08]] as CFDictionary
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let total = max(prepared.outputDuration, 0.01)
        var n = 0
        let ci = sharedContext
        while let sb = out.copyNextSampleBuffer() {
            try Task.checkCancellation()
            guard let pb = CMSampleBufferGetImageBuffer(sb) else { continue }
            let img = CIImage(cvPixelBuffer: pb)
            if let cg = ci.createCGImage(img, from: img.extent, format: .RGBA8, colorSpace: cs) {
                CGImageDestinationAddImage(dest, cg, frameProps)
                n += 1
            }
            progress(min(CMSampleBufferGetPresentationTimeStamp(sb).seconds / total, 1) * 0.95)
        }
        if reader.status == .failed { throw reader.error ?? RenderError.exportFailed("reader failed") }
        guard n > 0, CGImageDestinationFinalize(dest) else { throw RenderError.exportFailed("GIF encoding failed") }
        progress(1)
    }
}

/// Drives reader -> writer copying on a serial queue.
private final class SamplePump: @unchecked Sendable {
    let queue = DispatchQueue(label: "motionrecord.export")
    let videoIn: AVAssetWriterInput, videoOut: AVAssetReaderOutput
    let audioIn: AVAssetWriterInput?, audioOut: AVAssetReaderOutput?
    let duration: Double
    let progress: @Sendable (Double) -> Void
    private var pending = 0
    private var cancelled = false
    private var lastReported = -1.0

    init(videoIn: AVAssetWriterInput, videoOut: AVAssetReaderOutput, audioIn: AVAssetWriterInput?, audioOut: AVAssetReaderOutput?,
         duration: Double, progress: @escaping @Sendable (Double) -> Void) {
        self.videoIn = videoIn; self.videoOut = videoOut; self.audioIn = audioIn; self.audioOut = audioOut
        self.duration = max(duration, 0.001); self.progress = progress
    }

    func cancel() { queue.async { self.cancelled = true } }

    func start(done: @escaping @Sendable () -> Void) {
        pending = audioIn == nil ? 1 : 2
        let finish: @Sendable () -> Void = { [self] in
            pending -= 1
            if pending == 0 { done() }
        }
        videoIn.requestMediaDataWhenReady(on: queue) { [self] in
            while videoIn.isReadyForMoreMediaData {
                if cancelled { videoIn.markAsFinished(); finish(); return }
                if let sb = videoOut.copyNextSampleBuffer() {
                    let t = CMSampleBufferGetPresentationTimeStamp(sb).seconds
                    if !videoIn.append(sb) { videoIn.markAsFinished(); finish(); return }
                    let p = min(max(t / duration, 0), 1)
                    if p - lastReported >= 0.005 { lastReported = p; progress(p * 0.999) }
                } else {
                    videoIn.markAsFinished(); finish(); return
                }
            }
        }
        if let audioIn, let audioOut {
            audioIn.requestMediaDataWhenReady(on: queue) { [self] in
                while audioIn.isReadyForMoreMediaData {
                    if cancelled { audioIn.markAsFinished(); finish(); return }
                    if let sb = audioOut.copyNextSampleBuffer() {
                        if !audioIn.append(sb) { audioIn.markAsFinished(); finish(); return }
                    } else {
                        audioIn.markAsFinished(); finish(); return
                    }
                }
            }
        }
    }
}


// MARK: Custom compositor (screen + optional webcam track)

final class MRInstruction: NSObject, AVVideoCompositionInstructionProtocol, @unchecked Sendable {
    let timeRange: CMTimeRange
    let enablePostProcessing = false
    let containsTweening = true
    let requiredSourceTrackIDs: [NSValue]?
    let passthroughTrackID = kCMPersistentTrackID_Invalid
    let screenID: CMPersistentTrackID
    let camID: CMPersistentTrackID?
    let frames: FrameCompositor
    let screenTransform: CGAffineTransform, screenNatural: CGSize
    let camTransform: CGAffineTransform, camNatural: CGSize

    init(timeRange: CMTimeRange, screenID: CMPersistentTrackID, camID: CMPersistentTrackID?, frames: FrameCompositor,
         screenTransform: CGAffineTransform, screenNatural: CGSize, camTransform: CGAffineTransform, camNatural: CGSize) {
        self.timeRange = timeRange; self.screenID = screenID; self.camID = camID; self.frames = frames
        self.screenTransform = screenTransform; self.screenNatural = screenNatural
        self.camTransform = camTransform; self.camNatural = camNatural
        var ids: [NSValue] = [NSNumber(value: screenID)]
        if let camID { ids.append(NSNumber(value: camID)) }
        requiredSourceTrackIDs = ids
        super.init()
    }
}

final class MRCompositor: NSObject, AVVideoCompositing, @unchecked Sendable {
    let sourcePixelBufferAttributes: [String: any Sendable]? = [kCVPixelBufferPixelFormatTypeKey as String: [kCVPixelFormatType_32BGRA]]
    let requiredPixelBufferAttributesForRenderContext: [String: any Sendable] = [kCVPixelBufferPixelFormatTypeKey as String: [kCVPixelFormatType_32BGRA]]
    private let queue = DispatchQueue(label: "motionrecord.compositor", qos: .userInitiated)

    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {}

    func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        queue.async {
            autoreleasepool {
                guard let ins = request.videoCompositionInstruction as? MRInstruction,
                      let sb = request.sourceFrame(byTrackID: ins.screenID),
                      let outBuf = request.renderContext.newPixelBuffer() else {
                    request.finish(with: NSError(domain: "MotionRecord", code: 1))
                    return
                }
                let screen = VideoRenderer.oriented(CIImage(cvPixelBuffer: sb), transform: ins.screenTransform, naturalHeight: ins.screenNatural.height)
                var cam: CIImage?
                if let cid = ins.camID, let cb = request.sourceFrame(byTrackID: cid) {
                    cam = VideoRenderer.oriented(CIImage(cvPixelBuffer: cb), transform: ins.camTransform, naturalHeight: ins.camNatural.height)
                }
                let out = ins.frames.render(source: screen, camera: cam, t: request.compositionTime.seconds)
                let size = request.renderContext.size
                VideoRenderer.sharedContext.render(out, to: outBuf, bounds: CGRect(origin: .zero, size: size),
                                                   colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
                request.finish(withComposedVideoFrame: outBuf)
            }
        }
    }

    func cancelAllPendingVideoCompositionRequests() {}
}
