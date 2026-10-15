import Foundation
import CoreGraphics

// Contract for the full editor. Owned jointly: RENDER agent implements everything that CONSUMES it
// (time mapping, composition, export); EDITOR-UI agent implements everything that MUTATES it.
// Only ADD fields (with defaults) — never rename/remove without telling the other agent.
//
// Time domains:
//  * SOURCE time  = seconds in raw video (same as cursor/click `t`).
//  * OUTPUT time  = seconds in the exported/previewed video after cuts and speed changes.
//  Segments are listed in OUTPUT order; each maps a source range to output at `speed`.

struct ClipSegment: Codable, Equatable, Identifiable {
    var id = UUID()
    var sourceStart: Double
    var sourceEnd: Double
    /// 0.25 ... 8. Output duration = (sourceEnd - sourceStart) / speed.
    var speed: Double = 1.0
    var isMuted: Bool = false
}

/// A manual zoom region on the OUTPUT timeline.
struct ZoomRegion: Codable, Equatable, Identifiable {
    var id = UUID()
    /// Output-time range.
    var start: Double
    var end: Double
    var scale: Double = 2.0
    /// Focus point, normalized 0...1 of the source frame (origin top-left).
    var focusX: Double = 0.5
    var focusY: Double = 0.5
    /// true = camera follows the smoothed cursor inside the region; false = fixed on focus.
    var followCursor: Bool = true
}

struct TextOverlay: Codable, Equatable, Identifiable {
    var id = UUID()
    var start: Double          // output time
    var end: Double
    var text: String
    /// Normalized center in the OUTPUT frame, origin top-left.
    var x: Double = 0.5
    var y: Double = 0.85
    var fontSize: Double = 48  // points at 1080p output height
    var colorHex: String = "#FFFFFF"
    var hasBackground: Bool = true
    /// Typewriter animation: letters appear one by one.
    var typewriter: Bool = false
    /// Letters per second (raised automatically if the text wouldn't finish before `end`).
    var typeSpeed: Double = 16
    /// Auto keyboard-typing sound synchronized with the animation (kept in sync by the editor).
    var typeSound: Bool = false
}

extension TextOverlay {
    static let typeLead = 0.15
    /// Real letters-per-second used: fast enough to finish before the text disappears.
    var effectiveTypeSpeed: Double {
        let avail = max(end - start - Self.typeLead - 0.4, 0.2)
        return max(typeSpeed, Double(text.count) / avail)
    }
    /// Number of visible characters at OUTPUT time t.
    func typedCount(at t: Double) -> Int {
        guard typewriter else { return text.count }
        let k = Int(floor((t - start - Self.typeLead) * effectiveTypeSpeed)) + 1
        return min(max(k, 0), text.count)
    }
}

enum AspectPreset: String, Codable, CaseIterable, Identifiable {
    case original, landscape16x9, vertical9x16, square1x1, portrait4x5, standard4x3
    var id: String { rawValue }
    /// width / height, nil = same as source.
    var ratio: Double? {
        switch self {
        case .original: return nil
        case .landscape16x9: return 16.0 / 9
        case .vertical9x16: return 9.0 / 16
        case .square1x1: return 1
        case .portrait4x5: return 4.0 / 5
        case .standard4x3: return 4.0 / 3
        }
    }
}

enum BackgroundKind: String, Codable, CaseIterable, Identifiable {
    case gradient, solid, image, blurredVideo
    var id: String { rawValue }
}

enum CameraShape: String, Codable, CaseIterable, Identifiable {
    case circle, roundedRect, squircle, hexagon, star, heart, blob, rectangle
    var id: String { rawValue }
}

/// Webcam placement at an OUTPUT time. Between keyframes everything (rect, shape OUTLINE, corner radius,
/// opacity) is interpolated smoothly (smootherstep), so the camera can go fullscreen and then morph into
/// any cutout shape/position/size. Shapes morph by interpolating their sampled outlines.
struct CameraKeyframe: Codable, Equatable, Identifiable {
    var id = UUID()
    var t: Double
    /// Rect in the normalized OUTPUT canvas, origin top-left. Fullscreen = (0,0,1,1) (camera covers the whole frame).
    var x: Double = 0.78
    var y: Double = 0.70
    var w: Double = 0.2
    var h: Double = 0.2          // note: ignored for circle/square-like shapes when keepSquare (renderer uses min in pixels)
    var shape: CameraShape = .circle
    /// 0...1 corner roundness for roundedRect/rectangle/squircle.
    var cornerRadius: Double = 0.3
    var opacity: Double = 1
    /// Zoom/crop inside the camera image (1 = full camera frame).
    var innerZoom: Double = 1
    var borderWidth: Double = 0     // points at 1080p
    var borderColorHex: String = "#FFFFFF"
    var shadow: Bool = true
}

struct CameraSettings: Codable, Equatable {
    var enabled: Bool = true
    var mirror: Bool = true
    /// Sorted by t. Empty = one default corner bubble for the whole video.
    var keyframes: [CameraKeyframe] = []
}

/// Music / sound effect placed on the OUTPUT timeline.
struct AudioClip: Codable, Equatable, Identifiable {
    var id = UUID()
    /// Absolute path to an audio (mp3/m4a/wav/aiff/caf) or video file (its audio is used).
    var filePath: String
    var name: String = ""
    var isMusic: Bool = true          // false = sound effect
    /// Where it starts on the output timeline.
    var outputStart: Double = 0
    /// Trim inside the file (seconds). sourceEnd nil = until file end.
    var sourceStart: Double = 0
    var sourceEnd: Double? = nil
    var volume: Double = 0.8          // 0...2
    var fadeIn: Double = 0
    var fadeOut: Double = 0
    var loopToFitVideo: Bool = false  // music: loop until the end of the output video
    var isMuted: Bool = false
}

struct WindowCutout: Codable, Equatable, Identifiable {
    var id = UUID()
    /// OUTPUT-time range.
    var start: Double
    var end: Double
    /// WindowTrack.id in session.meta.windows (which window is shown).
    var windowID: Int
    /// Space around the window as a fraction of canvas width (0...0.2).
    var padding: Double = 0.06
    /// Window corner radius in points (macOS windows ≈ 10–14).
    var cornerRadius: Double = 12
    /// Seconds for the smooth appearance / disappearance (screen -> window and back).
    var transition: Double = 0.45
    var shadow: Bool = true
}

struct KeyboardSoundSettings: Codable, Equatable {
    var enabled: Bool = false
    /// "soft", "mechanical", "typewriter", "bubble", "paper"
    var style: String = "soft"
    var volume: Double = 0.8
}

struct EditStyle: Codable, Equatable {
    var aspect: AspectPreset = .landscape16x9
    var backgroundKind: BackgroundKind = .gradient
    /// For .image: absolute path to image file.
    var backgroundImagePath: String? = nil
    var shadowIntensity: Double = 0.5     // 0...1
    var showCursor: Bool = true
    /// While a window cut-out is active, show the recorded screen (the desktop wallpaper) behind the window instead of the plain background.
    var cutoutScreenBackdrop: Bool = false
}

enum BlurKind: String, Codable, CaseIterable, Identifiable {
    case blur, pixelate, cover
    var id: String { rawValue }
    var title: String {
        switch self { case .blur: return "Размытие"; case .pixelate: return "Пиксели"; case .cover: return "Закрасить" }
    }
}

enum BlurAnchor: String, Codable, CaseIterable, Identifiable {
    /// Rect is in normalized SCREEN coordinates: it follows the content when the camera zooms / pans.
    case screen
    /// Rect is in normalized OUTPUT frame coordinates: it stays put on the canvas.
    case frame
    var id: String { rawValue }
}

/// A rectangle that hides what is under it (secrets, faces, notifications) during an OUTPUT-time range.
struct BlurRegion: Codable, Equatable, Identifiable {
    var id = UUID()
    var start: Double
    var end: Double
    /// Normalized rect, origin top-left (screen- or frame-relative, see `anchor`).
    var x: Double = 0.35
    var y: Double = 0.35
    var w: Double = 0.3
    var h: Double = 0.2
    var kind: BlurKind = .blur
    /// 0...1 (blur radius / pixel size).
    var strength: Double = 0.6
    /// 0...1 of half the shorter side.
    var cornerRadius: Double = 0.2
    var anchor: BlurAnchor = .screen
}

enum MochiHat: String, Codable, CaseIterable, Identifiable {
    case none, witch, party, crown, beanie
    var id: String { rawValue }
    var title: String {
        switch self { case .none: return "Без шляпы"; case .witch: return "Ведьма"; case .party: return "Колпак"; case .crown: return "Корона"; case .beanie: return "Шапка" }
    }
}

/// Mochi at the bottom of the frame: bounces and opens his mouth to the loudness of the voice.
struct MochiOverlay: Codable, Equatable {
    var enabled: Bool = false
    /// Centre of the body, normalized in the output frame, origin top-left.
    var x: Double = 0.5
    var y: Double = 0.84
    /// Body width as a fraction of output HEIGHT.
    var size: Double = 0.2
    var hat: MochiHat = .none
    /// true = black body + white eyes, false = white body + black eyes.
    var darkBody: Bool = true
    var reactMic: Bool = true
    /// Sound effects / voice-over files from the SFX lane.
    var reactVoice: Bool = true
    var reactMusic: Bool = false
    /// 0...2 how high he hops.
    var bounce: Double = 1.0
    /// 0.3...3 input gain for the loudness.
    var sensitivity: Double = 1.0
    var mouth: Bool = true
}

struct MicSettings: Codable, Equatable {
    var enabled: Bool = true
    var volume: Double = 1.0
}

struct EditProject: Codable, Equatable {
    /// Existing RenderSettings are reused for cursor/zoom-auto/padding/corner/gradient colors/output size.
    var render = RenderSettings()
    var style = EditStyle()
    /// Empty = whole video at 1x (renderer must treat as one full segment).
    var segments: [ClipSegment] = []
    var zoomRegions: [ZoomRegion] = []
    var texts: [TextOverlay] = []
    /// Webcam overlay (only if session.meta.cameraFileName != nil).
    var camera = CameraSettings()
    /// Music and sound effects (mixed over the original audio).
    var audioClips: [AudioClip] = []
    /// Automatic keyboard typing sounds from the recorded key presses.
    var keyboard = KeyboardSoundSettings()
    /// "Window cut-outs": while one is active ONLY that window is shown (cropped from the screen recording, following
    /// the window as it moves) instead of the whole screen; outside of cut-outs the whole screen is shown.
    var windowCutouts: [WindowCutout] = []
    /// Blur / pixelate / cover rectangles.
    var blurs: [BlurRegion] = []
    /// Mochi that reacts to the voice.
    var mochi = MochiOverlay()
    /// Microphone track recorded together with the screen (meta.micFileName).
    var mic = MicSettings()
    /// Volume of the original video's own audio, 0...2.
    var originalVolume: Double = 1.0
    /// Auto-generated click zooms are used when render.autoZoom == true, in addition to manual regions
    /// (manual regions override auto ones where they overlap).
    var exportFormat: ExportFormat = .mp4HEVC

    enum ExportFormat: String, Codable, CaseIterable, Identifiable {
        case mp4HEVC, mp4H264, mov, gif
        var id: String { rawValue }
    }
}

extension EditProject {
    /// Segments to use (default: one full-length 1x segment).
    func effectiveSegments(sourceDuration: Double) -> [ClipSegment] {
        segments.isEmpty ? [ClipSegment(sourceStart: 0, sourceEnd: sourceDuration)] : segments
    }
    func outputDuration(sourceDuration: Double) -> Double {
        effectiveSegments(sourceDuration: sourceDuration).reduce(0) { $0 + ($1.sourceEnd - $1.sourceStart) / max($1.speed, 0.01) }
    }
    /// output time -> source time
    func sourceTime(forOutput t: Double, sourceDuration: Double) -> Double {
        var acc = 0.0
        let segs = effectiveSegments(sourceDuration: sourceDuration)
        for s in segs {
            let d = (s.sourceEnd - s.sourceStart) / max(s.speed, 0.01)
            if t < acc + d { return s.sourceStart + (t - acc) * s.speed }
            acc += d
        }
        return segs.last?.sourceEnd ?? 0
    }
    /// source time -> output time (nil if the source time was cut out)
    func outputTime(forSource t: Double, sourceDuration: Double) -> Double? {
        var acc = 0.0
        for s in effectiveSegments(sourceDuration: sourceDuration) {
            if t >= s.sourceStart && t <= s.sourceEnd { return acc + (t - s.sourceStart) / max(s.speed, 0.01) }
            acc += (s.sourceEnd - s.sourceStart) / max(s.speed, 0.01)
        }
        return nil
    }
}

extension RecordingSession {
    /// Wraps an arbitrary imported video file (no cursor/click data) so it can be edited.
    /// The directory is the file's folder; videoFileName its name. Size/duration must be read by the caller.
    static func imported(videoURL: URL, width: Int, height: Int, fps: Int, duration: Double) -> RecordingSession {
        RecordingSession(directory: videoURL.deletingLastPathComponent(),
                         meta: RecordingMetadata(videoFileName: videoURL.lastPathComponent, width: width, height: height,
                                                 pointWidth: Double(width), pointHeight: Double(height), fps: fps,
                                                 duration: duration, startedAt: Date(), cursor: [], clicks: []))
    }
}

extension TextOverlay {
    enum CodingKeys: String, CodingKey {
        case id, start, end, text, x, y, fontSize, colorHex, hasBackground, typewriter, typeSpeed, typeSound
    }
    /// Lenient decoding: projects saved before newer fields existed still open.
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        start = try c.decode(Double.self, forKey: .start)
        end = try c.decode(Double.self, forKey: .end)
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        x = try c.decodeIfPresent(Double.self, forKey: .x) ?? 0.5
        y = try c.decodeIfPresent(Double.self, forKey: .y) ?? 0.85
        fontSize = try c.decodeIfPresent(Double.self, forKey: .fontSize) ?? 48
        colorHex = try c.decodeIfPresent(String.self, forKey: .colorHex) ?? "#FFFFFF"
        hasBackground = try c.decodeIfPresent(Bool.self, forKey: .hasBackground) ?? true
        typewriter = try c.decodeIfPresent(Bool.self, forKey: .typewriter) ?? false
        typeSpeed = try c.decodeIfPresent(Double.self, forKey: .typeSpeed) ?? 16
        typeSound = try c.decodeIfPresent(Bool.self, forKey: .typeSound) ?? false
    }
}
