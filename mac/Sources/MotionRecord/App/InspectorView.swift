import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct BackgroundPreset: Identifiable {
    var id: String { name }
    let name: String
    let top: String
    let bottom: String
}

private let backgroundPresets: [BackgroundPreset] = [
    .init(name: "Фиолет", top: "#5B3DF5", bottom: "#D946EF"),
    .init(name: "Океан", top: "#0EA5E9", bottom: "#1D4ED8"),
    .init(name: "Закат", top: "#F97316", bottom: "#DB2777"),
    .init(name: "Мята", top: "#10B981", bottom: "#0891B2"),
    .init(name: "Полночь", top: "#0F172A", bottom: "#475569"),
    .init(name: "Персик", top: "#FDBA74", bottom: "#FB7185"),
    .init(name: "Лайм", top: "#A3E635", bottom: "#16A34A"),
    .init(name: "Роза", top: "#FB7185", bottom: "#9333EA"),
    .init(name: "Графит", top: "#27272A", bottom: "#09090B"),
]

private let solidPresets = ["#0F172A", "#111827", "#FFFFFF", "#F4F4F5", "#7C5CFF", "#EF4444", "#10B981", "#F59E0B"]
private let textColors = ["#FFFFFF", "#000000", "#FDE047", "#F87171", "#34D399", "#60A5FA", "#C084FC"]

struct InspectorView: View {
    @ObservedObject var editor: EditorModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 2) {
                ForEach(InspectorTab.allCases.filter { ($0 != .camera || editor.hasCamera) && ($0 != .window || editor.hasWindows) }) { tab in
                    Button { editor.inspectorTab = tab } label: {
                        VStack(spacing: 3) {
                            Image(systemName: tab.icon).font(.system(size: 13))
                            Text(tab.title).font(.system(size: 10, weight: .medium)).lineLimit(1).minimumScaleFactor(0.8)
                        }
                        .frame(maxWidth: .infinity).padding(.vertical, 7)
                        .foregroundColor(editor.inspectorTab == tab ? .white : Theme.textDim)
                        .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(editor.inspectorTab == tab ? Color.white.opacity(0.1) : .clear))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(8)
            Rectangle().fill(Theme.stroke).frame(height: 1)
            ScrollView {
                VStack(spacing: 14) {
                    switch editor.inspectorTab {
                    case .video: VideoTab(editor: editor)
                    case .camera: CameraTab(editor: editor)
                    case .audio: AudioTab(editor: editor)
                    case .cursor: CursorTab(editor: editor)
                    case .zoom: ZoomTab(editor: editor)
                    case .text: TextTab(editor: editor)
                    case .effects: EffectsTab(editor: editor)
                    case .window: WindowTab(editor: editor)
                    case .export: ExportSettingsForm(editor: editor, showAction: true)
                    }
                    Button { editor.resetTab(editor.inspectorTab) } label: {
                        Label("Сбросить по умолчанию", systemImage: "arrow.counterclockwise").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(SecondaryButtonStyle())
                }
                .padding(14)
            }
        }
        .background(Color.black.opacity(0.18))
    }
}

private func toggleRow(_ title: String, _ b: Binding<Bool>) -> some View {
    Toggle(title, isOn: b).toggleStyle(.switch).tint(Theme.accent).font(.system(size: 12.5))
}

// MARK: - Video / background

private struct VideoTab: View {
    @ObservedObject var editor: EditorModel

    var body: some View {
        if editor.selectedSegment != nil {
            VStack(alignment: .leading, spacing: 10) {
                SpeedControl(editor: editor)
                if let s = editor.selectedSegment {
                    toggleRow("Без звука", Binding(get: { s.isMuted }, set: { _ in editor.toggleMute(s.id) }))
                }
            }.card()
        }
        aspectCard
        backgroundCard
        frameCard
    }

    private var aspectCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle("Формат кадра")
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                ForEach(AspectPreset.allCases) { a in
                    let sel = editor.project.style.aspect == a
                    Button { editor.edit { $0.style.aspect = a } } label: {
                        VStack(spacing: 5) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 3).strokeBorder(sel ? Color.white : Theme.textDim, lineWidth: 1.5)
                                    .frame(width: glyphSize(a).width, height: glyphSize(a).height)
                            }.frame(height: 28)
                            Text(aspectTitle(a)).font(.system(size: 10.5, weight: .medium))
                        }
                        .frame(maxWidth: .infinity).padding(.vertical, 6)
                        .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(sel ? Theme.accent.opacity(0.55) : Color.white.opacity(0.06)))
                        .foregroundColor(.white)
                    }
                    .buttonStyle(.plain)
                }
            }
        }.card()
    }

    private func aspectTitle(_ a: AspectPreset) -> String {
        switch a {
        case .original: return "Оригинал"
        case .landscape16x9: return "16:9"
        case .vertical9x16: return "9:16"
        case .square1x1: return "1:1"
        case .portrait4x5: return "4:5"
        case .standard4x3: return "4:3"
        }
    }

    private func glyphSize(_ a: AspectPreset) -> CGSize {
        let m = editor.session.meta
        let r = a.ratio ?? Double(m.width) / Double(max(m.height, 1))
        let box: Double = 26
        return r >= 1 ? CGSize(width: box, height: box / r) : CGSize(width: box * r, height: box)
    }

    private var backgroundCard: some View {
        let kind = editor.project.style.backgroundKind
        return VStack(alignment: .leading, spacing: 12) {
            SectionTitle("Фон")
            HStack(spacing: 6) {
                ForEach(BackgroundKind.allCases) { k in
                    Chip(label: kindTitle(k), selected: kind == k) { editor.edit { $0.style.backgroundKind = k } }
                }
            }
            switch kind {
            case .gradient:
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                    ForEach(backgroundPresets) { p in
                        let r = editor.project.render
                        let sel = r.backgroundTop.caseInsensitiveCompare(p.top) == .orderedSame
                            && r.backgroundBottom.caseInsensitiveCompare(p.bottom) == .orderedSame
                        Button { editor.edit { $0.render.backgroundTop = p.top; $0.render.backgroundBottom = p.bottom } } label: {
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .fill(LinearGradient(colors: [Color(hex: p.top), Color(hex: p.bottom)], startPoint: .top, endPoint: .bottom))
                                .frame(height: 36)
                                .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                                    .strokeBorder(sel ? Color.white : Color.white.opacity(0.1), lineWidth: sel ? 2 : 1))
                        }
                        .buttonStyle(.plain).help(p.name)
                    }
                }
                HStack {
                    ColorPicker("Верх", selection: Binding(get: { Color(hex: editor.project.render.backgroundTop) },
                                                           set: { c in editor.edit(coalesce: "bgTop") { $0.render.backgroundTop = c.hexString } }))
                    ColorPicker("Низ", selection: Binding(get: { Color(hex: editor.project.render.backgroundBottom) },
                                                          set: { c in editor.edit(coalesce: "bgBottom") { $0.render.backgroundBottom = c.hexString } }))
                }.font(.system(size: 12))
            case .solid:
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8) {
                    ForEach(solidPresets, id: \.self) { c in
                        let sel = editor.project.render.backgroundTop.caseInsensitiveCompare(c) == .orderedSame
                            && editor.project.render.backgroundBottom.caseInsensitiveCompare(c) == .orderedSame
                        Button { editor.edit { $0.render.backgroundTop = c; $0.render.backgroundBottom = c } } label: {
                            RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color(hex: c)).frame(height: 32)
                                .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                                    .strokeBorder(sel ? Color.white : Color.white.opacity(0.15), lineWidth: sel ? 2 : 1))
                        }.buttonStyle(.plain)
                    }
                }
                ColorPicker("Свой цвет", selection: Binding(get: { Color(hex: editor.project.render.backgroundTop) },
                                                           set: { c in editor.edit(coalesce: "bgSolid") { $0.render.backgroundTop = c.hexString; $0.render.backgroundBottom = c.hexString } }))
                    .font(.system(size: 12))
            case .image:
                WallpaperGallery(editor: editor)
            case .blurredVideo:
                Text("Фон — размытая копия самого видео.").font(.system(size: 11.5)).foregroundColor(Theme.textDim)
            }
        }.card()
    }

    private func kindTitle(_ k: BackgroundKind) -> String {
        switch k {
        case .gradient: return "Градиент"
        case .solid: return "Цвет"
        case .image: return "Обои"
        case .blurredVideo: return "Размытие"
        }
    }

    private var frameCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionTitle("Рамка")
            SliderRow(title: "Отступ", value: editor.binding(\.render.padding), range: 0...0.15, format: "%.3f")
            SliderRow(title: "Скругление", value: editor.binding(\.render.cornerRadius), range: 0...60, format: "%.0f")
            SliderRow(title: "Тень", value: Binding(get: { editor.project.style.shadowIntensity },
                                                    set: { v in editor.edit(coalesce: "shadow") { $0.style.shadowIntensity = v; $0.render.shadow = v > 0.01 } }),
                      range: 0...1, format: "%.2f")
        }.card()
    }
}

// MARK: - Zoom

private struct ZoomTab: View {
    @ObservedObject var editor: EditorModel

    var body: some View {
        if let z = editor.selectedZoom { selectedCard(z) }
        VStack(alignment: .leading, spacing: 12) {
            SectionTitle("Автозум по кликам")
            toggleRow("Автоматический зум", editor.binding(\.render.autoZoom))
            Group {
                SliderRow(title: "Масштаб по умолчанию", value: editor.binding(\.render.zoomScale), range: 1.2...4, format: "%.1f×")
                SliderRow(title: "Удержание", value: editor.binding(\.render.zoomHold), range: 0.3...4, format: "%.1f с")
                SliderRow(title: "Длительность перехода", value: editor.binding(\.render.zoomDuration), range: 0.2...2, format: "%.1f с")
                SliderRow(title: "Плавность камеры", value: editor.binding(\.render.cameraSmoothing), range: 0...1, format: "%.2f")
            }
            .disabled(!editor.project.render.autoZoom).opacity(editor.project.render.autoZoom ? 1 : 0.4)
            if !editor.hasCursorData {
                Text("Автозум работает по кликам из записи. У импортированного видео кликов нет — добавляйте зум вручную.")
                    .font(.system(size: 11.5)).foregroundColor(Theme.textDim)
            }
        }.card()
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle("Зум вручную")
            HStack {
                Button { editor.addZoom() } label: { Label("Добавить на плейхеде", systemImage: "plus") }
                    .buttonStyle(SecondaryButtonStyle())
            }
            if !editor.visibleAutoZooms.isEmpty {
                Button { editor.adoptAutoZooms() } label: { Label("Сделать автозумы ручными (\(editor.visibleAutoZooms.count))", systemImage: "wand.and.stars") }
                    .buttonStyle(SecondaryButtonStyle())
            }
            Text("Двойной клик по дорожке зума добавляет область. Перетаскивайте края, чтобы изменить длительность.")
                .font(.system(size: 11.5)).foregroundColor(Theme.textDim)
        }.card()
    }

    private func selectedCard(_ z: ZoomRegion) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                SectionTitle("Выбранный зум")
                Spacer()
                Text("\(timecode(z.start)) – \(timecode(z.end))").font(.system(size: 11, design: .rounded).monospacedDigit()).foregroundColor(Theme.textDim)
            }
            SliderRow(title: "Масштаб", value: editor.zoomBinding(z.id, \.scale, fallback: 2), range: 1.1...5, format: "%.1f×")
            toggleRow("Следовать за курсором", editor.zoomBinding(z.id, \.followCursor, fallback: true))
            Text("Точка фокуса").font(.system(size: 12.5))
            FocusPicker(editor: editor, region: z)
            HStack {
                Button { editor.seek(to: z.start) } label: { Label("К началу", systemImage: "backward.end") }
                    .buttonStyle(SecondaryButtonStyle())
                Button(role: .destructive) { editor.deleteSelection() } label: { Label("Удалить", systemImage: "trash") }
                    .buttonStyle(SecondaryButtonStyle())
            }
        }.card()
    }
}

/// Click on a still frame of the source to choose the zoom focus point.
private struct FocusPicker: View {
    @ObservedObject var editor: EditorModel
    let region: ZoomRegion

    var body: some View {
        let m = editor.session.meta
        let aspect = CGFloat(m.width) / CGFloat(max(m.height, 1))
        let src = editor.project.sourceTime(forOutput: (region.start + region.end) / 2, sourceDuration: editor.sourceDuration)
        ZStack {
            Color.black
            if !editor.thumbnails.isEmpty {
                let i = min(max(Int(src / editor.sourceDuration * Double(editor.thumbnails.count)), 0), editor.thumbnails.count - 1)
                Image(decorative: editor.thumbnails[i], scale: 1).resizable().aspectRatio(contentMode: .fill)
            }
            GeometryReader { geo in
                let p = CGPoint(x: geo.size.width * region.focusX, y: geo.size.height * region.focusY)
                Rectangle().strokeBorder(Color.white.opacity(0.9), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    .frame(width: geo.size.width / region.scale, height: geo.size.height / region.scale)
                    .position(p)
                Circle().strokeBorder(Color.white, lineWidth: 2).background(Circle().fill(Theme.accent.opacity(0.7)))
                    .frame(width: 14, height: 14).position(p)
                Color.clear.contentShape(Rectangle()).gesture(DragGesture(minimumDistance: 0).onChanged { v in
                    let fx = min(max(Double(v.location.x / geo.size.width), 0), 1)
                    let fy = min(max(Double(v.location.y / geo.size.height), 0), 1)
                    editor.edit(coalesce: "focus\(region.id)") { pr in
                        if let i = pr.zoomRegions.firstIndex(where: { $0.id == region.id }) { pr.zoomRegions[i].focusX = fx; pr.zoomRegions[i].focusY = fy }
                    }
                })
            }
        }
        .aspectRatio(aspect, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.stroke))
        .help("Нажмите или тяните, чтобы выбрать точку, на которую наезжает камера")
    }
}

// MARK: - Window cut-out

private struct WindowTab: View {
    @ObservedObject var editor: EditorModel

    var body: some View {
        if let w = editor.selectedWindowCutout { selectedCard(w) }
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle("Окна")
            HStack {
                Button { editor.addWindowAtPlayhead() } label: { Label("Верхнее окно на плейхеде", systemImage: "plus") }
                    .buttonStyle(SecondaryButtonStyle())
            }
            Button { editor.setPickingWindow(!editor.pickingWindow) } label: {
                Label(editor.pickingWindow ? "Отмена выбора" : "Выбрать окно на превью", systemImage: "macwindow.badge.plus")
            }.buttonStyle(SecondaryButtonStyle())
            toggleRow("Экран записи как обои за окном", editor.binding(\.style.cutoutScreenBackdrop))
            Text("Пока блок на дорожке «Окна» активен, вместо всего экрана показывается только это окно (плавное появление). Нажмите на блок, чтобы выбрать другое окно.")
                .font(.system(size: 11.5)).foregroundColor(Theme.textDim)
        }.card()
    }

    private func name(_ t: WindowTrack) -> String { t.title.isEmpty ? t.app : "\(t.app) · \(t.title)" }

    private func selectedCard(_ w: WindowCutout) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                SectionTitle("Выбранное окно")
                Spacer()
                Text("\(timecode(w.start)) – \(timecode(w.end))").font(.system(size: 11, design: .rounded).monospacedDigit()).foregroundColor(Theme.textDim)
            }
            if let tr = editor.windowTrack(w.windowID) {
                HStack(spacing: 8) {
                    Image(systemName: "macwindow").foregroundColor(Color(hex: "#14B8A6"))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(tr.app).font(.system(size: 12.5, weight: .semibold))
                        if !tr.title.isEmpty { Text(tr.title).font(.system(size: 11)).foregroundColor(Theme.textDim).lineLimit(1) }
                    }
                }
            } else {
                Text("Окно не найдено в записи").font(.system(size: 12)).foregroundColor(.orange)
            }
            Text("Выбрать другое окно").font(.system(size: 12.5))
            let cands = editor.windowCandidates(for: w)
            if cands.isEmpty { Text("В этом промежутке нет окон").font(.system(size: 11.5)).foregroundColor(Theme.textDim) }
            VStack(spacing: 4) {
                ForEach(cands, id: \.track.id) { c in
                    let sel = c.track.id == w.windowID
                    Button { editor.windowBinding(w.id, \.windowID, fallback: w.windowID).wrappedValue = c.track.id } label: {
                        HStack(spacing: 8) {
                            Image(systemName: sel ? "checkmark.circle.fill" : "circle").foregroundColor(sel ? Theme.accent : Theme.textDim)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(name(c.track)).font(.system(size: 12, weight: .medium)).lineLimit(1)
                                Text("\(Int(c.size.width))×\(Int(c.size.height))").font(.system(size: 10.5)).foregroundColor(Theme.textDim)
                            }
                            Spacer()
                        }
                        .padding(.horizontal, 8).padding(.vertical, 5)
                        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(sel ? Theme.accent.opacity(0.25) : Color.white.opacity(0.05)))
                    }.buttonStyle(.plain)
                }
            }
            SliderRow(title: "Отступ", value: editor.windowBinding(w.id, \.padding, fallback: 0.06), range: 0...0.2, format: "%.2f")
            SliderRow(title: "Скругление углов", value: editor.windowBinding(w.id, \.cornerRadius, fallback: 12), range: 0...30, format: "%.0f")
            SliderRow(title: "Плавность появления", value: editor.windowBinding(w.id, \.transition, fallback: 0.45), range: 0...2, format: "%.1f с")
            toggleRow("Тень", editor.windowBinding(w.id, \.shadow, fallback: true))
            HStack {
                Button { editor.seek(to: w.start) } label: { Label("К началу", systemImage: "backward.end") }
                    .buttonStyle(SecondaryButtonStyle())
                Button(role: .destructive) { editor.deleteSelection() } label: { Label("Удалить окно", systemImage: "trash") }
                    .buttonStyle(SecondaryButtonStyle())
            }
        }.card()
    }
}

// MARK: - Text

private struct TextTab: View {
    @ObservedObject var editor: EditorModel

    var body: some View {
        if let t = editor.selectedText { selectedCard(t) }
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle("Надписи")
            Button { editor.addText() } label: { Label("Добавить текст на плейхеде", systemImage: "plus") }
                .buttonStyle(SecondaryButtonStyle())
            if editor.project.texts.isEmpty {
                Text("Надписей пока нет. Двойной клик по дорожке текста тоже добавляет.")
                    .font(.system(size: 11.5)).foregroundColor(Theme.textDim)
            }
            ForEach(editor.project.texts) { t in
                Button { editor.selection = .text(t.id) } label: {
                    HStack {
                        Image(systemName: "textformat").foregroundColor(Color(hex: "#F59E0B"))
                        Text(t.text).lineLimit(1).font(.system(size: 12.5))
                        Spacer()
                        Text(timecode(t.start, fine: false)).font(.system(size: 11, design: .rounded).monospacedDigit()).foregroundColor(Theme.textDim)
                    }
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .background(RoundedRectangle(cornerRadius: 8).fill(editor.selection == .text(t.id) ? Theme.accent.opacity(0.4) : Color.white.opacity(0.05)))
                }.buttonStyle(.plain)
            }
        }.card()
    }

    private func selectedCard(_ t: TextOverlay) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                SectionTitle("Выбранный текст")
                Spacer()
                Text("\(timecode(t.start)) – \(timecode(t.end))").font(.system(size: 11, design: .rounded).monospacedDigit()).foregroundColor(Theme.textDim)
            }
            TextField("Текст", text: editor.textBinding(t.id, \.text, fallback: ""), axis: .vertical)
                .textFieldStyle(.roundedBorder).lineLimit(1...3)
            SliderRow(title: "Размер", value: editor.textBinding(t.id, \.fontSize, fallback: 48), range: 16...200, format: "%.0f")
            HStack(spacing: 6) {
                ForEach(textColors, id: \.self) { c in
                    Button { editor.textBinding(t.id, \.colorHex, fallback: "#FFFFFF").wrappedValue = c } label: {
                        Circle().fill(Color(hex: c)).frame(width: 22, height: 22)
                            .overlay(Circle().strokeBorder(t.colorHex.caseInsensitiveCompare(c) == .orderedSame ? Theme.accent : Color.white.opacity(0.25),
                                                           lineWidth: t.colorHex.caseInsensitiveCompare(c) == .orderedSame ? 2.5 : 1))
                    }.buttonStyle(.plain)
                }
                ColorPicker("", selection: Binding(get: { Color(hex: t.colorHex) },
                                                   set: { editor.textBinding(t.id, \.colorHex, fallback: "#FFFFFF").wrappedValue = $0.hexString }))
                    .labelsHidden()
            }
            toggleRow("Плашка под текстом", editor.textBinding(t.id, \.hasBackground, fallback: true))
            toggleRow("Анимация печатания", editor.textBinding(t.id, \.typewriter, fallback: false))
            if t.typewriter {
                SliderRow(title: "Скорость печати", value: editor.textBinding(t.id, \.typeSpeed, fallback: 16), range: 4...40, format: "%.0f букв/с")
            }
            toggleRow("Звук печати на клавиатуре", Binding(get: { t.typeSound }, set: { on in
                editor.edit { p in
                    if let i = p.texts.firstIndex(where: { $0.id == t.id }) {
                        p.texts[i].typeSound = on
                        if on { p.texts[i].typewriter = true }   // sound is tied to the typing animation
                    }
                }
            }))
            SliderRow(title: "Позиция X", value: editor.textBinding(t.id, \.x, fallback: 0.5), range: 0...1, format: "%.2f")
            SliderRow(title: "Позиция Y", value: editor.textBinding(t.id, \.y, fallback: 0.85), range: 0...1, format: "%.2f")
            Text("Текст можно перетаскивать прямо на предпросмотре.").font(.system(size: 11)).foregroundColor(Theme.textDim)
            HStack {
                Button { editor.duplicateSelection() } label: { Label("Дублировать", systemImage: "plus.square.on.square") }
                    .buttonStyle(SecondaryButtonStyle())
                Button(role: .destructive) { editor.deleteSelection() } label: { Label("Удалить", systemImage: "trash") }
                    .buttonStyle(SecondaryButtonStyle())
            }
        }.card()
    }
}

// MARK: - Export settings (shared by tab and sheet)

struct ExportSettingsForm: View {
    @ObservedObject var editor: EditorModel
    var showAction: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 10) {
                SectionTitle("Формат")
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 2), spacing: 6) {
                    ForEach(EditProject.ExportFormat.allCases) { f in
                        Chip(label: formatTitle(f), selected: editor.project.exportFormat == f) { editor.edit { $0.exportFormat = f } }
                    }
                }
                SectionTitle("Разрешение (высота)")
                HStack(spacing: 5) {
                    ForEach([(0, "Исходное"), (720, "720"), (1080, "1080"), (1440, "1440"), (2160, "4K")], id: \.0) { v in
                        Chip(label: v.1, selected: editor.project.render.outputHeight == v.0) { editor.edit { $0.render.outputHeight = v.0 } }
                    }
                }
                SectionTitle("Частота кадров")
                HStack(spacing: 5) {
                    ForEach([(0, "Исходная"), (30, "30"), (60, "60")], id: \.0) { v in
                        Chip(label: v.1, selected: editor.project.render.outputFPS == v.0) { editor.edit { $0.render.outputFPS = v.0 } }
                    }
                }
                Text("Длительность итогового видео: \(timecode(editor.outputDuration))")
                    .font(.system(size: 11.5)).foregroundColor(Theme.textDim)
                if editor.project.exportFormat == .gif {
                    Text("GIF без звука; для размера лучше выбрать 720 и 30 fps.").font(.system(size: 11.5)).foregroundColor(Theme.textDim)
                }
            }
            if showAction {
                Button { editor.showExportSheet = true } label: {
                    Label("Экспортировать…", systemImage: "square.and.arrow.up").frame(maxWidth: .infinity)
                }.buttonStyle(PrimaryButtonStyle())
            }
        }
        .card()
    }

    private func formatTitle(_ f: EditProject.ExportFormat) -> String {
        switch f {
        case .mp4HEVC: return "MP4 · HEVC"
        case .mp4H264: return "MP4 · H.264"
        case .mov: return "MOV"
        case .gif: return "GIF"
        }
    }
}

// MARK: - Export sheet

struct ExportSheet: View {
    @ObservedObject var editor: EditorModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Экспорт видео").font(.system(size: 17, weight: .semibold))
                Spacer()
                Button { dismiss() } label: { Image(systemName: "xmark") }.buttonStyle(.plain)
                    .disabled(editor.exportProgress != nil)
            }
            if let p = editor.exportProgress {
                VStack(spacing: 12) {
                    ProgressView(value: min(max(p, 0), 1)).progressViewStyle(.linear).tint(Theme.accent)
                    HStack {
                        Text("Рендеринг… \(Int(p * 100))%").font(.system(size: 12.5, design: .rounded).monospacedDigit()).foregroundColor(Theme.textDim)
                        Spacer()
                        Button("Отмена") { editor.cancelExport() }.buttonStyle(SecondaryButtonStyle())
                    }
                }
                .padding(.vertical, 10)
            } else if let url = editor.exportResultURL {
                VStack(alignment: .leading, spacing: 12) {
                    Label("Готово", systemImage: "checkmark.circle.fill").foregroundColor(.green).font(.system(size: 14, weight: .semibold))
                    Text(url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")).font(.system(size: 11.5)).foregroundColor(Theme.textDim)
                    HStack {
                        Button { NSWorkspace.shared.activateFileViewerSelecting([url]) } label: { Label("Показать в Finder", systemImage: "folder") }
                            .buttonStyle(PrimaryButtonStyle())
                        Button("Экспортировать ещё") { editor.exportResultURL = nil }.buttonStyle(SecondaryButtonStyle())
                        Button("Закрыть") { editor.exportResultURL = nil; dismiss() }.buttonStyle(SecondaryButtonStyle())
                    }
                }
            } else {
                ExportSettingsForm(editor: editor, showAction: false)
                if let err = editor.exportError {
                    Label(err, systemImage: "exclamationmark.triangle").font(.system(size: 12)).foregroundColor(.orange)
                }
                HStack {
                    Spacer()
                    Button("Отмена") { dismiss() }.buttonStyle(SecondaryButtonStyle())
                    Button { editor.chooseExportURLAndRun() } label: { Label("Выбрать место и экспортировать", systemImage: "square.and.arrow.up") }
                        .buttonStyle(PrimaryButtonStyle())
                }
            }
        }
        .padding(22)
        .frame(width: 440)
        .background(Theme.bg)
        .preferredColorScheme(.dark)
        .interactiveDismissDisabled(editor.exportProgress != nil)
    }
}
