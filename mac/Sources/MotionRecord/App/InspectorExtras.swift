import SwiftUI
import AppKit
import AVFoundation
import ImageIO
import UniformTypeIdentifiers

private func toggleRow(_ title: String, _ b: Binding<Bool>) -> some View {
    Toggle(title, isOn: b).toggleStyle(.switch).tint(Theme.accent).font(.system(size: 12.5))
}

// MARK: - Cursor tab

struct CursorStyleOption: Identifiable {
    var id: String
    var title: String
}

private let cursorStyles: [CursorStyleOption] = [
    .init(id: "macArrow", title: "macOS"), .init(id: "classic", title: "Стрелка"), .init(id: "dot", title: "Точка"),
    .init(id: "ring", title: "Кольцо"), .init(id: "custom", title: "Свой"),
]

/// Small drawing of a cursor style (independent of the renderer).
struct CursorGlyph: View {
    let style: String
    var customPath: String?
    var size: CGFloat = 30

    var body: some View {
        ZStack {
            switch style {
            case "dot": Circle().fill(Color.white).frame(width: size * 0.4, height: size * 0.4).overlay(Circle().strokeBorder(Color.black.opacity(0.4)))
            case "ring": Circle().strokeBorder(Color.white, lineWidth: size * 0.1).frame(width: size * 0.6, height: size * 0.6)
            case "classic": Arrow().fill(Color.white).overlay(Arrow().stroke(Color.black, lineWidth: 1.5)).frame(width: size * 0.6, height: size * 0.9)
            case "custom":
                if let p = customPath, let img = NSImage(contentsOfFile: p) {
                    Image(nsImage: img).resizable().aspectRatio(contentMode: .fit).frame(width: size, height: size)
                } else { Image(systemName: "plus.circle").font(.system(size: size * 0.6)).foregroundColor(Theme.textDim) }
            default:
                Image(nsImage: NSCursor.arrow.image).resizable().aspectRatio(contentMode: .fit).frame(width: size * 0.8, height: size * 0.9)
            }
        }
        .frame(width: size, height: size)
    }

    struct Arrow: Shape {
        func path(in r: CGRect) -> Path {
            var p = Path()
            let w = r.width, h = r.height
            p.move(to: CGPoint(x: 0, y: 0))
            p.addLine(to: CGPoint(x: 0, y: h * 0.85))
            p.addLine(to: CGPoint(x: w * 0.3, y: h * 0.65))
            p.addLine(to: CGPoint(x: w * 0.55, y: h))
            p.addLine(to: CGPoint(x: w * 0.72, y: h * 0.92))
            p.addLine(to: CGPoint(x: w * 0.48, y: h * 0.58))
            p.addLine(to: CGPoint(x: w, y: h * 0.55))
            p.closeSubpath()
            return p
        }
    }
}

struct CursorTab: View {
    @ObservedObject var editor: EditorModel
    @State private var demoScale: CGFloat = 1
    @State private var rippleOn = false

    private var r: RenderSettings { editor.project.render }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionTitle("Курсор")
            if !editor.hasCursorData {
                Label("В этом видео нет данных о курсоре — настройки применяются только к записям MotionRecord.", systemImage: "info.circle")
                    .font(.system(size: 11.5)).foregroundColor(Theme.textDim)
            }
            toggleRow("Показывать курсор", editor.binding(\.style.showCursor))
            Group {
                Text("Вид").font(.system(size: 12.5))
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 5), spacing: 6) {
                    ForEach(cursorStyles) { st in
                        Button {
                            if st.id == "custom" && r.customCursorPath == nil { chooseCustom() }
                            else { editor.edit { $0.render.cursorStyle = st.id } }
                        } label: {
                            VStack(spacing: 2) {
                                ZStack { Color.black.opacity(0.45); CursorGlyph(style: st.id, customPath: r.customCursorPath, size: 30) }
                                    .frame(height: 38).clipShape(RoundedRectangle(cornerRadius: 7))
                                Text(st.title).font(.system(size: 9.5))
                            }
                            .padding(3)
                            .background(RoundedRectangle(cornerRadius: 9).fill(r.cursorStyle == st.id ? Theme.accent.opacity(0.6) : Color.white.opacity(0.05)))
                        }.buttonStyle(.plain)
                    }
                }
                Button { chooseCustom() } label: { Label("Свой курсор…", systemImage: "photo") }.buttonStyle(SecondaryButtonStyle())
                if r.cursorStyle == "custom", let p = r.customCursorPath, let img = NSImage(contentsOfFile: p) {
                    hotspotPicker(img)
                }
                SliderRow(title: "Размер", value: editor.binding(\.render.cursorScale), range: 0.6...4, format: "%.1f×")
                SliderRow(title: "Сглаживание", value: editor.binding(\.render.cursorSmoothing), range: 0...1, format: "%.2f")
            }
            .disabled(!editor.project.style.showCursor).opacity(editor.project.style.showCursor ? 1 : 0.4)
        }.card()
        VStack(alignment: .leading, spacing: 12) {
            SectionTitle("Анимация клика")
            SliderRow(title: "Сжатие курсора", value: editor.binding(\.render.clickShrinkScale), range: 0.5...1, format: "%.2f")
            SliderRow(title: "Длительность", value: editor.binding(\.render.clickAnimDuration), range: 0.05...0.4, format: "%.2f с")
            toggleRow("Волна при клике", editor.binding(\.render.showClickRipple))
            HStack {
                ZStack {
                    Color.black.opacity(0.45)
                    if rippleOn && r.showClickRipple {
                        Circle().strokeBorder(Color.white.opacity(0.7), lineWidth: 2).frame(width: 44, height: 44)
                            .scaleEffect(rippleOn ? 1.5 : 0.3).opacity(0)
                    }
                    CursorGlyph(style: r.cursorStyle, customPath: r.customCursorPath, size: 40).scaleEffect(demoScale)
                }
                .frame(width: 80, height: 60).clipShape(RoundedRectangle(cornerRadius: 10))
                Button { playDemo() } label: { Label("Показать", systemImage: "play.fill") }.buttonStyle(SecondaryButtonStyle())
            }
        }.card()
    }

    private func playDemo() {
        rippleOn = false
        withAnimation(.easeOut(duration: max(r.clickAnimDuration, 0.05))) { demoScale = CGFloat(r.clickShrinkScale); rippleOn = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + max(r.clickAnimDuration, 0.05) + 0.12) {
            withAnimation(.spring(response: max(r.clickAnimDuration * 2.2, 0.2), dampingFraction: 0.55)) { demoScale = 1 }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { rippleOn = false }
        }
    }

    private func hotspotPicker(_ img: NSImage) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Кончик курсора (нажмите на картинку)").font(.system(size: 11.5)).foregroundColor(Theme.textDim)
            let aspect = img.size.height > 0 ? img.size.width / img.size.height : 1
            ZStack {
                Color.black.opacity(0.45)
                Image(nsImage: img).resizable().aspectRatio(contentMode: .fit)
                GeometryReader { geo in
                    Circle().strokeBorder(Color.red, lineWidth: 2).frame(width: 12, height: 12)
                        .position(x: geo.size.width * r.customCursorHotspotX, y: geo.size.height * r.customCursorHotspotY)
                    Color.clear.contentShape(Rectangle()).gesture(DragGesture(minimumDistance: 0).onChanged { v in
                        let x = min(max(Double(v.location.x / geo.size.width), 0), 1), y = min(max(Double(v.location.y / geo.size.height), 0), 1)
                        editor.edit(coalesce: "hotspot") { $0.render.customCursorHotspotX = x; $0.render.customCursorHotspotY = y }
                    })
                }
            }
            .aspectRatio(aspect, contentMode: .fit).frame(maxHeight: 110)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }

    private func chooseCustom() {
        let panel = NSOpenPanel()
        var types: [UTType] = [.png, .pdf]
        if let svg = UTType(filenameExtension: "svg") { types.append(svg) }
        panel.allowedContentTypes = types
        panel.title = "Свой курсор (PNG, PDF или SVG)"
        if panel.runModal() == .OK, let u = panel.url {
            editor.edit { $0.render.customCursorPath = u.path; $0.render.cursorStyle = "custom"; $0.render.customCursorHotspotX = 0; $0.render.customCursorHotspotY = 0 }
        }
    }
}

// MARK: - Camera tab

struct CameraTab: View {
    @ObservedObject var editor: EditorModel

    private let shapeIcons: [(CameraShape, String, String)] = [
        (.circle, "circle", "Круг"), (.roundedRect, "app", "Скруглённый"), (.squircle, "squareshape", "Сквиркл"),
        (.hexagon, "hexagon", "Шестиугольник"), (.star, "star", "Звезда"), (.heart, "heart", "Сердце"),
        (.blob, "drop", "Капля"), (.rectangle, "rectangle", "Прямоугольник"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionTitle("Камера")
            toggleRow("Показывать камеру", editor.binding(\.camera.enabled))
            toggleRow("Зеркальное отражение", editor.binding(\.camera.mirror))
            Button { editor.collapseCameraToBubble() } label: {
                Label("Свернуть в пузырь", systemImage: "arrow.down.right.and.arrow.up.left").frame(maxWidth: .infinity)
            }
            .buttonStyle(PrimaryButtonStyle())
            .help("Ставит ключевой кадр «на весь экран» на плейхеде и «пузырь» через 0.8 с")
            Button { editor.addCameraKeyframe() } label: { Label("Ключевой кадр на плейхеде", systemImage: "diamond").frame(maxWidth: .infinity) }
                .buttonStyle(SecondaryButtonStyle())
            Text("Между ключевыми кадрами положение, размер и форма меняются плавно. Выберите кадр и двигайте рамку на предпросмотре.")
                .font(.system(size: 11.5)).foregroundColor(Theme.textDim)
        }.card()
        if let k = editor.selectedCameraKey { keyCard(k) }
    }

    private func keyCard(_ k: CameraKeyframe) -> some View {
        let id = k.id
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                SectionTitle("Ключевой кадр")
                Spacer()
                Text(timecode(k.t)).font(.system(size: 11, design: .rounded).monospacedDigit()).foregroundColor(Theme.textDim)
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 4), spacing: 6) {
                ForEach(shapeIcons, id: \.0) { s in
                    Button { editor.cameraBinding(id, \.shape, fallback: .circle).wrappedValue = s.0 } label: {
                        Image(systemName: s.1).font(.system(size: 16))
                            .frame(maxWidth: .infinity).padding(.vertical, 8)
                            .background(RoundedRectangle(cornerRadius: 8).fill(k.shape == s.0 ? Theme.accent.opacity(0.7) : Color.white.opacity(0.07)))
                    }
                    .buttonStyle(.plain).help(s.2)
                }
            }
            Text("Положение").font(.system(size: 12.5))
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3), spacing: 6) {
                preset("На весь экран", "arrow.up.left.and.arrow.down.right") { fullscreen(id) }
                preset("По центру", "circle.circle") { place(id, cx: 0.5, cy: 0.5) }
                preset("Угол ↖", "arrow.up.left") { place(id, cx: nil, cy: nil, corner: (0, 0)) }
                preset("Угол ↗", "arrow.up.right") { place(id, cx: nil, cy: nil, corner: (1, 0)) }
                preset("Угол ↙", "arrow.down.left") { place(id, cx: nil, cy: nil, corner: (0, 1)) }
                preset("Угол ↘", "arrow.down.right") { place(id, cx: nil, cy: nil, corner: (1, 1)) }
            }
            SliderRow(title: "Размер", value: Binding(get: { k.w }, set: { v in setSize(id, v) }), range: 0.05...1, format: "%.2f")
            SliderRow(title: "Скругление", value: editor.cameraBinding(id, \.cornerRadius, fallback: 0.3), range: 0...1, format: "%.2f")
            SliderRow(title: "Прозрачность", value: editor.cameraBinding(id, \.opacity, fallback: 1), range: 0.1...1, format: "%.2f")
            SliderRow(title: "Масштаб внутри", value: editor.cameraBinding(id, \.innerZoom, fallback: 1), range: 1...3, format: "%.1f×")
            SliderRow(title: "Обводка", value: editor.cameraBinding(id, \.borderWidth, fallback: 0), range: 0...20, format: "%.0f")
            HStack {
                ColorPicker("Цвет обводки", selection: Binding(get: { Color(hex: k.borderColorHex) },
                                                              set: { editor.cameraBinding(id, \.borderColorHex, fallback: "#FFFFFF").wrappedValue = $0.hexString }))
            }.font(.system(size: 12))
            toggleRow("Тень", editor.cameraBinding(id, \.shadow, fallback: true))
            HStack {
                Button { editor.seek(to: k.t) } label: { Label("К кадру", systemImage: "backward.end") }.buttonStyle(SecondaryButtonStyle())
                Button(role: .destructive) { editor.deleteSelection() } label: { Label("Удалить", systemImage: "trash") }.buttonStyle(SecondaryButtonStyle())
            }
        }.card()
    }

    private func preset(_ title: String, _ icon: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: icon).font(.system(size: 12))
                Text(title).font(.system(size: 10)).lineLimit(1).minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.07)))
        }.buttonStyle(.plain)
    }

    private func mutate(_ id: UUID, _ f: @escaping (inout CameraKeyframe) -> Void) {
        editor.edit { p in
            if let i = p.camera.keyframes.firstIndex(where: { $0.id == id }) { f(&p.camera.keyframes[i]) }
        }
    }

    private func fullscreen(_ id: UUID) {
        mutate(id) { $0.x = 0; $0.y = 0; $0.w = 1; $0.h = 1; $0.shape = .rectangle; $0.cornerRadius = 0; $0.borderWidth = 0 }
    }

    private func setSize(_ id: UUID, _ w: Double) {
        let asp = editor.outputAspect
        editor.edit(coalesce: "camsize\(id)") { p in
            guard let i = p.camera.keyframes.firstIndex(where: { $0.id == id }) else { return }
            var k = p.camera.keyframes[i]
            let cx = k.x + k.w / 2, cy = k.y + k.h / 2
            let ratioPx = (k.h * 1) / max(k.w, 0.001) / max(asp, 0.1) * asp   // keep stored h/w ratio
            let newW = min(w, 1)
            var newH = min(newW * (k.h / max(k.w, 0.001)), 1)
            if k.w >= 0.99 && k.h >= 0.99 { newH = min(newW * asp * 0.56, 1) }
            _ = ratioPx
            k.w = newW; k.h = newH
            k.x = min(max(cx - newW / 2, 0), 1 - newW); k.y = min(max(cy - newH / 2, 0), 1 - newH)
            p.camera.keyframes[i] = k
        }
    }

    private func place(_ id: UUID, cx: Double?, cy: Double?, corner: (Double, Double)? = nil) {
        let asp = editor.outputAspect
        mutate(id) { k in
            if k.w >= 0.99 { k.w = 0.2; k.h = 0.2 * asp; if k.shape == .rectangle { k.shape = .circle; k.cornerRadius = 0.3 } }
            if let c = corner {
                let m = 0.03
                k.x = c.0 == 0 ? m : 1 - m - k.w
                k.y = c.1 == 0 ? m * asp : 1 - m * asp - k.h
            } else {
                k.x = (cx ?? 0.5) - k.w / 2; k.y = (cy ?? 0.5) - k.h / 2
            }
        }
    }
}

// MARK: - Audio tab

@MainActor
final class SoundPreviewer: ObservableObject {
    static let shared = SoundPreviewer()
    private var player: AVAudioPlayer?
    @Published var playing: String?
    func toggle(_ url: URL) {
        if playing == url.path { player?.stop(); playing = nil; return }
        player?.stop()
        player = try? AVAudioPlayer(contentsOf: url)
        player?.volume = 0.8
        if player?.play() == true {
            playing = url.path
            let dur = player?.duration ?? 1
            let path = url.path
            DispatchQueue.main.asyncAfter(deadline: .now() + min(dur, 30) + 0.1) { [weak self] in
                if self?.playing == path { self?.playing = nil }
            }
        }
    }
    func stop() { player?.stop(); playing = nil }
}

enum BuiltinSounds {
    static let names: [String: String] = [
        "click_soft": "Клик мягкий", "click_tick": "Клик тик", "pop": "Поп", "bubble": "Пузырь", "whoosh": "Вжух",
        "swipe": "Свайп", "chime": "Колокольчик", "success": "Успех", "notify": "Уведомление", "sparkle": "Искры",
        "thud": "Глухой удар", "keystroke": "Нажатие клавиши", "ding": "Динь", "drop": "Капля", "ambient_pad": "Фон (эмбиент, музыка)",
        "loading_start": "Загрузка: старт", "loading_loop": "Загрузка: мелодия", "loading_progress": "Загрузка: ускоряется", "loading_done": "Загрузка: готово",
        "wheel_tick": "Колёсико: щелчок", "wheel_soft": "Колёсико: мягкий щелчок", "wheel_notch": "Колёсико: ступенька", "wheel_scroll_short": "Колёсико: прокрутка", "wheel_scroll_long": "Колёсико: длинная прокрутка",
    ]
    static let order = ["click_soft", "click_tick", "pop", "bubble", "whoosh", "swipe", "chime", "success", "notify", "sparkle",
                        "thud", "keystroke", "ding", "drop", "loading_start", "loading_loop", "loading_progress", "loading_done",
                        "wheel_tick", "wheel_soft", "wheel_notch", "wheel_scroll_short", "wheel_scroll_long", "ambient_pad"]

    static var directory: URL? {
        let fm = FileManager.default
        if let r = Bundle.main.resourceURL?.appendingPathComponent("Sounds"), fm.fileExists(atPath: r.path) { return r }
        // swift run: <repo>/Sources/MotionRecord/App/File.swift -> <repo>/Resources/Sounds
        var u = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 { u.deleteLastPathComponent() }
        let repo = u.appendingPathComponent("Resources/Sounds")
        if fm.fileExists(atPath: repo.path) { return repo }
        let cwd = URL(fileURLWithPath: fm.currentDirectoryPath).appendingPathComponent("Resources/Sounds")
        return fm.fileExists(atPath: cwd.path) ? cwd : nil
    }

    static var items: [(name: String, url: URL)] {
        guard let d = directory else { return [] }
        return order.compactMap { id in
            let u = d.appendingPathComponent(id + ".wav")
            return FileManager.default.fileExists(atPath: u.path) ? (names[id] ?? id, u) : nil
        }
    }
}

struct AudioTab: View {
    @ObservedObject var editor: EditorModel
    @ObservedObject private var previewer = SoundPreviewer.shared
    @State private var systemSounds: [URL] = []
    @State private var musicFiles: [URL] = []
    @State private var scanned = false
    @AppStorage("clickSoundPath") private var clickSound = ""
    private let builtin = BuiltinSounds.items
    private var allSfx: [(name: String, url: URL)] {
        builtin.filter { !$0.url.lastPathComponent.hasPrefix("ambient") }
            + systemSounds.map { ($0.deletingPathExtension().lastPathComponent, $0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionTitle("Звук")
            SliderRow(title: "Громкость оригинала",
                      value: Binding(get: { editor.project.originalVolume * 100 },
                                     set: { v in editor.edit(coalesce: "origVol") { $0.originalVolume = v / 100 } }),
                      range: 0...200, format: "%.0f%%")
            Button { chooseFiles() } label: { Label("Добавить музыку / звук…", systemImage: "music.note.list").frame(maxWidth: .infinity) }
                .buttonStyle(PrimaryButtonStyle())
            Text("Или перетащите аудиофайл (mp3, m4a, wav, aiff, caf) на окно.").font(.system(size: 11.5)).foregroundColor(Theme.textDim)
        }.card()
        MicCard(editor: editor)
        if let id = selectedID, let c = editor.project.audioClips.first(where: { $0.id == id }) { clipCard(c) }
        KeyboardSoundCard(editor: editor)
        clickCard
        GeneratorCards(editor: editor)
        library
    }

    private var selectedID: UUID? {
        if case .audio(let id) = editor.selection { return id }
        return nil
    }

    private func clipCard(_ c: AudioClip) -> some View {
        let id = c.id
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                SectionTitle(c.isMusic ? "Выбранная музыка" : "Выбранный эффект")
                Spacer()
                Text("\(timecode(c.outputStart)) · \(timecode(editor.clipLength(c)))").font(.system(size: 11, design: .rounded).monospacedDigit()).foregroundColor(Theme.textDim)
            }
            TextField("Название", text: editor.audioBinding(id, \.name, fallback: "")).textFieldStyle(.roundedBorder)
            SliderRow(title: "Громкость", value: Binding(get: { c.volume * 100 },
                                                         set: { v in editor.audioBinding(id, \.volume, fallback: 0.8).wrappedValue = v / 100 }),
                      range: 0...200, format: "%.0f%%")
            SliderRow(title: "Появление (fade in)", value: editor.audioBinding(id, \.fadeIn, fallback: 0), range: 0...5, format: "%.1f с")
            SliderRow(title: "Затухание (fade out)", value: editor.audioBinding(id, \.fadeOut, fallback: 0), range: 0...5, format: "%.1f с")
            if c.isMusic { toggleRow("Повторять до конца видео", editor.audioBinding(id, \.loopToFitVideo, fallback: false)) }
            toggleRow("Без звука", editor.audioBinding(id, \.isMuted, fallback: false))
            toggleRow("Музыка (а не эффект)", editor.audioBinding(id, \.isMusic, fallback: true))
            HStack {
                Button { editor.splitSelectedAudio() } label: { Label("Разрезать", systemImage: "scissors") }.buttonStyle(SecondaryButtonStyle())
                Button { editor.duplicateSelection() } label: { Label("Копия", systemImage: "plus.square.on.square") }.buttonStyle(SecondaryButtonStyle())
                Button(role: .destructive) { editor.deleteSelection() } label: { Image(systemName: "trash") }.buttonStyle(SecondaryButtonStyle())
            }
        }.card()
    }

    private var clickCard: some View {
        let n = editor.clickMarkers.count
        let hasClickSounds = editor.project.audioClips.contains { $0.name.hasPrefix("Клик · ") }
        return VStack(alignment: .leading, spacing: 10) {
            SectionTitle("Звук клика")
            if n == 0 {
                Text("В этом видео нет кликов мыши (только у записей MotionRecord).").font(.system(size: 11.5)).foregroundColor(Theme.textDim)
            } else {
                Picker("Звук", selection: $clickSound) {
                    ForEach(allSfx, id: \.url.path) { s in Text(s.name).tag(s.url.path) }
                }.labelsHidden()
                Button {
                    let u = allSfx.first(where: { $0.url.path == clickSound })?.url ?? allSfx.first?.url
                    if let u { editor.addClickSounds(url: u) }
                } label: { Label("Поставить на все клики (\(n))", systemImage: "cursorarrow.click.2").frame(maxWidth: .infinity) }
                    .buttonStyle(SecondaryButtonStyle())
                if hasClickSounds {
                    Button { editor.removeClickSounds() } label: { Label("Убрать звуки кликов", systemImage: "xmark").frame(maxWidth: .infinity) }
                        .buttonStyle(SecondaryButtonStyle())
                }
            }
        }.card()
        .onAppear(perform: scan)
    }

    private var library: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !builtin.isEmpty {
                SectionTitle("Встроенные звуки")
                ForEach(builtin, id: \.url.path) { b in builtinRow(b.name, b.url) }
                SectionTitle("Эффекты macOS").padding(.top, 6)
            } else {
                SectionTitle("Эффекты (системные)")
            }
            ForEach(systemSounds, id: \.path) { u in row(u, isMusic: false) }
            if !musicFiles.isEmpty {
                SectionTitle("Музыка (~/Music)").padding(.top, 6)
                ForEach(musicFiles.prefix(80), id: \.path) { u in row(u, isMusic: true) }
            }
        }.card()
    }

    private func builtinRow(_ name: String, _ u: URL) -> some View {
        let ambient = u.lastPathComponent.hasPrefix("ambient")
        return HStack(spacing: 8) {
            Button { previewer.toggle(u) } label: {
                Image(systemName: previewer.playing == u.path ? "stop.fill" : "play.fill").font(.system(size: 10))
                    .frame(width: 24, height: 24).background(Circle().fill(Color.white.opacity(0.1)))
            }.buttonStyle(.plain).help("Прослушать")
            Text(name).font(.system(size: 12)).lineLimit(1)
            Spacer()
            Button { addBuiltin(u, ambient: ambient, name: name) } label: { Image(systemName: "plus") }
                .buttonStyle(.plain).help("Добавить на плейхед")
        }
    }

    private func addBuiltin(_ u: URL, ambient: Bool, name: String) {
        if ambient { editor.addAudio(url: u, isMusic: true, at: 0, name: name, loopFit: true) }
        else { editor.addAudio(url: u, isMusic: false, name: name) }
    }

    private func row(_ u: URL, isMusic: Bool) -> some View {
        HStack(spacing: 8) {
            Button { previewer.toggle(u) } label: {
                Image(systemName: previewer.playing == u.path ? "stop.fill" : "play.fill").font(.system(size: 10))
                    .frame(width: 24, height: 24).background(Circle().fill(Color.white.opacity(0.1)))
            }.buttonStyle(.plain).help("Прослушать")
            Text(u.deletingPathExtension().lastPathComponent).font(.system(size: 12)).lineLimit(1)
            Spacer()
            Button { editor.addAudio(url: u, isMusic: isMusic) } label: { Image(systemName: "plus") }
                .buttonStyle(.plain).help("Добавить на плейхед")
        }
    }

    private func chooseFiles() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio]
        panel.allowsMultipleSelection = true
        panel.title = "Добавить музыку или звук"
        if panel.runModal() == .OK { for u in panel.urls { editor.addAudio(url: u, isMusic: true) } }
    }

    private func scan() {
        guard !scanned else { return }
        scanned = true
        Task.detached {
            let fm = FileManager.default
            let sounds = ((try? fm.contentsOfDirectory(at: URL(fileURLWithPath: "/System/Library/Sounds"), includingPropertiesForKeys: nil)) ?? [])
                .filter { ["aiff", "aif", "caf", "wav", "m4a"].contains($0.pathExtension.lowercased()) }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
            var music: [URL] = []
            let home = fm.homeDirectoryForCurrentUser.appendingPathComponent("Music")
            if let en = fm.enumerator(at: home, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles, .skipsPackageDescendants]) {
                for case let u as URL in en {
                    if ["mp3", "m4a", "wav", "aiff"].contains(u.pathExtension.lowercased()) { music.append(u) }
                    if music.count >= 300 { break }
                }
            }
            await MainActor.run { systemSounds = sounds; musicFiles = music }
        }
    }
}

// MARK: - Wallpapers

enum WallpaperLibrary {
    static let cache = NSCache<NSString, NSImage>()

    static func isImage(_ u: URL) -> Bool { ["heic", "jpg", "jpeg", "png", "tiff", "webp"].contains(u.pathExtension.lowercased()) }

    static func images(in dir: URL, depth: Int = 3, limit: Int = 400) -> [URL] {
        var out: [URL] = []
        let fm = FileManager.default
        guard let en = fm.enumerator(at: dir, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        for case let u as URL in en {
            if en.level > depth { en.skipDescendants(); continue }
            if isImage(u) { out.append(u) }
            if out.count >= limit { break }
        }
        return out.sorted { $0.path < $1.path }
    }

    static func thumbnail(_ url: URL) -> NSImage? {
        if let c = cache.object(forKey: url.path as NSString) { return c }
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                                     kCGImageSourceThumbnailMaxPixelSize: 220]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        let img = NSImage(cgImage: cg, size: .zero)
        cache.setObject(img, forKey: url.path as NSString)
        return img
    }
}

struct WallpaperGallery: View {
    @ObservedObject var editor: EditorModel
    @State private var current: [URL] = []
    @State private var system: [URL] = []
    @State private var mine: [URL] = []
    @State private var loaded = false
    @AppStorage("wallpaperExtras") private var extrasRaw = ""

    private var extras: [String] { extrasRaw.split(separator: "\n").map(String.init) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !current.isEmpty { section("Текущие обои", current) }
            section("Мои изображения", mine, empty: "Нет изображений. Добавьте файлы или папку.")
            HStack {
                Button("Файлы…") { choose(folder: false) }.buttonStyle(SecondaryButtonStyle())
                Button("Папка…") { choose(folder: true) }.buttonStyle(SecondaryButtonStyle())
                if editor.project.style.backgroundImagePath != nil {
                    Button("Убрать") { editor.edit { $0.style.backgroundImagePath = nil } }.buttonStyle(SecondaryButtonStyle())
                }
            }
            section("Системные обои", system, empty: "Загрузка…")
            Text("Можно перетащить картинку прямо на окно.").font(.system(size: 11)).foregroundColor(Theme.textDim)
        }
        .onAppear(perform: load)
    }

    private func section(_ title: String, _ urls: [URL], empty: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 12, weight: .semibold))
            if urls.isEmpty, let e = empty {
                Text(e).font(.system(size: 11)).foregroundColor(Theme.textDim)
            } else {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3), spacing: 6) {
                    ForEach(urls, id: \.path) { u in WallpaperCell(url: u, selected: editor.project.style.backgroundImagePath == u.path) { editor.setWallpaper(u); editor.inspectorTab = .video } }
                }
            }
        }
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        let extraPaths = extras
        Task.detached {
            var cur: [URL] = []
            for s in await MainActor.run(body: { NSScreen.screens }) {
                if let u = NSWorkspace.shared.desktopImageURL(for: s), !cur.contains(u), WallpaperLibrary.isImage(u) { cur.append(u) }
            }
            let sys = WallpaperLibrary.images(in: URL(fileURLWithPath: "/System/Library/Desktop Pictures"))
            let pics = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Pictures")
            var my = WallpaperLibrary.images(in: pics, depth: 1, limit: 60)
            for p in extraPaths {
                let u = URL(fileURLWithPath: p)
                var isDir: ObjCBool = false
                if FileManager.default.fileExists(atPath: p, isDirectory: &isDir) {
                    if isDir.boolValue { my.append(contentsOf: WallpaperLibrary.images(in: u, depth: 2, limit: 100)) }
                    else if WallpaperLibrary.isImage(u) { my.append(u) }
                }
            }
            let result = (cur, sys, my)
            await MainActor.run { current = result.0; system = result.1; mine = result.2 }
        }
    }

    private func choose(folder: Bool) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = folder
        panel.canChooseFiles = !folder
        panel.allowsMultipleSelection = !folder
        if !folder { panel.allowedContentTypes = [.image] }
        panel.title = folder ? "Папка с обоями" : "Изображения для фона"
        guard panel.runModal() == .OK else { return }
        extrasRaw = (extras + panel.urls.map { $0.path }).joined(separator: "\n")
        loaded = false
        load()
        if !folder, let f = panel.urls.first { editor.setWallpaper(f) }
    }
}

private struct WallpaperCell: View {
    let url: URL
    let selected: Bool
    let action: () -> Void
    @State private var image: NSImage?

    var body: some View {
        Button(action: action) {
            ZStack {
                Color.white.opacity(0.06)
                if let image { Image(nsImage: image).resizable().aspectRatio(contentMode: .fill) }
            }
            .frame(height: 48).clipped()
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(selected ? Color.white : Color.white.opacity(0.1), lineWidth: selected ? 2 : 1))
        }
        .buttonStyle(.plain)
        .help(url.deletingPathExtension().lastPathComponent)
        .task(id: url) {
            let u = url
            image = await Task.detached(priority: .utility) { WallpaperLibrary.thumbnail(u) }.value
        }
    }
}

// MARK: - Camera access wrapper (recording)

enum CameraBridge {
    static func availableCameras() -> [(id: String, name: String)] {
        let d = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera],
                                                 mediaType: .video, position: .unspecified)
        return d.devices.map { ($0.uniqueID, $0.localizedName) }
    }
    static var isAuthorized: Bool { AVCaptureDevice.authorizationStatus(for: .video) == .authorized }
    static var isDenied: Bool {
        let s = AVCaptureDevice.authorizationStatus(for: .video)
        return s == .denied || s == .restricted
    }
    static func requestPermission() async -> Bool { await AVCaptureDevice.requestAccess(for: .video) }
}
