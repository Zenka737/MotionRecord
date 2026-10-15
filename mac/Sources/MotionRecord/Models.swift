import Foundation
import CoreGraphics

// MARK: - Shared contracts. Do not change signatures without telling the other modules' owners.
//
// Coordinate conventions (IMPORTANT, everything depends on these):
//  * Time `t` is seconds since the PTS of the FIRST video frame of raw.mov (so t=0 is video start).
//  * Cursor / click positions are in POINTS, origin = TOP-LEFT of the captured display, y grows down.
//    (display size in points = RecordingMetadata.pointWidth x pointHeight; pixel size = width x height.)

struct RecordingSettings: Codable, Equatable {
    /// Capture frame rate: 15, 24, 30, 60, 120 (user choice).
    var fps: Int = 60
    /// CGDirectDisplayID; 0 = main display.
    var displayID: UInt32 = 0
    /// Show the recording pill in the notch while recording.
    var showNotchIndicator: Bool = true
    /// Also record the webcam to cam.mov (AVCaptureSession), same clock as the screen.
    var recordCamera: Bool = false
    /// AVCaptureDevice.uniqueID; nil = default camera.
    var cameraDeviceID: String? = nil
    /// Record WHEN keys are pressed (never which keys) so keyboard sounds can be added automatically.
    /// Needs the macOS "Input Monitoring" permission.
    var recordKeys: Bool = true
    /// Record the microphone to mic.m4a (same clock as the screen). Needs the microphone permission.
    var recordMic: Bool = false
    /// AVCaptureDevice.uniqueID; nil = default microphone.
    var micDeviceID: String? = nil
}

struct CursorSample: Codable, Equatable {
    var t: Double
    var x: Double
    var y: Double
}

/// One system cursor shape seen during recording (arrow, pointing hand, I-beam, closed hand ...). PNG: cursors/<id>.png.
struct CursorShapeDef: Codable, Equatable {
    var id: String
    /// Size and hotspot in POINTS, hotspot measured from the image's top-left.
    var w: Double
    var h: Double
    var hotX: Double
    var hotY: Double
}

/// The cursor shape changed to `id` at time `t` (same clock as the cursor track).
struct CursorChange: Codable, Equatable {
    var t: Double
    var id: String
}

struct ClickEvent: Codable, Equatable {
    var t: Double
    var x: Double
    var y: Double
    /// 0 = left, 1 = right, 2+ = other
    var button: Int
    var isDown: Bool
}

struct RecordingMetadata: Codable {
    var videoFileName: String = "raw.mov"
    /// Video pixel size (what's inside raw.mov).
    var width: Int
    var height: Int
    /// Captured display size in points.
    var pointWidth: Double
    var pointHeight: Double
    var fps: Int
    var duration: Double
    var startedAt: Date
    /// Dense cursor track (>=120 Hz), sorted by t.
    var cursor: [CursorSample]
    var clicks: [ClickEvent]
    /// Webcam file in the same folder (nil = no camera). Its t=0 is aligned to the screen video t=0
    /// (cameraOffset = camera PTS of first frame minus screen first-frame PTS, in seconds; usually ~0).
    var cameraFileName: String? = nil
    var cameraOffset: Double = 0
    /// Microphone file in the same folder (nil = none). micOffset = mic PTS of first sample minus screen first-frame PTS.
    var micFileName: String? = nil
    var micOffset: Double = 0
    /// Key press times only (kind: 0 letter/other, 1 space, 2 return, 3 delete). Content is NEVER stored.
    var keys: [KeyPress] = []
    /// Positions of on-screen app windows over time (for the editor's "window cut-out" feature).
    var windows: [WindowTrack] = []
    /// Real system cursor shapes + when they changed (empty for older recordings = plain arrow).
    var cursorShapes: [CursorShapeDef] = []
    var cursorChanges: [CursorChange] = []
}

/// One window (CGWindowID) tracked during recording. Samples are written only when the window changed.
struct WindowTrack: Codable, Equatable, Identifiable {
    var id: Int                 // CGWindowID (unique within the recording)
    var app: String             // owner name, e.g. "Safari"
    var title: String           // window title (may be empty)
    var pid: Int32
    var samples: [WindowSample]  // sorted by t; window exists from first sample until a sample with visible == false
}

struct WindowSample: Codable, Equatable {
    var t: Double               // seconds since first video frame (same clock as cursor)
    /// Frame in POINTS, origin TOP-LEFT of the captured display (same space as cursor positions).
    var x: Double
    var y: Double
    var w: Double
    var h: Double
    /// 0 = frontmost window of the recording at that time, 1 = behind it, ...
    var z: Int
    var visible: Bool = true
}

struct KeyPress: Codable, Equatable {
    var t: Double
    var kind: Int
}

struct RecordingSession {
    var directory: URL
    var meta: RecordingMetadata

    var videoURL: URL { directory.appendingPathComponent(meta.videoFileName) }
    var metaURL: URL { directory.appendingPathComponent("meta.json") }

    func save() throws {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        try enc.encode(meta).write(to: metaURL, options: .atomic)
    }

    static func load(from directory: URL) throws -> RecordingSession {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        let data = try Data(contentsOf: directory.appendingPathComponent("meta.json"))
        return RecordingSession(directory: directory, meta: try dec.decode(RecordingMetadata.self, from: data))
    }

    /// ~/Movies/MotionRecord
    static var libraryURL: URL {
        let base = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("MotionRecord", isDirectory: true)
    }
}

struct DisplayInfo: Identifiable, Hashable {
    var id: UInt32          // CGDirectDisplayID
    var name: String
    var pointWidth: Int
    var pointHeight: Int
    var isMain: Bool
}

/// Settings of the post-processing look ("Screen Studio"-style).
struct RenderSettings: Codable, Equatable {
    // Zoom
    var autoZoom: Bool = true
    /// Zoom factor while zoomed in on a click (1.0 = none). Typical 1.5...3.0
    var zoomScale: Double = 2.0
    /// Seconds to ease in/out of a zoom.
    var zoomDuration: Double = 0.7
    /// Seconds the camera stays zoomed after the last click of a burst.
    var zoomHold: Double = 1.4
    /// Camera follow smoothness 0...1 (higher = floatier/slower).
    var cameraSmoothing: Double = 0.55

    // Cursor
    /// Cursor smoothness 0...1 (0 = raw, 1 = very floaty).
    var cursorSmoothing: Double = 0.5
    var cursorScale: Double = 1.6
    /// "macArrow" = real macOS system arrow (NSCursor.arrow image, hotspot-correct), "classic" = procedural white arrow,
    /// "dot", "ring", "custom" (uses customCursorPath: PNG/SVG/PDF file; hotspot = customCursorHotspotX/Y normalized 0...1).
    var cursorStyle: String = "macArrow"
    var customCursorPath: String? = nil
    var customCursorHotspotX: Double = 0
    var customCursorHotspotY: Double = 0
    /// Click animation: cursor smoothly shrinks to this scale on mouse down (1 = no shrink) and springs back on release.
    var clickShrinkScale: Double = 0.78
    /// Seconds for the shrink / return animation.
    var clickAnimDuration: Double = 0.14
    var showClickRipple: Bool = true

    // Frame look
    /// Padding around the video as a fraction of output width (0...0.15).
    var padding: Double = 0.05
    var cornerRadius: Double = 16
    var shadow: Bool = true
    /// Two gradient colors, "#RRGGBB".
    var backgroundTop: String = "#5B3DF5"
    var backgroundBottom: String = "#D946EF"

    /// Output fps; 0 = same as source.
    var outputFPS: Int = 0
    /// Output height in pixels; 0 = same as source.
    var outputHeight: Int = 0
}
