import Foundation
import Combine
import AppKit
import AVFoundation
import ScreenCaptureKit
import CoreGraphics

enum CaptureError: LocalizedError {
    case noPermission
    case alreadyRecording
    case notRecording
    case displayNotFound(UInt32)
    case writerSetupFailed(String)
    case writerFailed(String)
    case streamFailed(String)
    case noFrames

    var errorDescription: String? {
        switch self {
        case .noPermission:
            return "Screen recording permission is not granted. Enable MotionRecord in System Settings > Privacy & Security > Screen & System Audio Recording, then restart the app."
        case .alreadyRecording: return "A recording is already in progress."
        case .notRecording: return "There is no recording in progress."
        case .displayNotFound(let id): return "The selected display (\(id)) is not available."
        case .writerSetupFailed(let m): return "Could not set up the video writer: \(m)"
        case .writerFailed(let m): return "Writing the video file failed: \(m)"
        case .streamFailed(let m): return "Screen capture failed to start: \(m)"
        case .noFrames: return "No video frames were captured. Check screen recording permission and try again."
        }
    }
}

@MainActor
final class RecordingEngine: ObservableObject {
    @Published private(set) var isRecording = false
    @Published private(set) var elapsed: TimeInterval = 0
    /// Live microphone loudness 0...1 while recording with the microphone on.
    @Published private(set) var micLevel: Float = 0

    /// Exclude MotionRecord's own windows (notch pill, editor) from the capture.
    static var excludeOwnApp = true

    private struct Active {
        var recorder: ScreenCaptureRecorder
        var tracker: InputTracker
        var windowTracker: WindowTracker
        var directory: URL
        var settings: RecordingSettings
        var displayID: CGDirectDisplayID
        var pointSize: CGSize
        var pixelWidth: Int
        var pixelHeight: Int
        var startedAt: Date
        var startedHost: Double
        var camera: CameraRecorder?
        var mic: MicRecorder?
    }

    private var active: Active?
    private var isStarting = false
    private var isStopping = false
    private var timer: Timer?

    // MARK: Static helpers

    /// Lists displays (name, size in points, main flag).
    static func availableDisplays() async -> [DisplayInfo] {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true) else { return [] }
        let main = CGMainDisplayID()
        return content.displays.map { d in
            let name = NSScreen.screens.first {
                ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == d.displayID
            }?.localizedName ?? "Display \(d.displayID)"
            return DisplayInfo(id: d.displayID, name: name, pointWidth: d.width, pointHeight: d.height, isMain: d.displayID == main)
        }.sorted { ($0.isMain ? 0 : 1, $0.id) < ($1.isMain ? 0 : 1, $1.id) }
    }

    /// Screen-recording permission (CGPreflightScreenCaptureAccess / CGRequestScreenCaptureAccess).
    static func hasPermission() -> Bool { CGPreflightScreenCaptureAccess() }
    static func requestPermission() { _ = CGRequestScreenCaptureAccess() }
    /// Input Monitoring (needed to see WHEN keys are pressed, for keyboard sounds).
    static func hasKeyboardPermission() -> Bool { CGPreflightListenEventAccess() }
    static func requestKeyboardPermission() { _ = CGRequestListenEventAccess() }

    // MARK: Microphone

    static func micPermissionStatus() -> AVAuthorizationStatus { MicRecorder.authorization }
    static func requestMicPermission() async -> Bool { await MicRecorder.requestPermission() }
    static func availableMics() -> [(id: String, name: String)] { MicRecorder.discovery().map { ($0.uniqueID, $0.localizedName) } }

    // MARK: Camera

    static func cameraPermissionStatus() -> AVAuthorizationStatus { AVCaptureDevice.authorizationStatus(for: .video) }
    static func requestCameraPermission() async -> Bool { await AVCaptureDevice.requestAccess(for: .video) }
    static func availableCameras() -> [(id: String, name: String)] {
        CameraRecorder.discovery().map { ($0.uniqueID, $0.localizedName) }
    }

    // MARK: Start

    /// Starts capture + input tracking. Creates ~/Movies/MotionRecord/<yyyy-MM-dd_HH-mm-ss>/raw.mov
    func start(settings: RecordingSettings) async throws {
        guard active == nil, !isStarting, !isStopping else { throw CaptureError.alreadyRecording }
        isStarting = true
        defer { isStarting = false }

        guard Self.hasPermission() else {
            Self.requestPermission()
            throw CaptureError.noPermission
        }

        let wantedID = settings.displayID == 0 ? CGMainDisplayID() : settings.displayID
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            throw CaptureError.streamFailed(error.localizedDescription)
        }
        guard let display = content.displays.first(where: { $0.displayID == wantedID }) else {
            throw CaptureError.displayNotFound(wantedID)
        }

        // Native pixel size (points * backing scale).
        let pointSize = CGSize(width: display.width, height: display.height)
        var pw = display.width, ph = display.height
        if let mode = CGDisplayCopyDisplayMode(wantedID), mode.pixelWidth > 0, mode.pixelHeight > 0 {
            pw = mode.pixelWidth
            ph = mode.pixelHeight
        }
        pw &= ~1; ph &= ~1   // even dimensions for the encoder

        var excluded: [SCRunningApplication] = []
        if Self.excludeOwnApp {
            let pid = ProcessInfo.processInfo.processIdentifier
            excluded = content.applications.filter { $0.processID == pid }
        }
        let filter = SCContentFilter(display: display, excludingApplications: excluded, exceptingWindows: [])

        let dir = try Self.makeSessionDirectory()
        let recorder: ScreenCaptureRecorder
        do {
            recorder = try ScreenCaptureRecorder(filter: filter, pixelWidth: pw, pixelHeight: ph, fps: settings.fps,
                                                 outputURL: dir.appendingPathComponent("raw.mov"))
        } catch {
            try? FileManager.default.removeItem(at: dir)
            throw error
        }

        let tracker = InputTracker()
        tracker.recordKeys = settings.recordKeys
        if settings.recordKeys && !CGPreflightListenEventAccess() { _ = CGRequestListenEventAccess() }
        let windowTracker = WindowTracker()
        windowTracker.start(displayID: wantedID)
        tracker.start()   // main thread; start sampling before the first frame so t=0 has a position

        // Camera is best effort: any failure leaves a screen-only recording.
        var camera: CameraRecorder?
        if settings.recordCamera, Self.cameraPermissionStatus() == .authorized {
            let cam = CameraRecorder(outputURL: dir.appendingPathComponent("cam.mov"), deviceID: settings.cameraDeviceID)
            if cam.start() { camera = cam }
        }

        // Microphone is best effort too.
        var mic: MicRecorder?
        if settings.recordMic, Self.micPermissionStatus() == .authorized {
            let m = MicRecorder(outputURL: dir.appendingPathComponent("mic.m4a"), deviceID: settings.micDeviceID)
            m.onLevel = { [weak self] lv in Task { @MainActor in self?.micLevel = lv } }
            if m.start() { mic = m }
        }

        do {
            try await recorder.start()
        } catch {
            if let mic { _ = await mic.finish(endHost: HostClock.now()) }
            _ = tracker.stop()
            _ = windowTracker.stop()
            if let camera { _ = await camera.finish(endHost: HostClock.now()) }
            await recorder.cancel()
            try? FileManager.default.removeItem(at: dir)
            throw error
        }

        let now = HostClock.now()
        active = Active(recorder: recorder, tracker: tracker, windowTracker: windowTracker, directory: dir, settings: settings,
                        displayID: wantedID, pointSize: pointSize, pixelWidth: pw, pixelHeight: ph,
                        startedAt: Date(), startedHost: now, camera: camera, mic: mic)
        elapsed = 0
        isRecording = true
        startTimer(startHost: now)
    }

    // MARK: Stop

    /// Stops, finalizes raw.mov, writes meta.json and returns the session.
    func stop() async throws -> RecordingSession {
        guard let a = active, !isStopping else { throw CaptureError.notRecording }
        isStopping = true
        let stopHost = HostClock.now()
        timer?.invalidate()
        timer = nil

        let raw = a.tracker.stop()
        let rawKeys = a.tracker.takeKeys()
        let rawShapes = a.tracker.takeShapes()
        let rawWindows = a.windowTracker.stop()
        let result = await a.recorder.finish(stopHost: stopHost)
        let camFirst = await a.camera?.finish(endHost: stopHost)
        let micFirst = await a.mic?.finish(endHost: stopHost)
        micLevel = 0

        active = nil
        isRecording = false
        isStopping = false

        if let error = result.error, result.framesWritten == 0 {
            try? FileManager.default.removeItem(at: a.directory)
            throw error
        }
        if let error = result.error {
            // Partial failure after frames were written: the file is not trustworthy.
            throw CaptureError.writerFailed(error.localizedDescription)
        }
        guard let t0 = result.firstPTS else { throw CaptureError.noFrames }

        // Duration straight from the finished file (matches what the renderer will read).
        var duration = max(stopHost - t0, 0)
        let asset = AVURLAsset(url: a.recorder.outputURL)
        if let d = try? await asset.load(.duration).seconds, d.isFinite, d > 0 { duration = d }

        let bounds = CGDisplayBounds(a.displayID)
        let cursor = InputTimeline.cursorTrack(raw: raw.cursor, displayOrigin: bounds.origin, pointSize: a.pointSize,
                                               t0: t0, duration: duration)
        let clicks = InputTimeline.clickEvents(raw: raw.clicks, displayOrigin: bounds.origin, pointSize: a.pointSize,
                                               t0: t0, duration: duration)

        var meta = RecordingMetadata(
            width: a.pixelWidth, height: a.pixelHeight,
            pointWidth: Double(a.pointSize.width), pointHeight: Double(a.pointSize.height),
            fps: a.settings.fps, duration: duration, startedAt: a.startedAt,
            cursor: cursor, clicks: clicks)
        meta.keys = rawKeys.compactMap { k in
            let t = k.host - t0
            return (t >= 0 && t <= duration) ? KeyPress(t: t, kind: k.kind) : nil
        }.sorted { $0.t < $1.t }
        meta.windows = InputTimeline.windowTracks(raw: rawWindows, displayOrigin: bounds.origin, pointSize: a.pointSize,
                                                  t0: t0, duration: duration)
        if !rawShapes.defs.isEmpty {
            let dir = a.directory.appendingPathComponent("cursors", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            for d in rawShapes.defs { try? d.png.write(to: dir.appendingPathComponent("\(d.def.id).png")) }
            meta.cursorShapes = rawShapes.defs.map { $0.def }
            // Changes before the first video frame collapse onto t = 0 (the last one wins).
            meta.cursorChanges = rawShapes.events.map { CursorChange(t: max($0.host - t0, 0), id: $0.id) }
                .filter { $0.t <= duration }
        }
        if let camFirst {
            meta.cameraFileName = "cam.mov"
            meta.cameraOffset = camFirst - t0
        }
        if let micFirst {
            meta.micFileName = "mic.m4a"
            meta.micOffset = micFirst - t0
        }
        let session = RecordingSession(directory: a.directory, meta: meta)
        try session.save()
        return session
    }

    // MARK: Private

    private func startTimer(startHost: Double) {
        let t = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.active != nil else { return }
                self.elapsed = HostClock.now() - startHost
            }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private static func makeSessionDirectory() throws -> URL {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let base = f.string(from: Date())
        let fm = FileManager.default
        var dir = RecordingSession.libraryURL.appendingPathComponent(base, isDirectory: true)
        var n = 1
        while fm.fileExists(atPath: dir.path) {
            n += 1
            dir = RecordingSession.libraryURL.appendingPathComponent("\(base)-\(n)", isDirectory: true)
        }
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            throw CaptureError.writerSetupFailed("Cannot create \(dir.path): \(error.localizedDescription)")
        }
        return dir
    }
}
