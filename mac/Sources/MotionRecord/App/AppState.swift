import SwiftUI
import AppKit
import AVFoundation
import Combine
import UniformTypeIdentifiers

// MARK: - Persistence

private enum Persist {
    static func load<T: Codable>(_ type: T.Type, key: String, defaults: T) -> T? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return LenientDecode.decode(T.self, from: data, defaults: defaults)
    }
    static func save<T: Encodable>(_ value: T, key: String) {
        if let data = try? JSONEncoder().encode(value) { UserDefaults.standard.set(data, forKey: key) }
    }
}

struct LibraryItem: Identifiable, Hashable {
    var id: URL { url }
    var url: URL
    var name: String
    var startedAt: Date
    var duration: Double
    var width: Int
    var height: Int
    var fps: Int
    var bytes: Int64
}

enum AppTab: String, CaseIterable, Identifiable {
    case record, editor, library
    var id: String { rawValue }
    var title: String {
        switch self {
        case .record: return "Запись"
        case .editor: return "Редактор"
        case .library: return "Библиотека"
        }
    }
    var icon: String {
        switch self {
        case .record: return "record.circle"
        case .editor: return "slider.horizontal.3"
        case .library: return "square.grid.2x2"
        }
    }
}

enum Phase: Equatable {
    case idle
    case countdown(Int)
    case starting
    case recording
    case stopping
}

// MARK: - AppState

@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    // Settings (persisted)
    @Published var recordingSettings: RecordingSettings {
        didSet { Persist.save(recordingSettings, key: "recordingSettings") }
    }
    @Published var renderSettings: RenderSettings {
        didSet {
            Persist.save(renderSettings, key: "renderSettings")
        }
    }
    @Published var countdownEnabled: Bool {
        didSet { UserDefaults.standard.set(countdownEnabled, forKey: "countdownEnabled") }
    }

    // Runtime state
    @Published var phase: Phase = .idle
    @Published var tab: AppTab = .record
    @Published var displays: [DisplayInfo] = []
    @Published var hasPermission = true
    @Published var editor: EditorModel?
    @Published var library: [LibraryItem] = []
    @Published var errorMessage: String?

    let engine = RecordingEngine()
    /// Live microphone loudness (0...1) while recording with the mic on.
    @Published var micLevel: Float = 0
    let notch = NotchIndicator()
    private let countdown = CountdownOverlay()
    private let hotKey = GlobalHotKey()
    private var cancellables = Set<AnyCancellable>()
    private var startTask: Task<Void, Never>?

    weak var mainWindow: NSWindow?
    var openMainWindow: (() -> Void)?

    var isBusy: Bool { phase != .idle }
    var isRecording: Bool { phase == .recording }

    private init() {
        recordingSettings = Persist.load(RecordingSettings.self, key: "recordingSettings", defaults: RecordingSettings()) ?? RecordingSettings()
        renderSettings = Persist.load(RenderSettings.self, key: "renderSettings", defaults: RenderSettings()) ?? RenderSettings()
        countdownEnabled = UserDefaults.standard.object(forKey: "countdownEnabled") as? Bool ?? true

        notch.onStop = { [weak self] in self?.stopRecording() }
        engine.$elapsed
            .receive(on: DispatchQueue.main)
            .sink { [weak self] value in
                MainActor.assumeIsolated { self?.notch.update(elapsed: value) }
            }
            .store(in: &cancellables)
        engine.$micLevel
            .receive(on: DispatchQueue.main)
            .sink { [weak self] v in MainActor.assumeIsolated { self?.micLevel = v } }
            .store(in: &cancellables)
    }

    /// Called once from the app delegate after launch. Never touches VideoRenderer.
    func bootstrap() {
        hotKey.register { [weak self] in
            Task { @MainActor in self?.toggleRecording() }
        }
        refreshPermission()
        refreshDisplays()
        refreshLibrary()
        NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshPermission() }
            }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshDisplays() }
            }
            .store(in: &cancellables)
    }

    // MARK: Permission / displays

    func refreshPermission() {
        hasPermission = RecordingEngine.hasPermission()
    }

    func requestPermission() {
        RecordingEngine.requestPermission()
        openScreenRecordingSettings()
        // The user flips the switch in System Settings; re-check when we become active again.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.refreshPermission() }
    }

    func openScreenRecordingSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    func refreshDisplays() {
        Task {
            let list = await RecordingEngine.availableDisplays()
            self.displays = list
        }
    }

    // MARK: Recording flow

    func toggleRecording() {
        switch phase {
        case .idle: startRecording()
        case .countdown, .starting:
            cancelStart()
        case .recording: stopRecording()
        case .stopping: break
        }
    }

    private func cancelStart() {
        startTask?.cancel()
    }

    func startRecording() {
        guard phase == .idle else { return }
        refreshPermission()
        guard hasPermission else {
            showMainWindow()
            tab = .record
            errorMessage = "Нет разрешения на запись экрана. Выдайте доступ в Системные настройки → Конфиденциальность и безопасность → Запись экрана, затем перезапустите приложение."
            return
        }
        phase = .starting
        let settings = recordingSettings
        let useCountdown = countdownEnabled
        startTask = Task { [weak self] in
            guard let self else { return }
            self.hideMainWindow()
            var cancelled = false
            if useCountdown {
                let screen = self.screen(for: settings.displayID)
                for n in [3, 2, 1] {
                    self.phase = .countdown(n)
                    self.countdown.show(number: n, on: screen)
                    do { try await Task.sleep(nanoseconds: 1_000_000_000) } catch { cancelled = true; break }
                }
                self.countdown.hide()
            }
            if !cancelled {
                self.phase = .starting
                // Let the window/overlay disappear before the first captured frame.
                do { try await Task.sleep(nanoseconds: 350_000_000) } catch { cancelled = true }
            }
            if cancelled || Task.isCancelled {
                self.countdown.hide()
                self.phase = .idle
                self.showMainWindow()
                return
            }
            do {
                try await self.engine.start(settings: settings)
                self.phase = .recording
                if settings.showNotchIndicator { self.notch.show() }
            } catch {
                self.countdown.hide()
                self.phase = .idle
                self.showMainWindow()
                self.errorMessage = "Не удалось начать запись: \(error.localizedDescription)"
            }
        }
    }

    func stopRecording() {
        guard phase == .recording else { return }
        phase = .stopping
        notch.hide()
        Task { [weak self] in
            guard let self else { return }
            do {
                let session = try await self.engine.stop()
                self.phase = .idle
                self.refreshLibrary()
                self.openEditor(session)
                self.showMainWindow()
            } catch {
                self.phase = .idle
                self.showMainWindow()
                self.errorMessage = "Не удалось остановить запись: \(error.localizedDescription)"
            }
        }
    }

    /// Used on quit: stops an active recording so raw.mov gets finalized.
    func finishForTermination() async {
        if phase == .recording {
            notch.hide()
            _ = try? await engine.stop()
        }
    }

    private func screen(for displayID: UInt32) -> NSScreen {
        let target = displayID == 0 ? CGMainDisplayID() : displayID
        for s in NSScreen.screens {
            if let n = s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber, n.uint32Value == target {
                return s
            }
        }
        return NSScreen.main ?? NSScreen.screens[0]
    }

    // MARK: Windows

    func showMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        if let w = mainWindow {
            if w.isMiniaturized { w.deminiaturize(nil) }
            w.makeKeyAndOrderFront(nil)
        } else {
            openMainWindow?()
        }
    }

    func hideMainWindow() {
        mainWindow?.orderOut(nil)
    }

    // MARK: Editor

    /// Remembers the latest look so that new projects start from it.
    func rememberRenderSettings(_ r: RenderSettings) {
        if r != renderSettings { renderSettings = r }
    }

    func openEditor(_ session: RecordingSession, imported: Bool = false) {
        editor?.stop()
        let projectURL: URL
        if imported {
            projectURL = Self.importedProjectURL(for: session.videoURL)
        } else {
            projectURL = session.directory.appendingPathComponent("project.json")
        }
        let model = EditorModel(session: session, projectURL: projectURL, isImported: imported, defaultRender: renderSettings)
        model.onError = { [weak self] msg in self?.errorMessage = msg }
        editor = model
        tab = .editor
        model.schedulePrepare(delay: 0)
    }

    /// ~/Movies/MotionRecord/Imported/<name>-<hash>/project.json
    static func importedProjectURL(for video: URL) -> URL {
        var h: UInt64 = 1469598103934665603
        for b in video.standardizedFileURL.path.utf8 { h = (h ^ UInt64(b)) &* 1099511628211 }
        let name = video.deletingPathExtension().lastPathComponent
        return RecordingSession.libraryURL
            .appendingPathComponent("Imported", isDirectory: true)
            .appendingPathComponent("\(name)-\(String(h, radix: 16).prefix(6))", isDirectory: true)
            .appendingPathComponent("project.json")
    }

    func openLibraryItem(_ item: LibraryItem) {
        Task {
            do {
                let url = item.url
                let session = try await Task.detached { try RecordingSession.load(from: url) }.value
                self.openEditor(session)
            } catch {
                self.errorMessage = "Не удалось открыть запись: \(error.localizedDescription)"
            }
        }
    }

    /// Files dropped onto the window: video -> open, audio -> add to timeline, image -> background.
    func handleDroppedFile(_ url: URL) {
        let ext = url.pathExtension.lowercased()
        if ["mov", "mp4", "m4v"].contains(ext) { openVideo(url); return }
        guard let ed = editor else { errorMessage = "Сначала откройте видео."; return }
        if ["mp3", "m4a", "wav", "aiff", "aif", "caf", "aac"].contains(ext) {
            tab = .editor
            ed.addAudio(url: url, isMusic: true)
        } else if ["png", "jpg", "jpeg", "heic", "tiff", "gif", "bmp"].contains(ext) {
            tab = .editor
            ed.setWallpaper(url)
        } else {
            errorMessage = "Неподдерживаемый тип файла: .\(ext)"
        }
    }

    /// NSOpenPanel -> openVideo
    func chooseVideoToOpen() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie, .mpeg4Movie, .quickTimeMovie]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.title = "Открыть видео"
        panel.prompt = "Открыть"
        if panel.runModal() == .OK, let url = panel.url { openVideo(url) }
    }

    /// Opens any video file (mov/mp4/m4v) in the editor.
    func openVideo(_ url: URL) {
        let ext = url.pathExtension.lowercased()
        guard ["mov", "mp4", "m4v"].contains(ext) else {
            errorMessage = "Поддерживаются только видео mov, mp4 и m4v."
            return
        }
        // A raw.mov inside a recording folder: open it as a full recording (with cursor data).
        let dir = url.deletingLastPathComponent()
        if url.lastPathComponent == "raw.mov", let s = try? RecordingSession.load(from: dir) {
            openEditor(s); return
        }
        Task {
            do {
                let asset = AVURLAsset(url: url)
                guard let track = try await asset.loadTracks(withMediaType: .video).first else {
                    self.errorMessage = "В файле нет видеодорожки."
                    return
                }
                let natural = try await track.load(.naturalSize)
                let tf = try await track.load(.preferredTransform)
                let size = natural.applying(tf)
                var fps = Int(((try? await track.load(.nominalFrameRate)) ?? 30).rounded())
                if fps <= 0 { fps = 30 }
                let dur = try await asset.load(.duration).seconds
                guard dur.isFinite, dur > 0 else { self.errorMessage = "Не удалось определить длительность видео."; return }
                let session = RecordingSession.imported(videoURL: url, width: Int(abs(size.width)), height: Int(abs(size.height)),
                                                        fps: fps, duration: dur)
                self.openEditor(session, imported: true)
            } catch {
                self.errorMessage = "Не удалось открыть видео: \(error.localizedDescription)"
            }
        }
    }

    func closeEditor() {
        editor?.stop()
        editor = nil
        tab = .record
    }

    // MARK: Library

    func refreshLibrary() {
        Task {
            let items = await Task.detached(priority: .utility) { Self.scanLibrary() }.value
            self.library = items
        }
    }

    nonisolated private static func scanLibrary() -> [LibraryItem] {
        let fm = FileManager.default
        let root = RecordingSession.libraryURL
        guard let dirs = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey],
                                                     options: [.skipsHiddenFiles]) else { return [] }
        var out: [LibraryItem] = []
        for dir in dirs {
            guard (try? dir.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true,
                  fm.fileExists(atPath: dir.appendingPathComponent("meta.json").path),
                  let session = try? RecordingSession.load(from: dir) else { continue }
            let size = (try? fm.attributesOfItem(atPath: session.videoURL.path)[.size] as? NSNumber)??.int64Value ?? 0
            out.append(LibraryItem(url: dir, name: dir.lastPathComponent, startedAt: session.meta.startedAt,
                                   duration: session.meta.duration, width: session.meta.width,
                                   height: session.meta.height, fps: session.meta.fps, bytes: size))
        }
        return out.sorted { $0.startedAt > $1.startedAt }
    }

    func deleteLibraryItem(_ item: LibraryItem) {
        do {
            try FileManager.default.trashItem(at: item.url, resultingItemURL: nil)
            if editor?.session.directory == item.url { closeEditor() }
            library.removeAll { $0.id == item.id }
        } catch {
            errorMessage = "Не удалось удалить: \(error.localizedDescription)"
        }
    }

    // MARK: Demo

    /// `--demo-notch`: shows the notch indicator for 5 seconds, then quits.
    func runNotchDemo() {
        notch.show()
        Task {
            for i in 0..<10 {
                try? await Task.sleep(nanoseconds: 500_000_000)
                self.notch.update(elapsed: Double(i + 1) * 0.5 + 11.5)
            }
            self.notch.hide()
            try? await Task.sleep(nanoseconds: 800_000_000)
            NSApp.terminate(nil)
        }
    }
}
