import Foundation
import AVFoundation
import ScreenCaptureKit
import CoreMedia
import CoreVideo

/// One-shot helper: runs a block exactly once (used to race async work against a timeout).
private final class OnceGate: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false
    func fire(_ block: () -> Void) {
        lock.lock()
        let first = !fired
        fired = true
        lock.unlock()
        if first { block() }
    }
}

/// SCStream -> AVAssetWriter pipeline for one recording.
final class ScreenCaptureRecorder: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {

    struct FinishResult {
        var firstPTS: Double?      // host-clock seconds of the first written frame
        var framesWritten: Int
        var framesDropped: Int
        var error: Error?
    }

    // MARK: Configuration
    let outputURL: URL
    let pixelWidth: Int
    let pixelHeight: Int
    let fps: Int
    private(set) var codecName = "hevc"

    // MARK: Objects
    private var stream: SCStream!
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let queue = DispatchQueue(label: "motionrecord.capture.samples", qos: .userInteractive)

    // MARK: State touched only on `queue`
    private var finished = false
    private var sessionStarted = false
    private var firstPTS = CMTime.invalid
    private var lastPTS = CMTime.invalid
    private var framesWritten = 0
    private var framesDropped = 0
    private var failure: Error?

    // MARK: State guarded by `lock`
    private let lock = NSLock()
    private var firstFrameHost: Double?
    private var waiter: CheckedContinuation<Bool, Never>?
    private var streamStopHost: Double?
    private var streamError: Error?

    init(filter: SCContentFilter, pixelWidth: Int, pixelHeight: Int, fps: Int, outputURL: URL) throws {
        self.outputURL = outputURL
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.fps = fps

        try? FileManager.default.removeItem(at: outputURL)
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mov)

        // Bitrate ~ pixels * fps * 0.12 bits, clamped 20...120 Mbps.
        let bits = Double(pixelWidth * pixelHeight) * Double(fps) * 0.12
        let bitrate = Int(min(max(bits, 20_000_000), 120_000_000))

        func settings(codec: AVVideoCodecType) -> [String: Any] {
            var compression: [String: Any] = [
                AVVideoAverageBitRateKey: bitrate,
                AVVideoMaxKeyFrameIntervalKey: fps,
                AVVideoMaxKeyFrameIntervalDurationKey: 1.0,
                AVVideoExpectedSourceFrameRateKey: fps,
                AVVideoAllowFrameReorderingKey: false,
            ]
            if codec == .h264 {
                compression[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel
            }
            return [
                AVVideoCodecKey: codec,
                AVVideoWidthKey: pixelWidth,
                AVVideoHeightKey: pixelHeight,
                AVVideoColorPropertiesKey: [
                    AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                    AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                    AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
                ],
                AVVideoCompressionPropertiesKey: compression,
            ]
        }

        var chosen = settings(codec: .hevc)
        var codec = "hevc"
        if !writer.canApply(outputSettings: chosen, forMediaType: .video) {
            chosen = settings(codec: .h264)
            codec = "h264"
            guard writer.canApply(outputSettings: chosen, forMediaType: .video) else {
                throw CaptureError.writerSetupFailed("Neither HEVC nor H.264 can encode \(pixelWidth)x\(pixelHeight) @ \(fps) fps.")
            }
        }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: chosen)
        input.expectsMediaDataInRealTime = true
        guard writer.canAdd(input) else {
            throw CaptureError.writerSetupFailed("Cannot add video input to the writer.")
        }
        writer.add(input)
        self.writer = writer
        self.input = input
        self.codecName = codec
        super.init()

        let config = SCStreamConfiguration()
        config.width = pixelWidth
        config.height = pixelHeight
        config.scalesToFit = false
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
        config.queueDepth = fps >= 60 ? 8 : 6
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.showsCursor = false
        config.capturesAudio = false
        config.colorSpaceName = CGColorSpace.sRGB
        self.stream = SCStream(filter: filter, configuration: config, delegate: self)
    }

    // MARK: Start

    /// Starts the writer and the stream. Returns once the first frame was written (or after `timeout`
    /// when the stream is running but nothing has been delivered yet).
    func start(firstFrameTimeout: TimeInterval = 4) async throws {
        guard writer.startWriting() else {
            throw CaptureError.writerSetupFailed(writer.error?.localizedDescription ?? "startWriting failed.")
        }
        do {
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
            try await stream.startCapture()
        } catch {
            writer.cancelWriting()
            throw CaptureError.streamFailed(error.localizedDescription)
        }
        _ = await waitForFirstFrame(timeout: firstFrameTimeout)
    }

    /// Host-clock seconds of the first written frame, if any.
    var firstFrameHostTime: Double? {
        lock.lock(); defer { lock.unlock() }
        return firstFrameHost
    }

    /// Error reported by the stream mid-recording, if any.
    var streamFailure: Error? {
        lock.lock(); defer { lock.unlock() }
        return streamError
    }

    private func waitForFirstFrame(timeout: TimeInterval) async -> Bool {
        await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            lock.lock()
            if firstFrameHost != nil {
                lock.unlock()
                cont.resume(returning: true)
                return
            }
            waiter = cont
            lock.unlock()
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in
                self?.resumeWaiter(with: false)
            }
        }
    }

    private func resumeWaiter(with value: Bool) {
        lock.lock()
        let w = waiter
        waiter = nil
        lock.unlock()
        w?.resume(returning: value)
    }

    // MARK: SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, !finished, failure == nil, sampleBuffer.isValid else { return }

        // Only complete frames (idle / blank / suspended frames carry no new image).
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let info = attachments.first,
              let raw = info[.status] as? Int,
              SCFrameStatus(rawValue: raw) == .complete,
              CMSampleBufferGetImageBuffer(sampleBuffer) != nil
        else { return }

        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard pts.isValid, pts.isNumeric else { return }

        if writer.status == .failed {
            failure = writer.error ?? CaptureError.writerFailed("Writer failed.")
            return
        }
        guard writer.status == .writing else { return }

        if !sessionStarted {
            writer.startSession(atSourceTime: pts)
            sessionStarted = true
            firstPTS = pts
        } else if CMTimeCompare(pts, lastPTS) <= 0 {
            return // non-monotonic, skip
        }

        guard input.isReadyForMoreMediaData else {
            framesDropped += 1
            return
        }
        if input.append(sampleBuffer) {
            lastPTS = pts
            framesWritten += 1
            if framesWritten == 1 {
                lock.lock(); firstFrameHost = pts.seconds; lock.unlock()
                resumeWaiter(with: true)
            }
        } else {
            failure = writer.error ?? CaptureError.writerFailed("append failed.")
        }
    }

    // MARK: SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        lock.lock()
        streamError = error
        streamStopHost = HostClock.now()
        lock.unlock()
        resumeWaiter(with: false)
    }

    // MARK: Stop

    /// Stops the stream (bounded wait, never deadlocks), finalizes the file.
    func finish(stopHost: Double) async -> FinishResult {
        await stopStream(timeout: 3)

        // If the stream died earlier, the video ends where the stream ended.
        let streamDied = lock.withLock { streamStopHost }
        let endHost = min(stopHost, streamDied ?? stopHost)

        return await withCheckedContinuation { (cont: CheckedContinuation<FinishResult, Never>) in
            queue.async {
                self.finished = true
                let first = self.sessionStarted ? self.firstPTS.seconds : nil
                let result = { (error: Error?) in
                    FinishResult(firstPTS: first, framesWritten: self.framesWritten,
                                 framesDropped: self.framesDropped, error: error)
                }
                guard self.sessionStarted, self.framesWritten > 0 else {
                    self.writer.cancelWriting()
                    cont.resume(returning: result(CaptureError.noFrames))
                    return
                }
                if self.writer.status == .failed {
                    cont.resume(returning: result(self.writer.error ?? self.failure ?? CaptureError.writerFailed("Writer failed.")))
                    return
                }
                self.input.markAsFinished()
                // Idle screens deliver no frames: end the session at the stop time so duration == wall time.
                let endSeconds = max(endHost, self.lastPTS.seconds + 1.0 / Double(max(self.fps, 1)))
                self.writer.endSession(atSourceTime: CMTime(seconds: endSeconds, preferredTimescale: 1_000_000_000))
                self.writer.finishWriting {
                    if self.writer.status == .completed {
                        cont.resume(returning: result(self.failure))
                    } else {
                        cont.resume(returning: result(self.writer.error ?? CaptureError.writerFailed("finishWriting ended with status \(self.writer.status.rawValue).")))
                    }
                }
            }
        }
    }

    /// Aborts without producing a usable file.
    func cancel() async {
        await stopStream(timeout: 2)
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            queue.async {
                self.finished = true
                if self.writer.status == .writing || self.writer.status == .unknown {
                    self.writer.cancelWriting()
                }
                cont.resume()
            }
        }
        try? FileManager.default.removeItem(at: outputURL)
    }

    private func stopStream(timeout: TimeInterval) async {
        let stream = self.stream!
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            let gate = OnceGate()
            Task {
                try? await stream.stopCapture()
                gate.fire { cont.resume() }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                gate.fire { cont.resume() }
            }
        }
        try? stream.removeStreamOutput(self, type: .screen)
    }
}
