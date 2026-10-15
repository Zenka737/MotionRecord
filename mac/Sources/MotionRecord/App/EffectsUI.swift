import SwiftUI
import AppKit

let blurColor = Color(hex: "#EC4899")

private func toggleRow(_ title: String, _ b: Binding<Bool>) -> some View {
    Toggle(title, isOn: b).toggleStyle(.switch).tint(Theme.accent).font(.system(size: 12.5))
}

// MARK: - Inspector tab "Эффекты": blur regions + Mochi

struct EffectsTab: View {
    @ObservedObject var editor: EditorModel

    var body: some View {
        blurCard
        if let b = editor.selectedBlur { selectedBlurCard(b) }
        mochiCard
    }

    // ---- Blur ----

    private var blurCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle("Скрыть часть кадра")
            Button { editor.addBlur() } label: { Label("Добавить размытие на плейхеде (B)", systemImage: "plus") }
                .buttonStyle(SecondaryButtonStyle())
            if editor.project.blurs.isEmpty {
                Text("Закройте пароль, лицо или уведомление: размытие, пиксели или чёрная плашка. Рамку можно двигать и тянуть за углы прямо на кадре.")
                    .font(.system(size: 11.5)).foregroundColor(Theme.textDim)
            }
            ForEach(editor.project.blurs) { b in
                Button { editor.selection = .blur(b.id); editor.seek(to: min(max(editor.playhead, b.start + 0.05), b.end - 0.05)) } label: {
                    HStack {
                        Image(systemName: icon(b.kind)).foregroundColor(blurColor)
                        Text(b.kind.title).font(.system(size: 12.5))
                        Spacer()
                        Text("\(timecode(b.start, fine: false)) – \(timecode(b.end, fine: false))")
                            .font(.system(size: 11, design: .rounded).monospacedDigit()).foregroundColor(Theme.textDim)
                    }
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .background(RoundedRectangle(cornerRadius: 8).fill(editor.selection == .blur(b.id) ? Theme.accent.opacity(0.4) : Color.white.opacity(0.05)))
                }.buttonStyle(.plain)
            }
        }.card()
    }

    private func icon(_ k: BlurKind) -> String {
        switch k { case .blur: return "drop.halffull"; case .pixelate: return "squareshape.split.3x3"; case .cover: return "rectangle.fill" }
    }

    private func selectedBlurCard(_ b: BlurRegion) -> some View {
        let id = b.id
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                SectionTitle("Выбранная область")
                Spacer()
                Text("\(timecode(b.start)) – \(timecode(b.end))").font(.system(size: 11, design: .rounded).monospacedDigit()).foregroundColor(Theme.textDim)
            }
            HStack(spacing: 6) {
                ForEach(BlurKind.allCases) { k in
                    Chip(label: k.title, selected: b.kind == k) { editor.blurBinding(id, \.kind, fallback: .blur).wrappedValue = k }
                }
            }
            if b.kind != .cover {
                SliderRow(title: b.kind == .blur ? "Сила размытия" : "Размер пикселей", value: editor.blurBinding(id, \.strength, fallback: 0.6), range: 0...1, format: "%.2f")
            }
            SliderRow(title: "Скругление углов", value: editor.blurBinding(id, \.cornerRadius, fallback: 0.2), range: 0...1, format: "%.2f")
            toggleRow("Двигается вместе с зумом экрана", Binding(get: { b.anchor == .screen }, set: { on in
                // keep the rectangle where the viewer sees it right now
                let t = min(max(editor.playhead, b.start), b.end)
                let frame = editor.blurFrameRect(b, at: t)
                editor.edit { p in
                    guard let i = p.blurs.firstIndex(where: { $0.id == id }) else { return }
                    var nb = p.blurs[i]; nb.anchor = on ? .screen : .frame
                    p.blurs[i] = editor.blurRegion(nb, settingFrameRect: frame, at: t)
                }
            }))
            Text(b.anchor == .screen ? "Область привязана к содержимому экрана: при зуме и движении камеры она остаётся на нужном месте."
                                     : "Область привязана к кадру: стоит на месте, даже если камера движется.")
                .font(.system(size: 11)).foregroundColor(Theme.textDim)
            HStack(spacing: 8) {
                Button { editor.duplicateSelection() } label: { Label("Дублировать", systemImage: "plus.square.on.square").frame(maxWidth: .infinity) }
                    .buttonStyle(SecondaryButtonStyle())
                Button(role: .destructive) { editor.deleteSelection() } label: { Label("Удалить", systemImage: "trash").frame(maxWidth: .infinity) }
                    .buttonStyle(SecondaryButtonStyle())
            }
        }.card()
    }

    // ---- Mochi ----

    private var mochiCard: some View {
        let m = editor.project.mochi
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                SectionTitle("Моти внизу кадра")
                Spacer()
            }
            toggleRow("Показывать Моти", editor.binding(\.mochi.enabled))
            if m.enabled {
                Text("Моти подпрыгивает и открывает рот, когда звучит голос. Двигайте его прямо на кадре.")
                    .font(.system(size: 11.5)).foregroundColor(Theme.textDim)
                SliderRow(title: "Размер", value: editor.binding(\.mochi.size), range: 0.08...0.5, format: "%.2f")
                SliderRow(title: "Высота прыжка", value: editor.binding(\.mochi.bounce), range: 0...2, format: "%.1f")
                SliderRow(title: "Чувствительность к звуку", value: editor.binding(\.mochi.sensitivity), range: 0.3...3, format: "%.1f×")
                HStack(spacing: 6) {
                    Chip(label: "Чёрный", selected: m.darkBody) { editor.edit { $0.mochi.darkBody = true } }
                    Chip(label: "Белый", selected: !m.darkBody) { editor.edit { $0.mochi.darkBody = false } }
                }
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3), spacing: 6) {
                    ForEach(MochiHat.allCases) { h in
                        Chip(label: h.title, selected: m.hat == h) { editor.edit { $0.mochi.hat = h } }
                    }
                }
                toggleRow("Рот открывается", editor.binding(\.mochi.mouth))
                SectionTitle("Реагирует на")
                toggleRow(editor.hasMic ? "Микрофон (записан)" : "Микрофон (в этой записи его нет)", editor.binding(\.mochi.reactMic))
                toggleRow("Голос и эффекты (дорожка эффектов)", editor.binding(\.mochi.reactVoice))
                toggleRow("Музыку (Моти танцует)", editor.binding(\.mochi.reactMusic))
                Text("Хотите, чтобы Моти «сказал» фразу: перетащите на окно аудиофайл с голосом — он ляжет на дорожку эффектов и Моти заговорит под него.")
                    .font(.system(size: 11)).foregroundColor(Theme.textDim)
            }
        }.card()
    }
}

// MARK: - Microphone card (Audio tab)

struct MicCard: View {
    @ObservedObject var editor: EditorModel
    @State private var lastMessage: String?

    private func cutPauses() {
        let before = editor.outputDuration
        let n = editor.removeSilences()
        let saved = max(0, before - editor.outputDuration)
        lastMessage = n == 0 ? "Пауз длиннее 0,8 с не найдено." : "Вырезано пауз: \(n), видео короче на \(String(format: "%.1f", saved)) с. Можно отменить (⌘Z)."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle("Микрофон")
            if editor.hasMic {
                Toggle("Звук микрофона", isOn: editor.binding(\.mic.enabled)).toggleStyle(.switch).tint(Theme.accent).font(.system(size: 12.5))
                if editor.project.mic.enabled {
                    SliderRow(title: "Громкость голоса", value: Binding(get: { editor.project.mic.volume * 100 },
                                                                      set: { v in editor.edit(coalesce: "micVol") { $0.mic.volume = v / 100 } }),
                              range: 0...300, format: "%.0f%%")
                }
                Button { cutPauses() } label: { Label("Вырезать паузы в речи", systemImage: "scissors.badge.ellipsis").frame(maxWidth: .infinity) }
                    .buttonStyle(SecondaryButtonStyle())
                    .disabled(editor.micEnvelope == nil)
                if let m = lastMessage { Text(m).font(.system(size: 11.5)).foregroundColor(Theme.accent) }
                Text("Голос записан вместе с экраном и режется / ускоряется вместе с видео. Зелёная дорожка внизу таймлайна — его громкость.")
                    .font(.system(size: 11)).foregroundColor(Theme.textDim)
            } else {
                Text("В этой записи нет микрофона. Включите «Записывать микрофон» на вкладке записи, чтобы озвучивать видео голосом.")
                    .font(.system(size: 11.5)).foregroundColor(Theme.textDim)
            }
        }.card()
    }
}

// MARK: - Preview boxes (blur rectangle, Mochi)

/// Draggable / resizable rectangle for the selected blur region, drawn where the viewer sees it (zoom-aware).
struct BlurBox: View {
    @ObservedObject var editor: EditorModel
    let region: BlurRegion
    let W: CGFloat, H: CGFloat
    @State private var base: CGRect?
    @State private var baseTime: Double = 0

    private var visible: Bool { editor.playhead >= region.start - 0.001 && editor.playhead <= region.end + 0.001 }

    var body: some View {
        let t = min(max(editor.playhead, region.start), region.end)
        let n = editor.blurFrameRect(region, at: t)
        let r = CGRect(x: n.minX * W, y: n.minY * H, width: n.width * W, height: n.height * H)
        ZStack(alignment: .topLeading) {
            Rectangle().fill(Color.white.opacity(0.001))
                .frame(width: r.width, height: r.height)
                .overlay(RoundedRectangle(cornerRadius: min(r.width, r.height) * CGFloat(region.cornerRadius) / 2)
                    .strokeBorder(blurColor, style: StrokeStyle(lineWidth: 2, dash: visible ? [] : [6, 4])))
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("bv")).onChanged { v in
                    if base == nil { base = n; baseTime = t }
                    guard let b = base else { return }
                    let nx = min(max(b.minX + v.translation.width / W, 0), 1 - b.width)
                    let ny = min(max(b.minY + v.translation.height / H, 0), 1 - b.height)
                    apply(CGRect(x: nx, y: ny, width: b.width, height: b.height))
                }.onEnded { _ in base = nil })
                .offset(x: r.minX, y: r.minY)
            ForEach(0..<4, id: \.self) { i in
                let right = i % 2 == 1, bottom = i >= 2
                Circle().fill(Color.white).overlay(Circle().strokeBorder(blurColor, lineWidth: 2))
                    .frame(width: 14, height: 14).padding(6).contentShape(Rectangle())
                    .position(x: right ? r.maxX : r.minX, y: bottom ? r.maxY : r.minY)
                    .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("bv")).onChanged { v in
                        if base == nil { base = n; baseTime = t }
                        guard let b = base else { return }
                        let px = Double(v.location.x / W), py = Double(v.location.y / H)
                        var x0 = Double(b.minX), y0 = Double(b.minY), x1 = Double(b.maxX), y1 = Double(b.maxY)
                        if right { x1 = min(max(px, x0 + 0.02), 1) } else { x0 = max(min(px, x1 - 0.02), 0) }
                        if bottom { y1 = min(max(py, y0 + 0.02), 1) } else { y0 = max(min(py, y1 - 0.02), 0) }
                        apply(CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0))
                    }.onEnded { _ in base = nil })
            }
            Text(visible ? "Тяните рамку или углы" : "Область скрыта в этот момент — подвиньте плейхед внутрь")
                .font(.system(size: 11)).padding(.horizontal, 8).padding(.vertical, 4)
                .background(Capsule().fill(Color.black.opacity(0.6)))
                .position(x: W / 2, y: 16).allowsHitTesting(false)
        }
        .frame(width: W, height: H, alignment: .topLeading)
        .coordinateSpace(name: "bv")
    }

    private func apply(_ frameRect: CGRect) {
        let id = region.id, tt = baseTime
        editor.edit(coalesce: "blurrect\(id)") { p in
            guard let i = p.blurs.firstIndex(where: { $0.id == id }) else { return }
            p.blurs[i] = editor.blurRegion(p.blurs[i], settingFrameRect: frameRect, at: tt)
        }
    }
}

/// Drag Mochi to a new place on the frame (only while the "Эффекты" tab is open and nothing else is selected).
struct MochiHandle: View {
    @ObservedObject var editor: EditorModel
    let W: CGFloat, H: CGFloat
    @State private var base: CGPoint?

    var body: some View {
        let m = editor.project.mochi
        let size = CGFloat(m.size) * H
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
                .strokeBorder(Theme.accent, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                .background(Color.white.opacity(0.001))
                .frame(width: size * 1.1, height: size * 1.5)
                .contentShape(Rectangle())
                .position(x: CGFloat(m.x) * W, y: CGFloat(m.y) * H - size * 0.2)
                .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("mv")).onChanged { v in
                    if base == nil { base = CGPoint(x: m.x, y: m.y) }
                    guard let b = base else { return }
                    let nx = min(max(Double(b.x + v.translation.width / W), 0.04), 0.96)
                    let ny = min(max(Double(b.y + v.translation.height / H), 0.05), 0.98)
                    editor.edit(coalesce: "mochipos") { $0.mochi.x = nx; $0.mochi.y = ny }
                }.onEnded { _ in base = nil })
            Text("Перетащите Моти")
                .font(.system(size: 11)).padding(.horizontal, 8).padding(.vertical, 4)
                .background(Capsule().fill(Color.black.opacity(0.6)))
                .position(x: W / 2, y: 16).allowsHitTesting(false)
        }
        .frame(width: W, height: H, alignment: .topLeading)
        .coordinateSpace(name: "mv")
    }
}
