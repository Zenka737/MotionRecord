import SwiftUI
import AVKit

struct EditorView: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        if let editor = app.editor {
            EditorContent(editor: editor).id(editor.id)
        } else {
            EditorEmptyState()
        }
    }
}

private struct EditorEmptyState: View {
    @EnvironmentObject var app: AppState
    var body: some View {
        VStack(spacing: 16) {
            ZStack {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(Theme.textDim.opacity(0.5), style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                    .frame(width: 440, height: 230)
                VStack(spacing: 10) {
                    Image(systemName: "film.stack").font(.system(size: 44)).foregroundColor(Theme.textDim)
                    Text("Перетащите видео сюда").font(.system(size: 18, weight: .semibold))
                    Text("mov, mp4, m4v — смонтируйте, добавьте зум, текст, фон и экспортируйте.")
                        .font(.system(size: 12.5)).foregroundColor(Theme.textDim).multilineTextAlignment(.center)
                        .frame(maxWidth: 340)
                }
            }
            HStack(spacing: 10) {
                Button { app.chooseVideoToOpen() } label: { Label("Открыть видео…", systemImage: "folder") }
                    .buttonStyle(PrimaryButtonStyle())
                Button("Библиотека") { app.tab = .library }.buttonStyle(SecondaryButtonStyle())
                Button("Начать запись") { app.tab = .record }.buttonStyle(SecondaryButtonStyle())
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Main editor

private struct EditorContent: View {
    @EnvironmentObject var app: AppState
    @ObservedObject var editor: EditorModel
    @State private var keyMonitor: Any?

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 0) {
                previewColumn
                Rectangle().fill(Theme.stroke).frame(width: 1)
                InspectorView(editor: editor).frame(width: 330)
            }
            .frame(maxHeight: .infinity)
            Rectangle().fill(Theme.stroke).frame(height: 1)
            TransportBar(editor: editor)
            Rectangle().fill(Theme.stroke).frame(height: 1)
            TimelineView(editor: editor)
        }
        .sheet(isPresented: $editor.showExportSheet) { ExportSheet(editor: editor) }
        .onAppear(perform: installKeys)
        .onDisappear { if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil } }
        .onChange(of: editor.selection) { _, sel in
            switch sel {
            case .segment?: editor.inspectorTab = .video
            case .zoom?, .autoZoom?: editor.inspectorTab = .zoom
            case .text?: editor.inspectorTab = .text
            case .window?: editor.inspectorTab = .window
            case .camera?: editor.inspectorTab = .camera
            case .audio?: editor.inspectorTab = .audio
            case .blur?: editor.inspectorTab = .effects
            case nil: break
            }
        }
    }

    // MARK: Preview

    private var previewColumn: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(editor.title).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                    Text("\(editor.session.meta.width)×\(editor.session.meta.height) · \(editor.session.meta.fps) fps · \(timecode(editor.outputDuration, fine: false))")
                        .font(.system(size: 11)).foregroundColor(Theme.textDim)
                }
                Spacer()
                if editor.isPreparing {
                    HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Обновление…").font(.system(size: 11.5)).foregroundColor(Theme.textDim) }
                        .transition(.opacity)
                }
                iconButton("arrow.uturn.backward", "Отменить (⌘Z)", enabled: editor.canUndo) { editor.undo() }
                iconButton("arrow.uturn.forward", "Повторить (⇧⌘Z)", enabled: editor.canRedo) { editor.redo() }
                Button { app.chooseVideoToOpen() } label: { Label("Открыть…", systemImage: "folder") }
                    .buttonStyle(SecondaryButtonStyle()).help("Открыть другое видео (⌘O)")
                Button { editor.showExportSheet = true } label: { Label("Экспорт", systemImage: "square.and.arrow.up") }
                    .buttonStyle(PrimaryButtonStyle()).help("Экспорт (⌘E)")
            }
            .animation(.easeOut(duration: 0.15), value: editor.isPreparing)

            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.black)
                PlayerView(player: editor.player)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .allowsHitTesting(false)
                PreviewOverlay(editor: editor)
                if let err = editor.previewError {
                    VStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle").font(.system(size: 26)).foregroundColor(.orange)
                        Text(err).font(.system(size: 12)).multilineTextAlignment(.center).foregroundColor(Theme.textDim)
                    }
                    .padding(20)
                    .background(RoundedRectangle(cornerRadius: 12).fill(.black.opacity(0.8)))
                }
            }
            .aspectRatio(aspect, contentMode: .fit)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.stroke, lineWidth: 1))
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func iconButton(_ name: String, _ help: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: name).font(.system(size: 13, weight: .medium))
                .frame(width: 30, height: 30)
                .background(Circle().fill(Color.white.opacity(0.08)))
                .opacity(enabled ? 1 : 0.35)
        }
        .buttonStyle(.plain).disabled(!enabled).help(help)
    }

    private var aspect: CGFloat {
        let s = editor.renderSize
        if s.width > 0, s.height > 0 { return s.width / s.height }
        let m = editor.session.meta
        return m.height > 0 ? CGFloat(m.width) / CGFloat(m.height) : 16.0 / 9.0
    }

    // MARK: Keyboard

    private func installKeys() {
        if let m = keyMonitor { NSEvent.removeMonitor(m) }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            MainActor.assumeIsolated {
                guard app.tab == .editor, app.editor === editor,
                      e.window === app.mainWindow, editor.showExportSheet == false else { return e }
                if let r = e.window?.firstResponder, r is NSTextView || r is NSTextField { return e }
                return handleKey(e) ? nil : e
            }
        }
    }

    private func handleKey(_ e: NSEvent) -> Bool {
        let cmd = e.modifierFlags.contains(.command)
        let shift = e.modifierFlags.contains(.shift)
        let ch = (e.charactersIgnoringModifiers ?? "").lowercased()
        if cmd {
            switch ch {
            case "z": shift ? editor.redo() : editor.undo(); return true
            case "d": editor.duplicateSelection(); return true
            case "e": editor.showExportSheet = true; return true
            default: return false
            }
        }
        if e.modifierFlags.contains(.option) || e.modifierFlags.contains(.control) { return false }
        switch e.keyCode {
        case 49: editor.togglePlay(); return true
        case 123: shift ? editor.step(seconds: -1) : editor.step(frames: -1); return true
        case 124: shift ? editor.step(seconds: 1) : editor.step(frames: 1); return true
        case 115: editor.seek(to: 0); return true
        case 119: editor.seek(to: editor.outputDuration); return true
        case 51, 117: editor.deleteSelection(); return true
        case 53:
            if editor.pickingWindow { editor.setPickingWindow(false) } else { editor.selection = nil }
            return true
        default: break
        }
        switch ch {
        case "s": editor.split(); return true
        case "b": editor.addBlur(); return true
        case "k": editor.player.pause(); return true
        case "l":
            let r = editor.player.rate
            editor.playRate(r > 0 ? min(r * 2, 8) : 1); return true
        case "j":
            let r = editor.player.rate
            editor.playRate(r < 0 ? max(r * 2, -8) : -1); return true
        case "=", "+": editor.setZoom(editor.pps * 1.35); return true
        case "-": editor.setZoom(editor.pps / 1.35); return true
        case "0": editor.fitTimeline(); return true
        default: return false
        }
    }
}

// MARK: - Preview overlay (focus crosshair, text dragging, click to play)

private struct PreviewOverlay: View {
    @ObservedObject var editor: EditorModel

    private func videoRect(_ W: CGFloat, _ H: CGFloat) -> CGRect {
        let m = editor.session.meta
        let sw = CGFloat(max(m.width, 1)), sh = CGFloat(max(m.height, 1))
        let k = 1 - 2 * min(max(CGFloat(editor.project.render.padding), 0), 0.3)
        var cw = W * k
        var ch = cw * sh / sw
        if ch > H * k { ch = H * k; cw = ch * sw / sh }
        return CGRect(x: (W - cw) / 2, y: (H - ch) / 2, width: cw, height: ch)
    }

    var body: some View {
        GeometryReader { geo in
            let W = geo.size.width, H = geo.size.height
            let vr = videoRect(W, H)
            ZStack(alignment: .topLeading) {
                Color.clear.contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                        handle(v.location, W, H, vr, ended: false)
                    }.onEnded { v in
                        handle(v.location, W, H, vr, ended: true)
                    })
                if editor.pickingWindow {
                    pickLayer(vr)
                } else if let k = editor.selectedCameraKey {
                    CameraBox(editor: editor, key: k, W: W, H: H)
                } else if let z = editor.selectedZoom {
                    let p = CGPoint(x: vr.minX + vr.width * z.focusX, y: vr.minY + vr.height * z.focusY)
                    let sz = CGSize(width: vr.width / z.scale, height: vr.height / z.scale)
                    Rectangle().strokeBorder(Color.white.opacity(0.9), style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
                        .frame(width: sz.width, height: sz.height)
                        .position(p).allowsHitTesting(false)
                    Crosshair().position(p).allowsHitTesting(false)
                } else if let b = editor.selectedBlur {
                    BlurBox(editor: editor, region: b, W: W, H: H)
                } else if editor.project.mochi.enabled && editor.inspectorTab == .effects && editor.selection == nil {
                    MochiHandle(editor: editor, W: W, H: H)
                } else if let t = editor.selectedText {
                    let fs = CGFloat(t.fontSize) * H / 1080
                    let w = max(CGFloat(t.text.count) * fs * 0.55 + 24, 40), h = fs * 1.5
                    RoundedRectangle(cornerRadius: 4).strokeBorder(Color.white.opacity(0.9), style: StrokeStyle(lineWidth: 1.5, dash: [5, 3]))
                        .frame(width: w, height: h)
                        .position(x: W * t.x, y: H * t.y).allowsHitTesting(false)
                }
                if editor.pickingWindow {
                    Text("Выбор окна: превью показывает весь экран — нажмите на окно")
                        .font(.system(size: 11)).padding(.horizontal, 8).padding(.vertical, 4)
                        .background(Capsule().fill(Color.black.opacity(0.6)))
                        .position(x: W / 2, y: 16).allowsHitTesting(false)
                } else if editor.selectedZoom != nil {
                    Text("Нажмите на кадр, чтобы выбрать фокус зума")
                        .font(.system(size: 11)).padding(.horizontal, 8).padding(.vertical, 4)
                        .background(Capsule().fill(Color.black.opacity(0.6)))
                        .position(x: W / 2, y: 16).allowsHitTesting(false)
                } else if editor.selectedText != nil {
                    Text("Перетащите текст на кадре")
                        .font(.system(size: 11)).padding(.horizontal, 8).padding(.vertical, 4)
                        .background(Capsule().fill(Color.black.opacity(0.6)))
                        .position(x: W / 2, y: 16).allowsHitTesting(false)
                }
            }
            .frame(width: W, height: H)
            .onContinuousHover { phase in
                if case .active(let p) = phase { hoverPoint = p } else { hoverPoint = nil }
            }
        }
    }

    @State private var downTime = Date.distantPast
    @State private var hoverPoint: CGPoint?

    private func windowAt(_ p: CGPoint, _ vr: CGRect) -> (track: WindowTrack, rect: CGRect)? {
        let m = editor.session.meta
        guard vr.width > 0, vr.contains(p) else { return nil }
        let dp = CGPoint(x: (p.x - vr.minX) / vr.width * CGFloat(m.pointWidth), y: (p.y - vr.minY) / vr.height * CGFloat(m.pointHeight))
        return editor.windows(atOutput: editor.playhead).first { $0.rect.contains(dp) }
    }

    @ViewBuilder private func pickLayer(_ vr: CGRect) -> some View {
        let m = editor.session.meta
        let kx = vr.width / CGFloat(max(m.pointWidth, 1)), ky = vr.height / CGFloat(max(m.pointHeight, 1))
        if let hp = hoverPoint, let hit = windowAt(hp, vr) {
            let r = CGRect(x: vr.minX + hit.rect.minX * kx, y: vr.minY + hit.rect.minY * ky,
                           width: hit.rect.width * kx, height: hit.rect.height * ky)
            let c = r.intersection(vr)
            Rectangle().fill(Color(hex: "#14B8A6").opacity(0.18))
                .overlay(Rectangle().strokeBorder(Color(hex: "#14B8A6"), lineWidth: 2.5))
                .frame(width: c.width, height: c.height).position(x: c.midX, y: c.midY).allowsHitTesting(false)
            Text(hit.track.title.isEmpty ? hit.track.app : "\(hit.track.app) · \(hit.track.title)")
                .font(.system(size: 11, weight: .semibold)).lineLimit(1).foregroundColor(.black)
                .padding(.horizontal, 7).padding(.vertical, 3)
                .background(Capsule().fill(Color(hex: "#14B8A6")))
                .position(x: min(max(c.minX + 70, 70), vr.maxX - 70), y: max(c.minY + 14, 14)).allowsHitTesting(false)
        }
    }

    private func handle(_ p: CGPoint, _ W: CGFloat, _ H: CGFloat, _ vr: CGRect, ended: Bool) {
        if editor.pickingWindow {
            hoverPoint = p
            if ended, let hit = windowAt(p, vr) {
                editor.setPickingWindow(false)
                editor.addWindowCutout(track: hit.track)
            }
            return
        }
        if let z = editor.selectedZoom {
            let fx = min(max(Double((p.x - vr.minX) / vr.width), 0), 1)
            let fy = min(max(Double((p.y - vr.minY) / vr.height), 0), 1)
            editor.edit(coalesce: "focus\(z.id)") { pr in
                if let i = pr.zoomRegions.firstIndex(where: { $0.id == z.id }) { pr.zoomRegions[i].focusX = fx; pr.zoomRegions[i].focusY = fy }
            }
        } else if let t = editor.selectedText {
            let x = min(max(Double(p.x / W), 0.02), 0.98), y = min(max(Double(p.y / H), 0.02), 0.98)
            editor.edit(coalesce: "textpos\(t.id)") { pr in
                if let i = pr.texts.firstIndex(where: { $0.id == t.id }) { pr.texts[i].x = x; pr.texts[i].y = y }
            }
        } else if editor.selectedCameraKey != nil || editor.selectedBlur != nil {
            return
        } else if editor.project.mochi.enabled && editor.inspectorTab == .effects && editor.selection == nil {
            return
        } else if ended {
            editor.togglePlay()
        }
    }
}

/// Draggable / resizable box for the selected camera keyframe.
private struct CameraBox: View {
    @ObservedObject var editor: EditorModel
    let key: CameraKeyframe
    let W: CGFloat, H: CGFloat
    @State private var base: CameraKeyframe?

    var body: some View {
        let r = CGRect(x: key.x * W, y: key.y * H, width: key.w * W, height: key.h * H)
        ZStack(alignment: .topLeading) {
            Rectangle().fill(Color.white.opacity(0.001))
                .frame(width: r.width, height: r.height)
                .overlay(Rectangle().strokeBorder(Theme.accent, style: StrokeStyle(lineWidth: 2, dash: [6, 3])))
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("pv")).onChanged { v in
                    if base == nil { base = key }
                    guard let b = base else { return }
                    let nx = min(max(b.x + Double(v.translation.width / W), 0), 1 - b.w)
                    let ny = min(max(b.y + Double(v.translation.height / H), 0), 1 - b.h)
                    apply { $0.x = nx; $0.y = ny }
                }.onEnded { _ in base = nil })
                .offset(x: r.minX, y: r.minY)
            ForEach(0..<4, id: \.self) { i in
                let right = i % 2 == 1, bottom = i >= 2
                Circle().fill(Color.white).overlay(Circle().strokeBorder(Theme.accent, lineWidth: 2))
                    .frame(width: 14, height: 14)
                    .padding(6).contentShape(Rectangle())
                    .position(x: right ? r.maxX : r.minX, y: bottom ? r.maxY : r.minY)
                    .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("pv")).onChanged { v in
                        if base == nil { base = key }
                        guard let b = base else { return }
                        let px = Double(v.location.x / W), py = Double(v.location.y / H)
                        var x0 = b.x, y0 = b.y, x1 = b.x + b.w, y1 = b.y + b.h
                        if right { x1 = min(max(px, x0 + 0.04), 1) } else { x0 = max(min(px, x1 - 0.04), 0) }
                        if bottom { y1 = min(max(py, y0 + 0.04), 1) } else { y0 = max(min(py, y1 - 0.04), 0) }
                        apply { $0.x = x0; $0.y = y0; $0.w = x1 - x0; $0.h = y1 - y0 }
                    }.onEnded { _ in base = nil })
            }
            Text("Перетащите рамку камеры или потяните за угол")
                .font(.system(size: 11)).padding(.horizontal, 8).padding(.vertical, 4)
                .background(Capsule().fill(Color.black.opacity(0.6)))
                .position(x: W / 2, y: 16).allowsHitTesting(false)
        }
        .frame(width: W, height: H, alignment: .topLeading)
        .coordinateSpace(name: "pv")
    }

    private func apply(_ f: @escaping (inout CameraKeyframe) -> Void) {
        let id = key.id
        editor.edit(coalesce: "camrect\(id)") { p in
            if let i = p.camera.keyframes.firstIndex(where: { $0.id == id }) { f(&p.camera.keyframes[i]) }
        }
    }
}

private struct Crosshair: View {
    var body: some View {
        ZStack {
            Circle().strokeBorder(Color.white, lineWidth: 2).frame(width: 22, height: 22)
            Circle().fill(Theme.accent).frame(width: 7, height: 7)
            Rectangle().fill(Color.white).frame(width: 1.5, height: 36)
            Rectangle().fill(Color.white).frame(width: 36, height: 1.5)
        }
        .shadow(color: .black.opacity(0.6), radius: 2)
    }
}

// MARK: - Transport + tools bar

private struct TransportBar: View {
    @ObservedObject var editor: EditorModel
    @State private var showSpeed = false

    var body: some View {
        HStack(spacing: 6) {
            Button { editor.seek(to: 0) } label: { Image(systemName: "backward.end.fill") }
                .buttonStyle(ToolButtonStyle()).help("В начало (Home)")
            Button { editor.togglePlay() } label: {
                Image(systemName: editor.isPlaying ? "pause.fill" : "play.fill").frame(width: 16)
            }
            .buttonStyle(ToolButtonStyle(prominent: true)).help("Пуск / пауза (Пробел)")
            Button { editor.loop.toggle() } label: { Image(systemName: "repeat") }
                .buttonStyle(ToolButtonStyle(active: editor.loop)).help("Зациклить воспроизведение")
            Text("\(timecode(editor.playhead)) / \(timecode(editor.outputDuration))")
                .font(.system(size: 12, weight: .medium, design: .rounded).monospacedDigit())
                .foregroundColor(Theme.textDim).frame(minWidth: 118, alignment: .leading).padding(.leading, 4)

            sep
            Button { editor.undo() } label: { Label("Отменить", systemImage: "arrow.uturn.backward") }
                .buttonStyle(ToolButtonStyle()).disabled(!editor.canUndo).help("Отменить последнее действие (⌘Z)")
            Button { editor.redo() } label: { Image(systemName: "arrow.uturn.forward") }
                .buttonStyle(ToolButtonStyle()).disabled(!editor.canRedo).help("Повторить (⇧⌘Z)")
            sep
            Button { editor.split() } label: { Label("Разрезать", systemImage: "scissors") }
                .buttonStyle(ToolButtonStyle()).help("Разрезать на позиции плейхеда (S)")
            Button { editor.deleteSelection() } label: { Image(systemName: "trash") }
                .buttonStyle(ToolButtonStyle()).disabled(editor.selection == nil).help("Удалить выбранное (⌫)")
            Button { editor.duplicateSelection() } label: { Image(systemName: "plus.square.on.square") }
                .buttonStyle(ToolButtonStyle()).disabled(editor.selection == nil).help("Дублировать (⌘D)")
            Button { showSpeed.toggle() } label: {
                Label(editor.selectedSegment.map { speedLabel($0.speed) } ?? "Скорость", systemImage: "speedometer")
            }
            .buttonStyle(ToolButtonStyle(active: (editor.selectedSegment?.speed ?? 1) != 1))
            .disabled(editor.selectedSegment == nil).help("Скорость выбранного фрагмента")
            .popover(isPresented: $showSpeed) { SpeedControl(editor: editor).padding(14).frame(width: 300) }
            Button {
                if let s = editor.selectedSegment { editor.toggleMute(s.id) }
            } label: { Image(systemName: editor.selectedSegment?.isMuted == true ? "speaker.slash.fill" : "speaker.wave.2.fill") }
                .buttonStyle(ToolButtonStyle(active: editor.selectedSegment?.isMuted == true))
                .disabled(editor.selectedSegment == nil).help("Выключить звук фрагмента")

            sep
            Button { editor.addZoom() } label: { Label("Зум", systemImage: "plus") }
                .buttonStyle(ToolButtonStyle()).help("Добавить зум на позиции плейхеда")
            Button { editor.addText() } label: { Label("Текст", systemImage: "plus") }
                .buttonStyle(ToolButtonStyle()).help("Добавить текст на позиции плейхеда")
            Button { editor.addBlur() } label: { Label("Блюр", systemImage: "drop.halffull") }
                .buttonStyle(ToolButtonStyle()).help("Скрыть часть кадра: размытие / пиксели / плашка (B)")
            Button { editor.edit { $0.mochi.enabled.toggle() }; editor.inspectorTab = .effects } label: { Label("Моти", systemImage: "face.smiling") }
                .buttonStyle(ToolButtonStyle(active: editor.project.mochi.enabled)).help("Моти внизу кадра: подпрыгивает, когда звучит голос")
            if editor.hasWindows {
                Button { editor.addWindowAtPlayhead() } label: { Label("Окно", systemImage: "plus") }
                    .buttonStyle(ToolButtonStyle()).help("Показать только верхнее окно на позиции плейхеда")
                Button { editor.setPickingWindow(!editor.pickingWindow) } label: { Label("Выбрать окно", systemImage: "macwindow.badge.plus") }
                    .buttonStyle(ToolButtonStyle(active: editor.pickingWindow)).help("Выбрать окно кликом по превью (Esc — выйти)")
            }
            if !editor.visibleAutoZooms.isEmpty {
                Button { editor.adoptAutoZooms() } label: { Label("Сделать ручными", systemImage: "wand.and.stars") }
                    .buttonStyle(ToolButtonStyle()).help("Превратить предложенные автозумы в редактируемые")
            }
            Spacer(minLength: 4)
            Button { editor.snapping.toggle() } label: { Image(systemName: "magnet") }
                .buttonStyle(ToolButtonStyle(active: editor.snapping)).help("Прилипание к границам")
            Image(systemName: "minus.magnifyingglass").font(.system(size: 11)).foregroundColor(Theme.textDim)
            Slider(value: Binding(get: { log2(editor.pps) }, set: { editor.setZoom(pow(2, $0)) }), in: 2...10)
                .controlSize(.mini).frame(width: 90).tint(Theme.accent)
            Image(systemName: "plus.magnifyingglass").font(.system(size: 11)).foregroundColor(Theme.textDim)
            Button { editor.fitTimeline() } label: { Text("Уместить") }
                .buttonStyle(ToolButtonStyle()).help("Показать всё видео (0)")
        }
        .padding(.horizontal, 12)
        .frame(height: 44)
        .background(Color.black.opacity(0.18))
    }

    private var sep: some View {
        Rectangle().fill(Theme.stroke).frame(width: 1, height: 20).padding(.horizontal, 4)
    }
}

struct ToolButtonStyle: ButtonStyle {
    var active = false
    var prominent = false
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .foregroundColor(prominent ? .white : .white)
            .padding(.horizontal, 9).frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(prominent ? AnyShapeStyle(Theme.accentGradient)
                      : AnyShapeStyle(active ? Theme.accent.opacity(0.55) : Color.white.opacity(configuration.isPressed ? 0.18 : 0.07))))
            .opacity(enabled ? 1 : 0.35)
    }
}

struct SpeedControl: View {
    @ObservedObject var editor: EditorModel
    private let presets: [Double] = [0.25, 0.5, 0.75, 1, 1.5, 2, 3, 4, 6, 8]

    var body: some View {
        if let seg = editor.selectedSegment {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Скорость фрагмента").font(.system(size: 12.5, weight: .semibold))
                    Spacer()
                    Text(speedLabel(seg.speed)).font(.system(size: 12, weight: .semibold, design: .rounded)).foregroundColor(Theme.accent)
                }
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 5), spacing: 6) {
                    ForEach(presets, id: \.self) { p in
                        Chip(label: speedLabel(p), selected: abs(seg.speed - p) < 0.001) { editor.setSpeed(p, for: seg.id) }
                    }
                }
                Slider(value: Binding(get: { log2(seg.speed) }, set: { editor.setSpeed(pow(2, $0), for: seg.id) }), in: -2...3)
                    .tint(Theme.accent)
                Text("Длительность: \(timecode((seg.sourceEnd - seg.sourceStart) / seg.speed))  ·  исходник: \(timecode(seg.sourceEnd - seg.sourceStart))")
                    .font(.system(size: 11)).foregroundColor(Theme.textDim)
            }
        } else {
            Text("Выберите фрагмент на таймлайне").font(.system(size: 12)).foregroundColor(Theme.textDim)
        }
    }
}

struct Chip: View {
    let label: String
    let selected: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(label).font(.system(size: 11.5, weight: .medium))
                .frame(maxWidth: .infinity).padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(selected ? Theme.accent.opacity(0.85) : Color.white.opacity(0.07)))
                .foregroundColor(.white)
        }
        .buttonStyle(.plain)
    }
}

struct SliderRow: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var format: String = "%.2f"

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.system(size: 12.5))
                Spacer()
                Text(String(format: format, value))
                    .font(.system(size: 11.5, weight: .medium, design: .rounded).monospacedDigit())
                    .foregroundColor(Theme.textDim)
            }
            Slider(value: $value, in: range).tint(Theme.accent).controlSize(.small)
        }
    }
}

func formatDuration(_ t: Double) -> String {
    let s = Int(max(0, t.rounded()))
    return String(format: "%d:%02d", s / 60, s % 60)
}
