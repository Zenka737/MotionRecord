import Foundation
import AVFoundation
import CoreMedia

/// Webcam -> cam.mov. Best effort: any failure just yields `nil` from finish(); never throws into screen capture.
final class CameraRecorder: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    let outputURL: URL
    private let deviceID: String?
    private let session = AVCaptureSession()
    private let output = AVCaptureVideoDataOutput()
    private let queue = DispatchQueue(label: "motionrecord.camera.samples", qos: .userInteractive)
    private let controlQueue = DispatchQueue(label: "motionrecord.camera.control")

    // queue-confined
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var sessionStarted = false
    private var lastPTS = CMTime.invalid
    private var frames = 0
    private var finished = false
    private var failed = false
    private var firstHost: Double?
    private var lastHost: Double = 0
    private var configured = false

    init(outputURL: URL, deviceID: String?) {
        self.outputURL = outputURL
        self.deviceID = deviceID
        super.init()
    }

    static func device(for id: String?) -> AVCaptureDevice? {
        if let id, let d = AVCaptureDevice(uniqueID: id) { return d }
        return AVCaptureDevice.default(for: .video) ?? discovery().first
    }

    static func discovery() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera],
            mediaType: .video, position: .unspecified).devices
    }

    /// Configures and starts the session asynchronously (non-blocking). Returns false if no camera could be set up.
    func start() -> Bool {
        guard let device = Self.device(for: deviceID),
              let inp = try? AVCaptureDeviceInput(device: device) else { return false }
        session.beginConfiguration()
        if session.canSetSessionPreset(.hd1280x720) { session.sessionPreset = .hd1280x720 }
        guard session.canAddInput(inp) else { session.commitConfiguration(); return false }
        session.addInput(inp)
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: queue)
        guard session.canAddOutput(output) else { session.commitConfiguration(); return false }
        session.addOutput(output)
        session.commitConfiguration()

        // Prefer 30 fps.
        if (try? device.lockForConfiguration()) != nil {
            let d = CMTime(value: 1, timescale: 30)
            let supports = device.activeFormat.videoSupportedFrameRateRanges.contains {
                $0.minFrameDuration <= d && d <= $0.maxFrameDuration
            }
            if supports { device.activeVideoMinFrameDuration = d; device.activeVideoMaxFrameDuration = d }
            device.unlockForConfiguration()
        }
        configured = true
        controlQueue.async { [session] in session.startRunning() }
        return true
    }

    /// Host-clock seconds of the first written camera frame.
    func firstFrameHost() -> Double? { queue.sync { firstHost } }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard !finished, !failed, sampleBuffer.isValid, let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        var pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard pts.isValid else { return }
        // Convert to the host clock if the session uses another clock.
        if let clock = session.synchronizationClock, !CFEqual(clock, CMClockGetHostTimeClock()) {
            pts = CMSyncConvertTime(pts, from: clock, to: CMClockGetHostTimeClock())
        }
        if writer == nil {
            let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
            do {
                try? FileManager.default.removeItem(at: outputURL)
                let wr = try AVAssetWriter(outputURL: outputURL, fileType: .mov)
                let bitrate = min(max(w * h * 30 / 6, 4_000_000), 16_000_000)
                var settings: [String: Any] = [
                    AVVideoCodecKey: AVVideoCodecType.hevc, AVVideoWidthKey: w, AVVideoHeightKey: h,
                    AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: bitrate,
                                                      AVVideoAllowFrameReorderingKey: false,
                                                      AVVideoMaxKeyFrameIntervalKey: 30],
                ]
                if !wr.canApply(outputSettings: settings, forMediaType: .video) {
                    settings[AVVideoCodecKey] = AVVideoCodecType.h264
                }
                let inp = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
                inp.expectsMediaDataInRealTime = true
                guard wr.canAdd(inp) else { failed = true; return }
                wr.add(inp)
                guard wr.startWriting() else { failed = true; return }
                writer = wr; input = inp
            } catch { failed = true; return }
        }
        guard let writer, let input, writer.status == .writing else { failed = writer?.status == .failed; return }
        if !sessionStarted {
            writer.startSession(atSourceTime: pts)
            sessionStarted = true
        } else if CMTimeCompare(pts, lastPTS) <= 0 { return }
        guard input.isReadyForMoreMediaData else { return }
        // Re-time the buffer to the converted PTS when the clock differs.
        var toAppend = sampleBuffer
        if CMTimeCompare(pts, CMSampleBufferGetPresentationTimeStamp(sampleBuffer)) != 0 {
            var timing = CMSampleTimingInfo(duration: CMSampleBufferGetDuration(sampleBuffer), presentationTimeStamp: pts, decodeTimeStamp: .invalid)
            var out: CMSampleBuffer?
            if CMSampleBufferCreateCopyWithNewTiming(allocator: nil, sampleBuffer: sampleBuffer, sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleBufferOut: &out) == noErr, let o = out { toAppend = o }
        }
        if input.append(toAppend) {
            lastPTS = pts
            frames += 1
            lastHost = pts.seconds
            if firstHost == nil { firstHost = pts.seconds }
        } else { failed = true }
    }

    /// Stops and finalizes. Returns the first-frame host time on success, nil if nothing usable was recorded.
    func finish(endHost: Double) async -> Double? {
        if configured {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                controlQueue.async { [session] in session.stopRunning(); c.resume() }
            }
        }
        return await withCheckedContinuation { (c: CheckedContinuation<Double?, Never>) in
            queue.async {
                self.finished = true
                guard let writer = self.writer, let input = self.input, self.sessionStarted, self.frames > 0,
                      !self.failed, writer.status == .writing else {
                    self.writer?.cancelWriting()
                    try? FileManager.default.removeItem(at: self.outputURL)
                    c.resume(returning: nil)
                    return
                }
                input.markAsFinished()
                writer.endSession(atSourceTime: CMTime(seconds: max(endHost, self.lastHost), preferredTimescale: 1_000_000_000))
                let first = self.firstHost
                writer.finishWriting {
                    if writer.status == .completed { c.resume(returning: first) }
                    else { try? FileManager.default.removeItem(at: self.outputURL); c.resume(returning: nil) }
                }
            }
        }
    }
}
