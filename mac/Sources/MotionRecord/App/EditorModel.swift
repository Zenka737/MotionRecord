import Foundation
import AVFoundation
import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

enum EditorSelection: Equatable {
    case segment(UUID)
    case zoom(UUID)
    case autoZoom(UUID)
    case text(UUID)
    case camera(UUID)
    case audio(UUID)
    case window(UUID)
    case blur(UUID)
}

enum InspectorTab: String, CaseIterable, Identifiable {
    case video, camera, audio, cursor, zoom, text, effects, window, export
    var id: String { rawValue }
    var title: String {
        switch self {
        case .video: return "Видео"
        case .camera: return "Камера"
        case .audio: return "Аудио"
        case .cursor: return "Курсор"
        case .zoom: return "Зум"
        case .text: return "Текст"
        case .effects: return "Эффекты"
        case .window: return "Окно"
        case .export: return "Экспорт"
        }
    }
    var icon: String {
        switch self {
        case .video: return "rectangle.on.rectangle"
        case .camera: return "web.camera"
        case .audio: return "waveform"
        case .cursor: return "cursorarrow"
        case .zoom: return "plus.magnifyingglass"
        case .text: return "textformat"
        case .effects: return "sparkles"
        case .window: return "macwindow"
        case .export: return "square.and.arrow.up"
        }
    }
}

struct AudioInfo {
    var duration: Double
    var waveform: [Float]
}

struct SegmentLayout: Identifiable {
    var seg: ClipSegment
    var outStart: Double
    var outEnd: Double
    var id: UUID { seg.id }
}

/// Drives the preview player, editing state, undo/redo, autosave and export for one session.
@MainActor
final class EditorModel: ObservableObject, Identifiable {
    let session: RecordingSession
    let player = AVPlayer()
    let projectURL: URL
    let isImported: Bool

    // Edit state
    @Published private(set) var project: EditProject
    @Published var selection: EditorSelection?
    @Published var inspectorTab: InspectorTab = .video
    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false

    // Playback state
    @Published var playhead: Double = 0
    @Published private(set) var isPlaying = false
    @Published var loop = false
    /// Window-pick mode: preview shows the whole screen (no zoom / cut-outs) and hovering highlights windows.
    @Published private(set) var pickingWindow = false

    // Timeline view state
    @Published var pps: Double = 80
    @Published var scrollX: Double = 0
    @Published var timelineWidth: Double = 800
    @Published var snapping = true

    // Derived / async data
    @Published private(set) var thumbnails: [CGImage] = []
    @Published private(set) var audioInfos: [String: AudioInfo] = [:]
    /// Loudness of the recorded microphone (for the waveform lane and "cut pauses").
    @Published private(set) var micEnvelope: AudioEnvelope?
    @Published private(set) var autoZooms: [ZoomRegion] = []
    @Published private(set) var isPreparing = false
    @Published private(set) var renderSize: CGSize = .zero
    @Published private(set) var previewError: String?
    /// The compositor of the current preview: used to place boxes over the picture (zoom-aware).
    var previewCompositor: FrameCompositor?
    @Published private(set) var exportProgress: Double?
    @Published var showExportSheet = false
    @Published var exportResultURL: URL?
    @Published var exportError: String?

    var onError: ((String) -> Void)?

    private var prepareTask: Task<Void, Never>?
    private var generation = 0
    private var autoZoomTask: Task<Void, Never>?
    private var exportTask: Task<Void, Never>?
    private var saveWork: DispatchWorkItem?
    private var undoStack: [EditProject] = []
    private var redoStack: [EditProject] = []
    private var lastCoalesceKey: String?
    private var lastCoalesceTime = Date.distantPast
    private var gestureBase: EditProject?
    private var timeObserver: Any?
    private var cancellables = Set<AnyCancellable>()
    private var endObserver: NSObjectProtocol?
    private var didFitTimeline = false

    init(session: RecordingSession, projectURL: URL, isImported: Bool, defaultRender: RenderSettings) {
        self.session = session
        self.projectURL = projectURL
        self.isImported = isImported
        var p = EditProject()
        p.render = defaultRender
        if let data = try? Data(contentsOf: projectURL) {
            if let loaded = LenientDecode.decode(EditProject.self, from: data, defaults: EditProject()) {
                p = loaded
            } else {
                // Old / incompatible project.json: keep a backup and start fresh.
                try? FileManager.default.copyItem(at: projectURL, to: projectURL.deletingLastPathComponent().appendingPathComponent("project.old.json"))
            }
        }
        if p.segments.isEmpty { p.segments = [ClipSegment(sourceStart: 0, sourceEnd: max(session.meta.duration, 0.1))] }
        self.project = p
        let interval = CMTime(seconds: 1.0 / 30.0, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] t in
            MainActor.assumeIsolated {
                guard let self, t.isValid, !self.isScrubbing else { return }
                let s = t.seconds
                if s.isFinite { self.playhead = min(max(s, 0), self.outputDuration) }
            }
        }
        player.publisher(for: \.timeControlStatus)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] st in self?.isPlaying = (st != .paused) }
            .store(in: &cancellables)
        loadThumbnails()
        loadAudioInfos()
        loadMicEnvelope()
    }

    deinit {
        prepareTask?.cancel()
        if let o = timeObserver { player.removeTimeObserver(o) }
        if let e = endObserver { NotificationCenter.default.removeObserver(e) }
    }

    // MARK: Basic info

    var title: String { isImported ? session.videoURL.deletingPathExtension().lastPathComponent : session.directory.lastPathComponent }
    var sourceDuration: Double { max(session.meta.duration, 0.1) }
    var outputDuration: Double { max(project.outputDuration(sourceDuration: sourceDuration), 0.1) }
    var frameDuration: Double { 1.0 / Double(max(min(session.meta.fps, 120), 10)) }
    var hasCursorData: Bool { !session.meta.cursor.isEmpty }
    var isScrubbing = false

    var layout: [SegmentLayout] {
        var acc = 0.0
        return project.effectiveSegments(sourceDuration: sourceDuration).map { s in
            let d = (s.sourceEnd - s.sourceStart) / max(s.speed, 0.01)
            defer { acc += d }
            return SegmentLayout(seg: s, outStart: acc, outEnd: acc + d)
        }
    }

    var selectedSegment: ClipSegment? {
        if case .segment(let id) = selection { return layout.first { $0.id == id }?.seg }
        return nil
    }
    var selectedZoom: ZoomRegion? {
        if case .zoom(let id) = selection { return project.zoomRegions.first { $0.id == id } }
        return nil
    }
    var selectedWindowCutout: WindowCutout? {
        if case .window(let id) = selection { return project.windowCutouts.first { $0.id == id } }
        return nil
    }
    var selectedText: TextOverlay? {
        if case .text(let id) = selection { return project.texts.first { $0.id == id } }
        return nil
    }

    var selectedBlur: BlurRegion? {
        if case .blur(let id) = selection { return project.blurs.first { $0.id == id } }
        return nil
    }
    var hasMic: Bool {
        guard let n = session.meta.micFileName else { return false }
        return FileManager.default.fileExists(atPath: session.directory.appendingPathComponent(n).path)
    }
    var selectedCameraKey: CameraKeyframe? {
        if case .camera(let id) = selection { return project.camera.keyframes.first { $0.id == id } }
        return nil
    }
    var hasCamera: Bool { session.meta.cameraFileName != nil }
    var outputAspect: Double {
        renderSize.height > 0 ? Double(renderSize.width / renderSize.height) : Double(session.meta.width) / Double(max(session.meta.height, 1))
    }

    /// Click positions mapped to output time.
    var clickMarkers: [Double] {
        session.meta.clicks.filter { $0.isDown }.compactMap {
            project.outputTime(forSource: $0.t, sourceDuration: sourceDuration)
        }
    }

    func stop() {
        prepareTask?.cancel()
        exportTask?.cancel()
        player.pause()
        saveNow()
    }

    // MARK: Project mutation / undo

    private func pushUndo(coalesce key: String?) {
        let now = Date()
        if let key, key == lastCoalesceKey, now.timeIntervalSince(lastCoalesceTime) < 0.8 {
            lastCoalesceTime = now
            return
        }
        undoStack.append(project)
        if undoStack.count > 150 { undoStack.removeFirst() }
        redoStack.removeAll()
        lastCoalesceKey = key
        lastCoalesceTime = now
        canUndo = true; canRedo = false
    }

    /// Applies an edit with an undo snapshot. Equal results are ignored.
    func edit(coalesce key: String? = nil, remap: Bool = false, _ f: (inout EditProject) -> Void) {
        var p = project
        f(&p)
        if p == project { return }
        pushUndo(coalesce: key)
        if remap { Self.remapItems(old: project, new: &p, dur: sourceDuration) }
        setProject(p)
    }

    /// Gesture-style edits (drags): one undo step per gesture, all updates computed from the base.
    func beginGesture() {
        var base = project
        if base.segments.isEmpty { base.segments = base.effectiveSegments(sourceDuration: sourceDuration) }
        pushUndo(coalesce: nil)
        lastCoalesceKey = nil
        gestureBase = base
    }

    func updateGesture(remap: Bool = false, _ f: (inout EditProject) -> Void) {
        guard let base = gestureBase else { return }
        var p = base
        f(&p)
        if remap { Self.remapItems(old: base, new: &p, dur: sourceDuration) }
        if p != project { setProject(p) }
    }

    func endGesture() { gestureBase = nil }

    private func setProject(_ p: EditProject) {
        let segmentsChanged = p.segments != project.segments
        project = p
        playhead = min(playhead, outputDuration)
        AppState.shared.rememberRenderSettings(p.render)
        scheduleSave()
        schedulePrepare()
        _ = segmentsChanged
        syncTypingSounds()
        syncKeyboardSound()
    }

    // MARK: Automatic keyboard sound from recorded key presses

    private var keyboardInFlight = Set<String>()

    /// Keeps one "Клавиатура" clip (all key presses mapped to OUTPUT time) in sync with project.keyboard.
    private func syncKeyboardSound() {
        func isKb(_ c: AudioClip) -> Bool { URL(fileURLWithPath: c.filePath).lastPathComponent.hasPrefix("keyboard-") && !c.filePath.contains("keyboard-demo") }
        let kb = project.keyboard
        let keys = session.meta.keys
        guard kb.enabled, !keys.isEmpty, let style = KeyboardStyle(rawValue: kb.style) else {
            if project.audioClips.contains(where: isKb) {
                var p = project; p.audioClips.removeAll(where: isKb); setProject(p)
            }
            return
        }
        let srcDur = sourceDuration
        let times: [(Double, Int)] = keys.compactMap { k in
            project.outputTime(forSource: k.t, sourceDuration: srcDur).map { ($0, k.kind) }
        }
        let dur = outputDuration
        let url = MusicGenerator.keyboardURL(style: style, times: times, duration: dur)
        if let i = project.audioClips.firstIndex(where: isKb), project.audioClips[i].filePath == url.path {
            if abs(project.audioClips[i].volume - kb.volume) > 0.001 {
                var p = project; p.audioClips[i].volume = kb.volume; setProject(p)
            }
            return
        }
        guard !keyboardInFlight.contains(url.path) else { return }
        keyboardInFlight.insert(url.path)
        Task { [weak self] in
            let ok: Bool = await Task.detached(priority: .utility) {
                if FileManager.default.fileExists(atPath: url.path) { return true }
                return (try? MusicGenerator.generateKeyboard(style: style, times: times, duration: dur, to: url)) != nil
            }.value
            guard let self else { return }
            self.keyboardInFlight.remove(url.path)
            guard ok, self.project.keyboard.enabled, let info = await RenderBridge.audioInfo(url: url) else { return }
            self.audioInfos[url.path] = AudioInfo(duration: info.duration, waveform: info.waveform)
            var q = self.project
            q.audioClips.removeAll(where: isKb)
            var c = AudioClip(filePath: url.path)
            c.name = "Клавиатура"; c.isMusic = false; c.volume = self.project.keyboard.volume; c.outputStart = 0
            q.audioClips.append(c)
            self.setProject(q)
        }
    }

    // MARK: Auto typing sound for typewriter texts

    private var typingInFlight = Set<String>()

    /// Keeps one "Печать" sound clip per typewriter text with typeSound on: created, moved with the text,
    /// regenerated when text/speed change, removed when switched off. Clips are linked by file name typing-<textID>-….wav.
    private func syncTypingSounds() {
        let wanted = project.texts.filter { $0.typewriter && $0.typeSound && !$0.text.isEmpty }
        let wantedIDs = Set(wanted.map { $0.id.uuidString })
        func isTyping(_ c: AudioClip) -> Bool { URL(fileURLWithPath: c.filePath).lastPathComponent.hasPrefix("typing-") }
        func textID(_ c: AudioClip) -> String {
            let n = URL(fileURLWithPath: c.filePath).deletingPathExtension().lastPathComponent  // typing-<uuid>-<hash>
            return String(n.dropFirst(7).prefix(36))
        }
        var p = project
        var changed = false
        let before = p.audioClips.count
        p.audioClips.removeAll { isTyping($0) && !wantedIDs.contains(textID($0)) }
        if p.audioClips.count != before { changed = true }
        for t in wanted {
            let url = MusicGenerator.typingURL(textID: t.id, text: t.text, speed: t.effectiveTypeSpeed, lead: TextOverlay.typeLead)
            if let i = p.audioClips.firstIndex(where: { isTyping($0) && textID($0) == t.id.uuidString }) {
                if p.audioClips[i].filePath == url.path {
                    if abs(p.audioClips[i].outputStart - t.start) > 0.0005 { p.audioClips[i].outputStart = t.start; changed = true }
                    continue
                }
            }
            guard !typingInFlight.contains(url.path) else { continue }
            typingInFlight.insert(url.path)
            let tid = t.id
            let (text, speed) = (t.text, t.effectiveTypeSpeed)
            Task { [weak self] in
                let ok: Bool = await Task.detached(priority: .utility) {
                    if FileManager.default.fileExists(atPath: url.path) { return true }
                    return (try? MusicGenerator.generateTyping(text: text, speed: speed, lead: TextOverlay.typeLead, to: url)) != nil
                }.value
                guard let self else { return }
                self.typingInFlight.remove(url.path)
                guard ok, let info = await RenderBridge.audioInfo(url: url),
                      var q = Optional(self.project), let ti = q.texts.firstIndex(where: { $0.id == tid }),
                      q.texts[ti].typewriter, q.texts[ti].typeSound else { return }
                self.audioInfos[url.path] = AudioInfo(duration: info.duration, waveform: info.waveform)
                q.audioClips.removeAll { isTyping($0) && textID($0) == tid.uuidString }
                var c = AudioClip(filePath: url.path)
                c.name = "Печать"; c.isMusic = false; c.volume = 0.9; c.outputStart = q.texts[ti].start
                q.audioClips.append(c)
                self.setProject(q)
            }
        }
        if changed { setProject(p) }
    }

    func undo() {
        guard let prev = undoStack.popLast() else { return }
        redoStack.append(project)
        lastCoalesceKey = nil
        validateSelection(after: prev)
        setProject(prev)
        canUndo = !undoStack.isEmpty; canRedo = true
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(project)
        lastCoalesceKey = nil
        validateSelection(after: next)
        setProject(next)
        canUndo = true; canRedo = !redoStack.isEmpty
    }

    private func validateSelection(after p: EditProject) {
        switch selection {
        case .segment(let id)?:
            if !p.effectiveSegments(sourceDuration: sourceDuration).contains(where: { $0.id == id }) { selection = nil }
        case .zoom(let id)?:
            if !p.zoomRegions.contains(where: { $0.id == id }) { selection = nil }
        case .text(let id)?:
            if !p.texts.contains(where: { $0.id == id }) { selection = nil }
        case .window(let id)?:
            if !p.windowCutouts.contains(where: { $0.id == id }) { selection = nil }
        case .blur(let id)?:
            if !p.blurs.contains(where: { $0.id == id }) { selection = nil }
        case .audio(let id)?:
            if !p.audioClips.contains(where: { $0.id == id }) { selection = nil }
        case .camera(let id)?:
            if !p.camera.keyframes.contains(where: { $0.id == id }) { selection = nil }
        default: break
        }
    }

    /// A binding into the project that records undo steps (coalesced for slider drags).
    func binding<T: Equatable>(_ kp: WritableKeyPath<EditProject, T>) -> Binding<T> {
        Binding(get: { self.project[keyPath: kp] },
                set: { v in self.edit(coalesce: "\(kp)") { $0[keyPath: kp] = v } })
    }

    /// Binding into the selected zoom region.
    func zoomBinding<T: Equatable>(_ id: UUID, _ kp: WritableKeyPath<ZoomRegion, T>, fallback: T) -> Binding<T> {
        Binding(get: { self.project.zoomRegions.first { $0.id == id }?[keyPath: kp] ?? fallback },
                set: { v in
                    self.edit(coalesce: "zoom\(id)\(kp)") { p in
                        if let i = p.zoomRegions.firstIndex(where: { $0.id == id }) { p.zoomRegions[i][keyPath: kp] = v }
                    }
                })
    }

    func textBinding<T: Equatable>(_ id: UUID, _ kp: WritableKeyPath<TextOverlay, T>, fallback: T) -> Binding<T> {
        Binding(get: { self.project.texts.first { $0.id == id }?[keyPath: kp] ?? fallback },
                set: { v in
                    self.edit(coalesce: "text\(id)\(kp)") { p in
                        if let i = p.texts.firstIndex(where: { $0.id == id }) { p.texts[i][keyPath: kp] = v }
                    }
                })
    }

    // MARK: Remapping of output-time items when segments change

    private static func mapNearest(_ t: Double, old: EditProject, new: EditProject, dur: Double) -> Double {
        let s = old.sourceTime(forOutput: t, sourceDuration: dur)
        if let o = new.outputTime(forSource: s, sourceDuration: dur) { return o }
        var acc = 0.0
        for seg in new.effectiveSegments(sourceDuration: dur) {
            if s <= seg.sourceStart { return acc }
            acc += (seg.sourceEnd - seg.sourceStart) / max(seg.speed, 0.01)
        }
        return acc
    }

    private static func remapItems(old: EditProject, new: inout EditProject, dur: Double) {
        guard old.segments != new.segments else { return }
        let total = new.outputDuration(sourceDuration: dur)
        func map(_ s: Double, _ e: Double) -> (Double, Double)? {
            let a = mapNearest(s, old: old, new: new, dur: dur)
            let b = min(mapNearest(e, old: old, new: new, dur: dur), total)
            return b - a >= 0.08 ? (a, b) : nil
        }
        new.zoomRegions = new.zoomRegions.compactMap { z in
            guard let (a, b) = map(z.start, z.end) else { return nil }
            var z = z; z.start = a; z.end = b; return z
        }
        new.camera.keyframes = new.camera.keyframes.map { k in
            var k = k; k.t = min(mapNearest(k.t, old: old, new: new, dur: dur), total); return k
        }.sorted { $0.t < $1.t }
        new.texts = new.texts.compactMap { t in
            guard let (a, b) = map(t.start, t.end) else { return nil }
            var t = t; t.start = a; t.end = b; return t
        }
        new.blurs = new.blurs.compactMap { b in
            guard let (a, c) = map(b.start, b.end) else { return nil }
            var b = b; b.start = a; b.end = c; return b
        }
        new.windowCutouts = new.windowCutouts.compactMap { w in
            guard let (a, b) = map(w.start, w.end) else { return nil }
            var w = w; w.start = a; w.end = b; return w
        }
    }

    // MARK: Editing operations

    func split() {
        // Split acts on what is selected (never the video when a zoom / text / sound block is selected).
        switch selection {
        case .audio: splitSelectedAudio(); return
        case .zoom(let id):
            guard let z = project.zoomRegions.first(where: { $0.id == id }), playhead > z.start + 0.2, playhead < z.end - 0.2 else { return }
            let t = playhead
            edit { p in
                guard let i = p.zoomRegions.firstIndex(where: { $0.id == id }) else { return }
                var b = p.zoomRegions[i]; b.id = UUID(); b.start = t
                p.zoomRegions[i].end = t
                p.zoomRegions.insert(b, at: i + 1)
            }
            return
        case .text(let id):
            guard let x = project.texts.first(where: { $0.id == id }), playhead > x.start + 0.2, playhead < x.end - 0.2 else { return }
            let t = playhead
            edit { p in
                guard let i = p.texts.firstIndex(where: { $0.id == id }) else { return }
                var b = p.texts[i]; b.id = UUID(); b.start = t
                p.texts[i].end = t
                p.texts.insert(b, at: i + 1)
            }
            return
        case .blur(let id):
            guard let x = project.blurs.first(where: { $0.id == id }), playhead > x.start + 0.2, playhead < x.end - 0.2 else { return }
            let t = playhead
            edit { p in
                guard let i = p.blurs.firstIndex(where: { $0.id == id }) else { return }
                var b = p.blurs[i]; b.id = UUID(); b.start = t
                p.blurs[i].end = t
                p.blurs.insert(b, at: i + 1)
            }
            return
        case .window(let id):
            guard let x = project.windowCutouts.first(where: { $0.id == id }), playhead > x.start + 0.2, playhead < x.end - 0.2 else { return }
            let t = playhead
            edit { p in
                guard let i = p.windowCutouts.firstIndex(where: { $0.id == id }) else { return }
                var b = p.windowCutouts[i]; b.id = UUID(); b.start = t
                p.windowCutouts[i].end = t
                p.windowCutouts.insert(b, at: i + 1)
            }
            return
        default: break
        }
        let t = playhead
        guard let l = layout.first(where: { t > $0.outStart + 0.05 && t < $0.outEnd - 0.05 }) else { return }
        let src = project.sourceTime(forOutput: t, sourceDuration: sourceDuration)
        edit(remap: true) { p in
            var segs = p.effectiveSegments(sourceDuration: sourceDuration)
            guard let i = segs.firstIndex(where: { $0.id == l.id }) else { return }
            var a = segs[i], b = segs[i]
            a.sourceEnd = src
            b.id = UUID(); b.sourceStart = src
            segs[i] = a; segs.insert(b, at: i + 1)
            p.segments = segs
        }
        selection = .segment(l.id)
    }

    func deleteSelection() {
        guard let sel = selection else { return }
        switch sel {
        case .segment(let id):
            let segs = project.effectiveSegments(sourceDuration: sourceDuration)
            guard segs.count > 1 else { return }
            edit(remap: true) { $0.segments = segs.filter { $0.id != id } }
        case .zoom(let id): edit { $0.zoomRegions.removeAll { $0.id == id } }
        case .text(let id): edit { $0.texts.removeAll { $0.id == id } }
        case .window(let id): edit { $0.windowCutouts.removeAll { $0.id == id } }
        case .blur(let id): edit { $0.blurs.removeAll { $0.id == id } }
        case .audio(let id): edit { $0.audioClips.removeAll { $0.id == id } }
        case .camera(let id): edit { $0.camera.keyframes.removeAll { $0.id == id } }
        case .autoZoom: return
        }
        selection = nil
    }

    func duplicateSelection() {
        guard let sel = selection else { return }
        switch sel {
        case .segment(let id):
            edit(remap: true) { p in
                var segs = p.effectiveSegments(sourceDuration: sourceDuration)
                guard let i = segs.firstIndex(where: { $0.id == id }) else { return }
                var c = segs[i]; c.id = UUID()
                segs.insert(c, at: i + 1); p.segments = segs
            }
        case .zoom(let id):
            guard var z = project.zoomRegions.first(where: { $0.id == id }) else { return }
            let len = z.end - z.start
            z.id = UUID(); z.start = min(z.end + 0.1, max(outputDuration - len, 0)); z.end = z.start + len
            let copy = z
            edit { $0.zoomRegions.append(copy) }
            selection = .zoom(copy.id)
        case .text(let id):
            guard var t = project.texts.first(where: { $0.id == id }) else { return }
            let len = t.end - t.start
            t.id = UUID(); t.start = min(t.end + 0.1, max(outputDuration - len, 0)); t.end = t.start + len
            let copy = t
            edit { $0.texts.append(copy) }
            selection = .text(copy.id)
        case .blur(let id):
            guard var b = project.blurs.first(where: { $0.id == id }) else { return }
            let len = b.end - b.start
            b.id = UUID(); b.start = min(b.end + 0.1, max(outputDuration - len, 0)); b.end = b.start + len
            let copy = b
            edit { $0.blurs.append(copy) }
            selection = .blur(copy.id)
        case .window(let id):
            guard var w = project.windowCutouts.first(where: { $0.id == id }) else { return }
            let len = w.end - w.start
            w.id = UUID(); w.start = min(w.end + 0.1, max(outputDuration - len, 0)); w.end = w.start + len
            let copy = w
            guard freeSlot(start: copy.start, length: len, existing: project.windowCutouts.map { ($0.start, $0.end) }) == copy.start else { return }
            edit { $0.windowCutouts.append(copy); $0.windowCutouts.sort { $0.start < $1.start } }
            selection = .window(copy.id)
        case .audio(let id):
            guard var c = project.audioClips.first(where: { $0.id == id }) else { return }
            c.id = UUID(); c.outputStart += clipLength(c) + 0.05
            let copy = c
            edit { $0.audioClips.append(copy) }
            selection = .audio(copy.id)
        case .camera(let id):
            guard var k = project.camera.keyframes.first(where: { $0.id == id }) else { return }
            k.id = UUID(); k.t = min(k.t + 0.5, outputDuration)
            let copy = k
            edit { $0.camera.keyframes.append(copy); $0.camera.keyframes.sort { $0.t < $1.t } }
            selection = .camera(copy.id)
        case .autoZoom: break
        }
    }

    func setSpeed(_ speed: Double, for id: UUID) {
        let sp = min(max(speed, 0.25), 8)
        edit(coalesce: "speed\(id)", remap: true) { p in
            var segs = p.effectiveSegments(sourceDuration: sourceDuration)
            guard let i = segs.firstIndex(where: { $0.id == id }) else { return }
            segs[i].speed = sp
            p.segments = segs
        }
    }

    func toggleMute(_ id: UUID) {
        edit { p in
            var segs = p.effectiveSegments(sourceDuration: sourceDuration)
            guard let i = segs.firstIndex(where: { $0.id == id }) else { return }
            segs[i].isMuted.toggle()
            p.segments = segs
        }
    }

    func addZoom() {
        // Prefer the full length at the playhead; if the spot is cramped, shorten the region before jumping elsewhere.
        let existing = project.zoomRegions.map { ($0.start, $0.end) }
        var picked: (start: Double, len: Double)?
        for l in [2.5, 1.5, 0.8] {
            let len = min(l, outputDuration)
            guard let st = freeSlot(start: playhead, length: len, existing: existing) else { continue }
            if picked == nil { picked = (st, len) }
            if abs(st - min(max(playhead, 0), max(outputDuration - len, 0))) < 0.05 { picked = (st, len); break }
        }
        guard let pk = picked else { return }
        let start = pk.start, len = pk.len
        var z = ZoomRegion(start: start, end: start + len)
        z.scale = project.render.zoomScale
        // Focus on the cursor at the middle of the region if we have cursor data.
        if let f = cursorFocus(atOutput: start + len / 2) { z.focusX = f.x; z.focusY = f.y }
        edit { $0.zoomRegions.append(z) }
        selection = .zoom(z.id)
        inspectorTab = .zoom
    }

    func addText() {
        let len = min(3, outputDuration)
        let start = min(playhead, max(outputDuration - len, 0))
        let t = TextOverlay(start: start, end: start + len, text: "Новый текст")
        edit { $0.texts.append(t) }
        selection = .text(t.id)
        inspectorTab = .text
        // Text fades in over 0.2 s, so at its exact start it's invisible: jump inside it so it shows right away.
        seek(to: start + min(0.5, len / 2))
    }

    // MARK: Microphone: waveform + cutting pauses

    private func loadMicEnvelope() {
        guard let name = session.meta.micFileName else { return }
        let url = session.directory.appendingPathComponent(name)
        Task.detached(priority: .utility) { [weak self] in
            let env = AudioEnvelope.load(url: url)
            await MainActor.run { self?.micEnvelope = env }
        }
    }

    /// Loudness (0...1) of the microphone at SOURCE time `t`.
    func micLevel(atSource t: Double) -> Float { micEnvelope?.value(at: t - session.meta.micOffset) ?? 0 }

    /// Cuts out the pauses in speech (microphone quieter than the threshold for at least `minPause` seconds), keeping a short
    /// breath of `keep` seconds on both sides. Works on the current segments, so speed and mute are preserved.
    @discardableResult
    func removeSilences(minPause: Double = 0.8, keep: Double = 0.15, threshold: Float = 0.08) -> Int {
        guard let env = micEnvelope else { return 0 }
        let off = session.meta.micOffset
        // silent ranges in SOURCE time
        var silent: [(Double, Double)] = []
        var start: Double?
        let step = 1 / AudioEnvelope.hz
        // only where the microphone file actually covers the video
        let from = max(0, off), to = min(sourceDuration, off + env.duration)
        var t = from
        while t <= to + step {
            let inside = t < to
            let quiet = inside && env.value(at: t - off) < threshold
            if quiet, start == nil { start = t }
            if !quiet, let s = start {
                if t - s >= minPause { silent.append((s + keep, t - keep)) }
                start = nil
            }
            t += step
        }
        silent = silent.filter { $0.1 - $0.0 > 0.05 }
        guard !silent.isEmpty else { return 0 }
        var cuts = 0
        edit(remap: true) { p in
            var out: [ClipSegment] = []
            for seg in p.effectiveSegments(sourceDuration: sourceDuration) {
                var pieces: [(Double, Double)] = [(seg.sourceStart, seg.sourceEnd)]
                for (a, b) in silent {
                    var next: [(Double, Double)] = []
                    for (x, y) in pieces {
                        if b <= x || a >= y { next.append((x, y)); continue }
                        cuts += 1
                        if a - x > 0.05 { next.append((x, a)) }
                        if y - b > 0.05 { next.append((b, y)) }
                    }
                    pieces = next
                }
                for (i, pc) in pieces.enumerated() {
                    var s = seg; s.sourceStart = pc.0; s.sourceEnd = pc.1
                    if i > 0 || pieces.count != 1 || pc != (seg.sourceStart, seg.sourceEnd) { s.id = UUID() }
                    out.append(s)
                }
            }
            if !out.isEmpty { p.segments = out }
        }
        return cuts
    }

    // MARK: Blur

    /// Maps normalized SOURCE coords to normalized OUTPUT-frame coords at output time `t` (identity-ish while preparing).
    func screenGeometry(at t: Double) -> (sx: Double, sy: Double, tx: Double, ty: Double) {
        if let c = previewCompositor { return c.screenToFrame(at: t) }
        let k = 1 - 2 * min(max(project.render.padding, 0), 0.3)
        return (k, k, (1 - k) / 2, (1 - k) / 2)
    }

    /// Normalized rect of a blur in OUTPUT-frame coordinates at time `t` (what the viewer sees).
    func blurFrameRect(_ b: BlurRegion, at t: Double) -> CGRect {
        guard b.anchor == .screen else { return CGRect(x: b.x, y: b.y, width: b.w, height: b.h) }
        let g = screenGeometry(at: t)
        return CGRect(x: g.sx * b.x + g.tx, y: g.sy * b.y + g.ty, width: g.sx * b.w, height: g.sy * b.h)
    }

    /// Inverse of `blurFrameRect`: store a frame-space rect in the blur's own anchor space.
    func blurRegion(_ b: BlurRegion, settingFrameRect r: CGRect, at t: Double) -> BlurRegion {
        var o = b
        if b.anchor == .screen {
            let g = screenGeometry(at: t)
            o.x = (Double(r.minX) - g.tx) / g.sx; o.y = (Double(r.minY) - g.ty) / g.sy
            o.w = Double(r.width) / g.sx; o.h = Double(r.height) / g.sy
        } else { o.x = Double(r.minX); o.y = Double(r.minY); o.w = Double(r.width); o.h = Double(r.height) }
        return o
    }

    func addBlur(frameRect: CGRect? = nil) {
        let len = min(3, outputDuration)
        let start = min(playhead, max(outputDuration - len, 0))
        var b = BlurRegion(start: start, end: start + len)
        let r = frameRect ?? CGRect(x: 0.3, y: 0.4, width: 0.4, height: 0.2)
        b = blurRegion(b, settingFrameRect: r, at: start + len / 2)
        edit { $0.blurs.append(b) }
        selection = .blur(b.id)
        inspectorTab = .effects
        seek(to: start + min(0.5, len / 2))
    }

    func blurBinding<T: Equatable>(_ id: UUID, _ kp: WritableKeyPath<BlurRegion, T>, fallback: T) -> Binding<T> {
        Binding(get: { self.project.blurs.first { $0.id == id }?[keyPath: kp] ?? fallback },
                set: { v in
                    self.edit(coalesce: "blur\(id)\(kp)") { p in
                        if let i = p.blurs.firstIndex(where: { $0.id == id }) { p.blurs[i][keyPath: kp] = v }
                    }
                })
    }

    func moveBlur(id: UUID, dt: Double) {
        updateGesture { p in
            guard let me = gestureBase?.blurs.first(where: { $0.id == id }) else { return }
            let len = me.end - me.start
            var s = me.start + dt
            let ex: Set<UUID> = [id]
            let sn = snap(s, excluding: ex), sn2 = snap(s + len, excluding: ex) - len
            s = abs(sn - s) <= abs(sn2 - s) ? sn : sn2
            s = min(max(s, 0), max(outputDuration - len, 0))
            if let i = p.blurs.firstIndex(where: { $0.id == id }) { p.blurs[i].start = s; p.blurs[i].end = s + len }
        }
    }

    func resizeBlur(id: UUID, leading: Bool, dt: Double) {
        updateGesture { p in
            guard let me = gestureBase?.blurs.first(where: { $0.id == id }) else { return }
            var s = me.start, e = me.end
            if leading { s = snap(me.start + dt, excluding: [id]); s = min(max(s, 0), e - 0.2) }
            else { e = snap(me.end + dt, excluding: [id]); e = max(min(e, outputDuration), s + 0.2) }
            if let i = p.blurs.firstIndex(where: { $0.id == id }) { p.blurs[i].start = s; p.blurs[i].end = e }
        }
    }

    func adoptAutoZooms(only id: UUID? = nil) {
        let list = visibleAutoZooms.filter { id == nil || $0.id == id }
        guard !list.isEmpty else { return }
        edit { p in
            for z in list { p.zoomRegions.append(z) }
            p.zoomRegions.sort { $0.start < $1.start }
        }
        selection = id.map { .zoom($0) }
    }

    func setWallpaper(_ url: URL) {
        edit { $0.style.backgroundKind = .image; $0.style.backgroundImagePath = url.path }
        inspectorTab = .video
    }

    // MARK: Audio clips

    private func loadAudioInfos() {
        let paths = Set(project.audioClips.map { $0.filePath }).filter { audioInfos[$0] == nil }
        for p in paths {
            Task { [weak self] in
                if let info = await RenderBridge.audioInfo(url: URL(fileURLWithPath: p)) {
                    self?.audioInfos[p] = AudioInfo(duration: info.duration, waveform: info.waveform)
                }
            }
        }
    }

    func clipFileDuration(_ c: AudioClip) -> Double { audioInfos[c.filePath]?.duration ?? (c.sourceEnd ?? 5) }

    func clipLength(_ c: AudioClip) -> Double {
        let base = max((c.sourceEnd ?? clipFileDuration(c)) - c.sourceStart, 0.05)
        if c.loopToFitVideo && c.isMusic { return max(outputDuration - c.outputStart, base) }
        return base
    }

    func addAudio(url: URL, isMusic: Bool, at: Double? = nil, name: String? = nil, select: Bool = true, loopFit: Bool = false) {
        Task { [weak self] in
            guard let self else { return }
            guard let info = await RenderBridge.audioInfo(url: url) else {
                self.onError?("Не удалось прочитать аудиофайл «\(url.lastPathComponent)».")
                return
            }
            self.audioInfos[url.path] = AudioInfo(duration: info.duration, waveform: info.waveform)
            var c = AudioClip(filePath: url.path)
            c.name = name ?? url.deletingPathExtension().lastPathComponent
            c.isMusic = isMusic
            c.outputStart = min(max(at ?? self.playhead, 0), self.outputDuration)
            if !isMusic { c.volume = 1 }
            if loopFit { c.loopToFitVideo = true; c.fadeIn = 1; c.fadeOut = 2; c.volume = 0.5 }
            self.edit { $0.audioClips.append(c) }
            if select { self.selection = .audio(c.id); self.inspectorTab = .audio }
        }
    }

    func splitSelectedAudio() {
        guard case .audio(let id) = selection, let c = project.audioClips.first(where: { $0.id == id }) else { return }
        let len = clipLength(c)
        let rel = playhead - c.outputStart
        guard rel > 0.05, rel < len - 0.05 else { return }
        var a = c, b = c
        b.id = UUID()
        let fileEnd = c.sourceEnd ?? clipFileDuration(c)
        a.sourceEnd = c.sourceStart + rel; a.loopToFitVideo = false; a.fadeOut = 0
        b.sourceStart = c.sourceStart + rel; b.sourceEnd = fileEnd; b.outputStart = playhead; b.loopToFitVideo = false; b.fadeIn = 0
        edit { p in
            guard let i = p.audioClips.firstIndex(where: { $0.id == id }) else { return }
            p.audioClips[i] = a; p.audioClips.insert(b, at: i + 1)
        }
    }

    func audioBinding<T: Equatable>(_ id: UUID, _ kp: WritableKeyPath<AudioClip, T>, fallback: T) -> Binding<T> {
        Binding(get: { self.project.audioClips.first { $0.id == id }?[keyPath: kp] ?? fallback },
                set: { v in
                    self.edit(coalesce: "aud\(id)\(kp)") { p in
                        if let i = p.audioClips.firstIndex(where: { $0.id == id }) { p.audioClips[i][keyPath: kp] = v }
                    }
                })
    }

    func moveAudio(id: UUID, dt: Double) {
        updateGesture { p in
            guard let base = gestureBase?.audioClips.first(where: { $0.id == id }),
                  let i = p.audioClips.firstIndex(where: { $0.id == id }) else { return }
            let len = clipLength(base)
            var s = base.outputStart + dt
            let a = snap(s, excluding: [id]), b = snap(s + len, excluding: [id]) - len
            s = abs(a - s) <= abs(b - s) ? a : b
            p.audioClips[i].outputStart = max(s, 0)
        }
    }

    func trimAudio(id: UUID, leading: Bool, dt: Double) {
        updateGesture { p in
            guard let base = gestureBase?.audioClips.first(where: { $0.id == id }),
                  let i = p.audioClips.firstIndex(where: { $0.id == id }) else { return }
            let fileEnd = base.sourceEnd ?? clipFileDuration(base)
            if leading {
                let d = min(max(dt, -base.sourceStart), (fileEnd - base.sourceStart) - 0.1)
                let d2 = max(d, -base.outputStart)
                p.audioClips[i].sourceStart = base.sourceStart + d2
                p.audioClips[i].outputStart = base.outputStart + d2
            } else {
                let e = min(max(fileEnd + dt, base.sourceStart + 0.1), clipFileDuration(base))
                p.audioClips[i].sourceEnd = e
            }
        }
    }

    /// Places a sound effect at every click (output time). Replaces earlier click sounds.
    func addClickSounds(url: URL) {
        let times = clickMarkers.sorted()
        guard !times.isEmpty else { return }
        Task { [weak self] in
            guard let self else { return }
            guard let info = await RenderBridge.audioInfo(url: url) else { return }
            self.audioInfos[url.path] = AudioInfo(duration: info.duration, waveform: info.waveform)
            var clips: [AudioClip] = []
            var last = -1.0
            for t in times where t - last >= 0.12 {
                var c = AudioClip(filePath: url.path)
                c.name = "Клик · " + url.deletingPathExtension().lastPathComponent
                c.isMusic = false; c.volume = 0.7; c.outputStart = t
                clips.append(c); last = t
            }
            self.edit { p in
                p.audioClips.removeAll { $0.name.hasPrefix("Клик · ") }
                p.audioClips.append(contentsOf: clips)
            }
        }
    }

    func removeClickSounds() { edit { $0.audioClips.removeAll { $0.name.hasPrefix("Клик · ") } } }

    // MARK: Camera keyframes

    func defaultBubble() -> CameraKeyframe {
        var k = CameraKeyframe(t: 0)
        k.shape = .circle
        k.w = 0.2; k.h = 0.2 * outputAspect
        k.x = 0.78; k.y = 1 - 0.04 - k.h
        return k
    }

    /// Value to start a new keyframe from: the previous keyframe (or the next, or a default bubble).
    private func baseKeyframe(at t: Double) -> CameraKeyframe {
        let ks = project.camera.keyframes
        if let p = ks.last(where: { $0.t <= t }) ?? ks.first { return p }
        return defaultBubble()
    }

    func addCameraKeyframe(at t: Double? = nil) {
        let time = min(max(t ?? playhead, 0), outputDuration)
        var k = baseKeyframe(at: time)
        k.id = UUID(); k.t = time
        edit { p in
            p.camera.keyframes.removeAll { abs($0.t - time) < 0.02 }
            p.camera.keyframes.append(k); p.camera.keyframes.sort { $0.t < $1.t }
        }
        selection = .camera(k.id)
    }

    /// Fullscreen keyframe at the playhead + bubble keyframe 0.8 s later.
    func collapseCameraToBubble() {
        let t0 = min(playhead, max(outputDuration - 0.9, 0))
        let t1 = min(t0 + 0.8, outputDuration)
        var full = baseKeyframe(at: t0)
        full.id = UUID(); full.t = t0
        full.x = 0; full.y = 0; full.w = 1; full.h = 1; full.shape = .rectangle; full.cornerRadius = 0; full.opacity = 1; full.borderWidth = 0
        let bubbleSrc = project.camera.keyframes.last(where: { $0.t > t0 && $0.shape != .rectangle }) ?? defaultBubble()
        var bub = bubbleSrc
        if bub.w >= 0.99 { bub = defaultBubble() }
        bub.id = UUID(); bub.t = t1
        edit { p in
            p.camera.enabled = true
            p.camera.keyframes.removeAll { abs($0.t - t0) < 0.02 || abs($0.t - t1) < 0.02 }
            p.camera.keyframes.append(full); p.camera.keyframes.append(bub)
            p.camera.keyframes.sort { $0.t < $1.t }
        }
        selection = .camera(bub.id)
    }

    func moveCameraKey(id: UUID, dt: Double) {
        updateGesture { p in
            guard let base = gestureBase?.camera.keyframes.first(where: { $0.id == id }),
                  let i = p.camera.keyframes.firstIndex(where: { $0.id == id }) else { return }
            var t = snap(base.t + dt, excluding: [id])
            t = min(max(t, 0), outputDuration)
            p.camera.keyframes[i].t = t
            p.camera.keyframes.sort { $0.t < $1.t }
        }
    }

    func cameraBinding<T: Equatable>(_ id: UUID, _ kp: WritableKeyPath<CameraKeyframe, T>, fallback: T) -> Binding<T> {
        Binding(get: { self.project.camera.keyframes.first { $0.id == id }?[keyPath: kp] ?? fallback },
                set: { v in
                    self.edit(coalesce: "cam\(id)\(kp)") { p in
                        if let i = p.camera.keyframes.firstIndex(where: { $0.id == id }) { p.camera.keyframes[i][keyPath: kp] = v }
                    }
                })
    }

    /// Auto suggestions that do not collide with manual regions.
    var visibleAutoZooms: [ZoomRegion] {
        guard project.render.autoZoom else { return [] }
        return autoZooms.filter { a in
            !project.zoomRegions.contains { $0.start < a.end && $0.end > a.start }
        }
    }

    private func freeSlot(start: Double, length: Double, existing: [(Double, Double)]) -> Double? {
        var s = min(max(start, 0), max(outputDuration - length, 0))
        for _ in 0..<50 {
            guard let hit = existing.first(where: { $0.0 < s + length && $0.1 > s }) else { return s }
            s = hit.1
            if s + length > outputDuration + 0.001 { break }
        }
        // No room at the playhead: use the free gap NEAREST to it (not the first one from the start).
        let sorted = existing.sorted { $0.0 < $1.0 }
        var gaps: [(Double, Double)] = []
        var cursor = 0.0
        for e in sorted {
            if e.0 - cursor >= length { gaps.append((cursor, e.0)) }
            cursor = max(cursor, e.1)
        }
        if outputDuration - cursor >= length { gaps.append((cursor, outputDuration)) }
        let ref = min(max(start, 0), outputDuration)
        let best = gaps.map { g in min(max(ref, g.0), g.1 - length) }.min { abs($0 - ref) < abs($1 - ref) }
        return best
    }

    func cursorFocus(atOutput t: Double) -> CGPoint? {
        let cur = session.meta.cursor
        guard !cur.isEmpty, session.meta.pointWidth > 0, session.meta.pointHeight > 0 else { return nil }
        let s = project.sourceTime(forOutput: t, sourceDuration: sourceDuration)
        var lo = 0, hi = cur.count - 1
        while lo < hi { let m = (lo + hi) / 2; if cur[m].t < s { lo = m + 1 } else { hi = m } }
        let c = cur[lo]
        return CGPoint(x: min(max(c.x / session.meta.pointWidth, 0), 1), y: min(max(c.y / session.meta.pointHeight, 0), 1))
    }

    // MARK: Window cut-outs

    var hasWindows: Bool { !session.meta.windows.isEmpty }

    func windowTrack(_ id: Int) -> WindowTrack? { session.meta.windows.first { $0.id == id } }

    /// Windows visible at an OUTPUT time (front to back, display points, top-left origin).
    func windows(atOutput t: Double) -> [(track: WindowTrack, rect: CGRect)] {
        let s = project.sourceTime(forOutput: t, sourceDuration: sourceDuration)
        return RenderBridge.windows(at: s, in: session.meta)
    }

    /// Output-time end of a window's life counted from `t` (ignores speed changes; clamps to the video end).
    private func windowLifeEnd(_ track: WindowTrack, fromOutput t: Double) -> Double {
        let s = project.sourceTime(forOutput: t, sourceDuration: sourceDuration)
        let life = RenderBridge.lifetime(of: track, meta: session.meta)
        return min(t + max(life.upperBound - s, 0), outputDuration)
    }

    func setPickingWindow(_ on: Bool) {
        guard on != pickingWindow, !(on && !hasWindows) else { return }
        if on { player.pause() }
        pickingWindow = on
        schedulePrepare(delay: 0)
    }

    /// Adds a cut-out of `track` at the playhead (default 4 s or until the window disappears).
    func addWindowCutout(track: WindowTrack, select: Bool = true) {
        let end = windowLifeEnd(track, fromOutput: playhead)
        let len = max(min(4, end - playhead, outputDuration), min(0.5, outputDuration))
        guard let start = freeSlot(start: min(playhead, max(outputDuration - len, 0)), length: len,
                                   existing: project.windowCutouts.map { ($0.start, $0.end) }) else { return }
        let w = WindowCutout(start: start, end: start + len, windowID: track.id)
        edit { $0.windowCutouts.append(w); $0.windowCutouts.sort { $0.start < $1.start } }
        if select { selection = .window(w.id); inspectorTab = .window }
        // Jump slightly inside so the (fading-in) cut-out is visible right away.
        if !pickingWindow { seek(to: start + min(0.5 + (w.transition), len / 2)) }
    }

    /// Cut-out for the topmost window at the playhead (double click on the lane / "+ Окно").
    func addWindowAtPlayhead() {
        let list = windows(atOutput: playhead)
        guard let top = list.first?.track else { return }
        addWindowCutout(track: top)
    }

    func windowBinding<T: Equatable>(_ id: UUID, _ kp: WritableKeyPath<WindowCutout, T>, fallback: T) -> Binding<T> {
        Binding(get: { self.project.windowCutouts.first { $0.id == id }?[keyPath: kp] ?? fallback },
                set: { v in
                    self.edit(coalesce: "win\(id)\(kp)") { p in
                        if let i = p.windowCutouts.firstIndex(where: { $0.id == id }) { p.windowCutouts[i][keyPath: kp] = v }
                    }
                })
    }

    /// All windows that exist at some moment of the cut-out (deduped, front-most first).
    func windowCandidates(for w: WindowCutout) -> [(track: WindowTrack, size: CGSize)] {
        let a = project.sourceTime(forOutput: w.start, sourceDuration: sourceDuration)
        let b = project.sourceTime(forOutput: max(w.end - 0.001, w.start), sourceDuration: sourceDuration)
        var out: [(WindowTrack, CGSize)] = []
        for tr in session.meta.windows {
            let life = RenderBridge.lifetime(of: tr, meta: session.meta)
            guard life.lowerBound <= max(a, b), life.upperBound >= min(a, b) else { continue }
            let t = min(max(a, life.lowerBound), life.upperBound)
            let r = RenderBridge.rect(of: tr, at: t)
            out.append((tr, r.size))
        }
        return out
    }

    func moveWindow(id: UUID, dt: Double) {
        updateGesture { p in
            guard let b = gestureBase, let me = b.windowCutouts.first(where: { $0.id == id }) else { return }
            let len = me.end - me.start
            var lo = 0.0, hi = outputDuration
            for o in b.windowCutouts where o.id != id {
                if o.end <= me.start + 0.0001 { lo = max(lo, o.end) }
                if o.start >= me.end - 0.0001 { hi = min(hi, o.start) }
            }
            var s = me.start + dt
            let sn = snap(s, excluding: [id]), sn2 = snap(s + len, excluding: [id]) - len
            s = abs(sn - s) <= abs(sn2 - s) ? sn : sn2
            s = min(max(s, lo), max(hi - len, lo))
            if let i = p.windowCutouts.firstIndex(where: { $0.id == id }) { p.windowCutouts[i].start = s; p.windowCutouts[i].end = s + len }
        }
    }

    func resizeWindow(id: UUID, leading: Bool, dt: Double) {
        updateGesture { p in
            guard let b = gestureBase, let me = b.windowCutouts.first(where: { $0.id == id }) else { return }
            var lo = 0.0, hi = outputDuration
            for o in b.windowCutouts where o.id != id {
                if o.end <= me.start + 0.0001 { lo = max(lo, o.end) }
                if o.start >= me.end - 0.0001 { hi = min(hi, o.start) }
            }
            var s = me.start, e = me.end
            if leading { s = snap(me.start + dt, excluding: [id]); s = min(max(s, lo), e - 0.3) }
            else { e = snap(me.end + dt, excluding: [id]); e = max(min(e, hi), s + 0.3) }
            if let i = p.windowCutouts.firstIndex(where: { $0.id == id }) { p.windowCutouts[i].start = s; p.windowCutouts[i].end = e }
        }
    }

    // MARK: Snapping

    func snapPoints(excluding: Set<UUID> = []) -> [Double] {
        var pts: [Double] = [0, outputDuration, playhead]
        for l in layout { pts.append(l.outStart); pts.append(l.outEnd) }
        for z in project.zoomRegions where !excluding.contains(z.id) { pts.append(z.start); pts.append(z.end) }
        for t in project.texts where !excluding.contains(t.id) { pts.append(t.start); pts.append(t.end) }
        for w in project.windowCutouts where !excluding.contains(w.id) { pts.append(w.start); pts.append(w.end) }
        for b in project.blurs where !excluding.contains(b.id) { pts.append(b.start); pts.append(b.end) }
        return pts
    }

    func snap(_ t: Double, excluding: Set<UUID> = []) -> Double {
        guard snapping else { return t }
        let thr = 7.0 / pps
        var best = t, bd = thr
        for p in snapPoints(excluding: excluding) where abs(p - t) < bd { bd = abs(p - t); best = p }
        return best
    }

    // MARK: Gesture helpers (called by the timeline)

    func moveItem(id: UUID, isZoom: Bool, dt: Double) {
        updateGesture { p in
            let items: [(Double, Double, UUID)] = isZoom
                ? (gestureBaseRegions(isZoom: true))
                : (gestureBaseRegions(isZoom: false))
            guard let me = items.first(where: { $0.2 == id }) else { return }
            let len = me.1 - me.0
            var lo = 0.0, hi = outputDuration
            if isZoom {
                for o in items where o.2 != id {
                    if o.1 <= me.0 + 0.0001 { lo = max(lo, o.1) }
                    if o.0 >= me.1 - 0.0001 { hi = min(hi, o.0) }
                }
            }
            var s = me.0 + dt
            let ex: Set<UUID> = [id]
            let sn = snap(s, excluding: ex)
            let sn2 = snap(s + len, excluding: ex) - len
            s = abs(sn - s) <= abs(sn2 - s) ? sn : sn2
            s = min(max(s, lo), max(hi - len, lo))
            if isZoom, let i = p.zoomRegions.firstIndex(where: { $0.id == id }) { p.zoomRegions[i].start = s; p.zoomRegions[i].end = s + len }
            if !isZoom, let i = p.texts.firstIndex(where: { $0.id == id }) { p.texts[i].start = s; p.texts[i].end = s + len }
        }
    }

    func resizeItem(id: UUID, isZoom: Bool, leading: Bool, dt: Double) {
        updateGesture { p in
            let items = gestureBaseRegions(isZoom: isZoom)
            guard let me = items.first(where: { $0.2 == id }) else { return }
            var lo = 0.0, hi = outputDuration
            if isZoom {
                for o in items where o.2 != id {
                    if o.1 <= me.0 + 0.0001 { lo = max(lo, o.1) }
                    if o.0 >= me.1 - 0.0001 { hi = min(hi, o.0) }
                }
            }
            var s = me.0, e = me.1
            if leading { s = snap(me.0 + dt, excluding: [id]); s = min(max(s, lo), e - 0.2) }
            else { e = snap(me.1 + dt, excluding: [id]); e = max(min(e, hi), s + 0.2) }
            if isZoom, let i = p.zoomRegions.firstIndex(where: { $0.id == id }) { p.zoomRegions[i].start = s; p.zoomRegions[i].end = e }
            if !isZoom, let i = p.texts.firstIndex(where: { $0.id == id }) { p.texts[i].start = s; p.texts[i].end = e }
        }
    }

    private func gestureBaseRegions(isZoom: Bool) -> [(Double, Double, UUID)] {
        guard let b = gestureBase else { return [] }
        return isZoom ? b.zoomRegions.map { ($0.start, $0.end, $0.id) } : b.texts.map { ($0.start, $0.end, $0.id) }
    }

    func trimSegment(id: UUID, leading: Bool, dt: Double) {
        updateGesture(remap: true) { p in
            guard let base = gestureBase, let bi = base.segments.firstIndex(where: { $0.id == id }),
                  let i = p.segments.firstIndex(where: { $0.id == id }) else { return }
            let s = base.segments[bi]
            let minSrc = 0.1 * s.speed
            // output start of this segment in the base
            var outStart = 0.0
            for x in base.segments[..<bi] { outStart += (x.sourceEnd - x.sourceStart) / max(x.speed, 0.01) }
            let outEnd = outStart + (s.sourceEnd - s.sourceStart) / s.speed
            if leading {
                let target = snapExcludingSelf(outStart + dt)
                let d = target - outStart
                p.segments[i].sourceStart = min(max(s.sourceStart + d * s.speed, 0), s.sourceEnd - minSrc)
            } else {
                let target = snapExcludingSelf(outEnd + dt)
                let d = target - outEnd
                p.segments[i].sourceEnd = max(min(s.sourceEnd + d * s.speed, sourceDuration), s.sourceStart + minSrc)
            }
        }
    }

    private func snapExcludingSelf(_ t: Double) -> Double {
        guard snapping else { return t }
        let thr = 7.0 / pps
        var best = t, bd = thr
        for p in [playhead] + (gestureBase?.zoomRegions.flatMap { [$0.start, $0.end] } ?? []) where abs(p - t) < bd { bd = abs(p - t); best = p }
        return best
    }

    // MARK: Playback

    func togglePlay() {
        if isPlaying { player.pause() } else {
            if playhead >= outputDuration - 0.03 { seek(to: 0) }
            player.play()
        }
    }

    func seek(to t: Double, precise: Bool = true) {
        let c = min(max(t, 0), outputDuration)
        playhead = c
        let time = CMTime(seconds: c, preferredTimescale: 600)
        if precise { player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero) }
        else {
            let tol = CMTime(seconds: 0.1, preferredTimescale: 600)
            player.seek(to: time, toleranceBefore: tol, toleranceAfter: tol)
        }
        ensurePlayheadVisible()
    }

    func step(frames: Int) { player.pause(); seek(to: playhead + Double(frames) * frameDuration) }
    func step(seconds: Double) { seek(to: playhead + seconds) }

    func playRate(_ r: Float) {
        if r < 0 && !(player.currentItem?.canPlayReverse ?? false) { step(seconds: -1); return }
        player.rate = r
    }

    func ensurePlayheadVisible() {
        let x = playhead * pps - scrollX
        if x < 20 || x > timelineWidth - 20 {
            scrollX = max(0, playhead * pps - timelineWidth * 0.3)
        }
    }

    func setZoom(_ newPPS: Double, anchorTime: Double? = nil) {
        let a = anchorTime ?? playhead
        let screenX = a * pps - scrollX
        pps = min(max(newPPS, 4), 1500)
        scrollX = max(0, a * pps - min(max(screenX, 0), timelineWidth))
        clampScroll()
    }

    func fitTimeline() {
        pps = max((timelineWidth - 24) / outputDuration, 4)
        scrollX = 0
    }

    func clampScroll() {
        let maxScroll = max(0, outputDuration * pps + 60 - timelineWidth)
        scrollX = min(max(scrollX, 0), maxScroll)
    }

    func timelineWidthChanged(_ w: Double) {
        timelineWidth = w
        if !didFitTimeline && w > 100 { didFitTimeline = true; fitTimeline() }
        clampScroll()
    }

    // MARK: Prepare

    func schedulePrepare(delay: TimeInterval = 0.25) {
        prepareTask?.cancel()
        generation += 1
        let gen = generation
        prepareTask = Task { [weak self] in
            if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
            guard !Task.isCancelled, let self, gen == self.generation else { return }
            await self.prepare(generation: gen)
        }
        scheduleAutoZoom()
    }

    private func prepare(generation gen: Int) async {
        isPreparing = true
        previewError = nil
        var proj = project
        if pickingWindow {
            // Pick mode: whole-screen preview, no zoom / cut-outs, so overlay coordinates are exact.
            proj.windowCutouts = []; proj.zoomRegions = []; proj.render.autoZoom = false
        }
        do {
            let prepared = try await RenderBridge.prepare(session: session, project: proj)
            guard !Task.isCancelled, gen == generation else { return }
            let time = playhead
            let wasPlaying = player.rate > 0
            let item = AVPlayerItem(asset: prepared.asset)
            item.videoComposition = prepared.videoComposition
            item.audioMix = prepared.audioMix
            player.replaceCurrentItem(with: item)
            observeEnd(of: item)
            renderSize = prepared.renderSize
            previewCompositor = prepared.frames
            if time > 0.01 {
                await player.seek(to: CMTime(seconds: min(time, outputDuration), preferredTimescale: 600),
                                  toleranceBefore: .zero, toleranceAfter: .zero)
            }
            if wasPlaying { player.play() }
            isPreparing = false
        } catch {
            guard gen == generation else { return }
            previewError = error.localizedDescription
            isPreparing = false
        }
    }

    private func observeEnd(of item: AVPlayerItem) {
        if let e = endObserver { NotificationCenter.default.removeObserver(e) }
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.loop {
                    self.player.seek(to: .zero) { _ in self.player.play() }
                } else {
                    self.playhead = self.outputDuration
                }
            }
        }
    }

    private func scheduleAutoZoom() {
        autoZoomTask?.cancel()
        let session = self.session
        var proj = project
        proj.render.autoZoom = true
        let p = proj
        autoZoomTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled else { return }
            let list = await Task.detached(priority: .utility) {
                RenderBridge.autoZoomSuggestions(session: session, project: p)
            }.value
            guard !Task.isCancelled else { return }
            self?.autoZooms = list
        }
    }

    private func loadThumbnails() {
        let session = self.session
        let count = max(24, min(80, Int(session.meta.duration / 1.5)))
        Task { [weak self] in
            let size = CGSize(width: 200, height: 120)
            let imgs = await RenderBridge.thumbnails(session: session, count: count, size: size)
            self?.thumbnails = imgs
        }
    }

    // MARK: Persistence

    private func scheduleSave() {
        saveWork?.cancel()
        let w = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.saveNow() }
        }
        saveWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: w)
    }

    func saveNow() {
        saveWork?.cancel()
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? FileManager.default.createDirectory(at: projectURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? enc.encode(project) { try? data.write(to: projectURL, options: .atomic) }
    }

    func resetLook() {
        edit {
            let keep = $0
            $0.render = RenderSettings()
            $0.style = EditStyle()
            $0.segments = keep.segments; $0.zoomRegions = keep.zoomRegions; $0.texts = keep.texts
        }
    }

    /// Resets only the settings of one inspector tab to their defaults (clips, texts, zoom regions and cut-out blocks are kept).
    func resetTab(_ tab: InspectorTab) {
        let d = RenderSettings()
        let ds = EditStyle()
        edit {
            switch tab {
            case .video:
                $0.style.aspect = ds.aspect; $0.style.backgroundKind = ds.backgroundKind
                $0.style.backgroundImagePath = ds.backgroundImagePath; $0.style.shadowIntensity = ds.shadowIntensity
                $0.render.padding = d.padding; $0.render.cornerRadius = d.cornerRadius; $0.render.shadow = d.shadow
                $0.render.backgroundTop = d.backgroundTop; $0.render.backgroundBottom = d.backgroundBottom
            case .camera:
                $0.camera = CameraSettings()
            case .audio:
                $0.originalVolume = 1.0
                $0.keyboard = KeyboardSoundSettings()
            case .cursor:
                $0.style.showCursor = ds.showCursor
                $0.render.cursorSmoothing = d.cursorSmoothing; $0.render.cursorScale = d.cursorScale
                $0.render.cursorStyle = d.cursorStyle; $0.render.customCursorPath = d.customCursorPath
                $0.render.customCursorHotspotX = d.customCursorHotspotX; $0.render.customCursorHotspotY = d.customCursorHotspotY
                $0.render.clickShrinkScale = d.clickShrinkScale; $0.render.clickAnimDuration = d.clickAnimDuration
                $0.render.showClickRipple = d.showClickRipple
            case .zoom:
                $0.render.autoZoom = d.autoZoom; $0.render.zoomScale = d.zoomScale; $0.render.zoomDuration = d.zoomDuration
                $0.render.zoomHold = d.zoomHold; $0.render.cameraSmoothing = d.cameraSmoothing
            case .text:
                let sel = selectedText?.id
                for i in $0.texts.indices where sel == nil || $0.texts[i].id == sel {
                    let t = TextOverlay(start: 0, end: 0, text: "")
                    $0.texts[i].x = t.x; $0.texts[i].y = t.y; $0.texts[i].fontSize = t.fontSize
                    $0.texts[i].colorHex = t.colorHex; $0.texts[i].hasBackground = t.hasBackground
                    $0.texts[i].typewriter = t.typewriter; $0.texts[i].typeSpeed = t.typeSpeed; $0.texts[i].typeSound = t.typeSound
                }
            case .effects:
                if let id = selectedBlur?.id, let i = $0.blurs.firstIndex(where: { $0.id == id }) {
                    let r = BlurRegion(start: 0, end: 0)
                    $0.blurs[i].kind = r.kind; $0.blurs[i].strength = r.strength; $0.blurs[i].cornerRadius = r.cornerRadius; $0.blurs[i].anchor = r.anchor
                } else {
                    let on = $0.mochi.enabled
                    $0.mochi = MochiOverlay(); $0.mochi.enabled = on
                }
            case .window:
                let sel = selectedWindowCutout?.id
                for i in $0.windowCutouts.indices where sel == nil || $0.windowCutouts[i].id == sel {
                    let c = WindowCutout(start: 0, end: 0, windowID: 0)
                    $0.windowCutouts[i].padding = c.padding; $0.windowCutouts[i].cornerRadius = c.cornerRadius
                    $0.windowCutouts[i].transition = c.transition; $0.windowCutouts[i].shadow = c.shadow
                }
            case .export:
                $0.exportFormat = EditProject().exportFormat
                $0.render.outputFPS = d.outputFPS; $0.render.outputHeight = d.outputHeight
            }
        }
    }

    // MARK: Export

    var fileExtension: String {
        switch project.exportFormat {
        case .mp4HEVC, .mp4H264: return "mp4"
        case .mov: return "mov"
        case .gif: return "gif"
        }
    }

    func chooseExportURLAndRun() {
        guard exportProgress == nil else { return }
        let panel = NSSavePanel()
        switch project.exportFormat {
        case .mp4HEVC, .mp4H264: panel.allowedContentTypes = [.mpeg4Movie]
        case .mov: panel.allowedContentTypes = [.quickTimeMovie]
        case .gif: panel.allowedContentTypes = [.gif]
        }
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = title + "." + fileExtension
        panel.directoryURL = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first
        panel.title = "Экспорт видео"
        panel.prompt = "Экспортировать"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        runExport(to: url)
    }

    func runExport(to url: URL) {
        player.pause()
        exportProgress = 0
        exportResultURL = nil
        exportError = nil
        let session = self.session
        let proj = project
        exportTask = Task { [weak self] in
            do {
                try? FileManager.default.removeItem(at: url)
                try await RenderBridge.export(session: session, project: proj, to: url) { p in
                    Task { @MainActor in self?.exportProgress = p }
                }
                if Task.isCancelled { try? FileManager.default.removeItem(at: url); self?.exportProgress = nil; return }
                self?.exportProgress = nil
                self?.exportResultURL = url
            } catch {
                self?.exportProgress = nil
                try? FileManager.default.removeItem(at: url)
                if !Task.isCancelled { self?.exportError = error.localizedDescription }
            }
        }
    }

    func cancelExport() {
        exportTask?.cancel()
        exportProgress = nil
    }
}

// MARK: - Formatting

func timecode(_ t: Double, fine: Bool = true) -> String {
    let t = max(0, t)
    let m = Int(t) / 60
    let s = Int(t) % 60
    let cs = Int((t - floor(t)) * 100)
    return fine ? String(format: "%d:%02d.%02d", m, s, cs) : String(format: "%d:%02d", m, s)
}
