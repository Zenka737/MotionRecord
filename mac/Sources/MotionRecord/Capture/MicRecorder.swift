import Foundation
import AVFoundation
import CoreMedia

/// Microphone -> mic.m4a (AAC). Best effort like the camera: any failure just yields `nil` from finish().
/// Samples carry host-clock PTS so the file lines up with the screen recording (micOffset in the metadata).
final class MicRecorder: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    let outputURL: URL
    private let deviceID: String?
    private let session = AVCaptureSession()
    private let output = AVCaptureAudioDataOutput()
    private let queue = DispatchQueue(label: "motionrecord.mic.samples", qos: .userInteractive)
    private let controlQueue = DispatchQueue(label: "motionrecord.mic.control")

    // queue-confined
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var sessionStarted = false
    private var finished = false
    private var failed = false
    private var firstHost: Double?
    private var lastHost: Double = 0
    private var buffers = 0
    private var configured = false

    /// Live loudness 0...1 for the recording UI (called on the sample queue ~20 Hz).
    var onLevel: (@Sendable (Float) -> Void)?
    private var lastLevelHost = 0.0

    init(outputURL: URL, deviceID: String?) {
        self.outputURL = outputURL
        self.deviceID = deviceID
        super.init()
    }

    static func device(for id: String?) -> AVCaptureDevice? {
        if let id, let d = AVCaptureDevice(uniqueID: id) { return d }
        return AVCaptureDevice.default(for: .audio) ?? discovery().first
    }

    static func discovery() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified).devices
    }

    static var authorization: AVAuthorizationStatus { AVCaptureDevice.authorizationStatus(for: .audio) }
    static func requestPermission() async -> Bool { await AVCaptureDevice.requestAccess(for: .audio) }

    func start() -> Bool {
        guard let device = Self.device(for: deviceID), let inp = try? AVCaptureDeviceInput(device: device) else { return false }
        session.beginConfiguration()
        guard session.canAddInput(inp) else { session.commitConfiguration(); return false }
        session.addInput(inp)
        output.setSampleBufferDelegate(self, queue: queue)
        guard session.canAddOutput(output) else { session.commitConfiguration(); return false }
        session.addOutput(output)
        session.commitConfiguration()
        configured = true
        controlQueue.async { [session] in session.startRunning() }
        return true
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard !finished, !failed, sampleBuffer.isValid, CMSampleBufferGetNumSamples(sampleBuffer) > 0 else { return }
        var pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard pts.isValid else { return }
        if let clock = session.synchronizationClock, !CFEqual(clock, CMClockGetHostTimeClock()) {
            pts = CMSyncConvertTime(pts, from: clock, to: CMClockGetHostTimeClock())
        }
        if writer == nil {
            guard let fmt = CMSampleBufferGetFormatDescription(sampleBuffer),
                  let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fmt)?.pointee else { failed = true; return }
            do {
                try? FileManager.default.removeItem(at: outputURL)
                let wr = try AVAssetWriter(outputURL: outputURL, fileType: .m4a)
                let ch = max(1, min(Int(asbd.mChannelsPerFrame), 2))
                let settings: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48000,
                                               AVNumberOfChannelsKey: ch, AVEncoderBitRateKey: 128_000 * ch / 1]
                let inp = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
                inp.expectsMediaDataInRealTime = true
                guard wr.canAdd(inp) else { failed = true; return }
                wr.add(inp)
                guard wr.startWriting() else { failed = true; return }
                writer = wr; input = inp
            } catch { failed = true; return }
        }
        guard let writer, let input, writer.status == .writing else { failed = writer?.status == .failed; return }
        if !sessionStarted { writer.startSession(atSourceTime: pts); sessionStarted = true }
        guard input.isReadyForMoreMediaData else { return }
        var toAppend = sampleBuffer
        if CMTimeCompare(pts, CMSampleBufferGetPresentationTimeStamp(sampleBuffer)) != 0 {
            var timing = CMSampleTimingInfo(duration: CMSampleBufferGetDuration(sampleBuffer), presentationTimeStamp: pts, decodeTimeStamp: .invalid)
            var out: CMSampleBuffer?
            if CMSampleBufferCreateCopyWithNewTiming(allocator: nil, sampleBuffer: sampleBuffer, sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleBufferOut: &out) == noErr, let o = out { toAppend = o }
        }
        if input.append(toAppend) {
            buffers += 1
            lastHost = pts.seconds
            if firstHost == nil { firstHost = pts.seconds }
            if let cb = onLevel, pts.seconds - lastLevelHost > 0.05 { lastLevelHost = pts.seconds; cb(Self.level(of: sampleBuffer)) }
        } else { failed = true }
    }

    /// RMS of the buffer mapped to 0...1 (about -50 dB ... -10 dB).
    private static func level(of sb: CMSampleBuffer) -> Float {
        guard let bb = CMSampleBufferGetDataBuffer(sb), let fmt = CMSampleBufferGetFormatDescription(sb),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fmt)?.pointee else { return 0 }
        var len = 0; var ptr: UnsafeMutablePointer<CChar>?
        guard CMBlockBufferGetDataPointer(bb, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &len, dataPointerOut: &ptr) == noErr, let p = ptr, len > 0 else { return 0 }
        var sum: Double = 0; var n = 0
        if asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0 && asbd.mBitsPerChannel == 32 {
            let f = UnsafeRawPointer(p).assumingMemoryBound(to: Float.self); n = len / 4
            for i in stride(from: 0, to: n, by: 2) { let v = Double(f[i]); sum += v * v }
            n = (n + 1) / 2
        } else if asbd.mBitsPerChannel == 16 {
            let f = UnsafeRawPointer(p).assumingMemoryBound(to: Int16.self); n = len / 2
            for i in stride(from: 0, to: n, by: 2) { let v = Double(f[i]) / 32768; sum += v * v }
            n = (n + 1) / 2
        } else { return 0 }
        guard n > 0 else { return 0 }
        let db = 20 * log10(max(sqrt(sum / Double(n)), 1e-6))
        return Float(min(max((db + 50) / 40, 0), 1))
    }

    /// Stops and finalizes. Returns the first-sample host time on success, nil if nothing usable was recorded.
    func finish(endHost: Double) async -> Double? {
        if configured {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                controlQueue.async { [session] in session.stopRunning(); c.resume() }
            }
        }
        return await withCheckedContinuation { (c: CheckedContinuation<Double?, Never>) in
            queue.async {
                self.finished = true
                guard let writer = self.writer, let input = self.input, self.sessionStarted, self.buffers > 0,
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
