import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - Event catcher (trackpad scroll / pinch / wheel over the timeline)

struct ScrollCatcher: NSViewRepresentable {
    var onPan: (Double) -> Void
    var onZoom: (Double, Double) -> Void   // factor, anchor x in view coordinates

    final class V: NSView {
        var monitor: Any?
        var onPan: (Double) -> Void = { _ in }
        var onZoom: (Double, Double) -> Void = { _, _ in }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .magnify]) { [weak self] e in
                guard let self, e.window === self.window else { return e }
                let p = self.convert(e.locationInWindow, from: nil)
                guard self.bounds.contains(p) else { return e }
                if e.type == .magnify {
                    self.onZoom(1 + Double(e.magnification), Double(p.x))
                    return nil
                }
                if e.modifierFlags.contains(.command) || e.modifierFlags.contains(.option) {
                    self.onZoom(exp(Double(e.scrollingDeltaY) * 0.01), Double(p.x))
                    return nil
                }
                let dx = Double(e.scrollingDeltaX), dy = Double(e.scrollingDeltaY)
                self.onPan(abs(dx) > abs(dy) ? dx : dy)
                return nil
            }
        }
        deinit { if let m = monitor { NSEvent.removeMonitor(m) } }
    }

    func makeNSView(context: Context) -> V {
        let v = V(); v.onPan = onPan; v.onZoom = onZoom; return v
    }
    func updateNSView(_ v: V, context: Context) { v.onPan = onPan; v.onZoom = onZoom }
}

// MARK: - Timeline

private let rulerH: CGFloat = 24
private let videoH: CGFloat = 50
private let zoomH: CGFloat = 24
private let textH: CGFloat = 24
private let laneH: CGFloat = 24
private let laneGap: CGFloat = 4
private let gutterW: CGFloat = 34
private let zoomColor = Color(hex: "#7C5CFF")
private let textColor = Color(hex: "#F59E0B")
private let windowColor = Color(hex: "#14B8A6")

struct TimelineView: View {
    @ObservedObject var editor: EditorModel

    private enum Lane: CaseIterable { case video, zoom, text, blur, window, camera, mic, music, sfx
        var height: CGFloat { self == .video ? videoH : laneH }
        var icon: String {
            switch self {
            case .video: return "film"
            case .zoom: return "plus.magnifyingglass"
            case .text: return "textformat"
            case .blur: return "drop.halffull"
            case .window: return "macwindow"
            case .camera: return "web.camera"
            case .mic: return "mic"
            case .music: return "music.note"
            case .sfx: return "speaker.wave.2"
            }
        }
        var help: String {
            switch self {
            case .video: return "Видео"
            case .zoom: return "Зум"
            case .text: return "Текст"
            case .blur: return "Блюр: скрыть часть кадра"
            case .window: return "Окна"
            case .camera: return "Камера"
            case .mic: return "Микрофон"
            case .music: return "Музыка"
            case .sfx: return "Звуковые эффекты"
            }
        }
    }

    private var lanesShown: [Lane] { Lane.allCases.filter { ($0 != .camera || editor.hasCamera) && ($0 != .window || editor.hasWindows) && ($0 != .mic || editor.hasMic) } }
    private func top(_ l: Lane) -> CGFloat {
        var y = rulerH + laneGap
        for x in lanesShown { if x == l { return y }; y += x.height + laneGap }
        return y
    }
    private var totalH: CGFloat {
        rulerH + laneGap + lanesShown.reduce(0) { $0 + $1.height + laneGap } + 2
    }

    var body: some View {
        HStack(spacing: 0) {
            gutter
            GeometryReader { geo in
                lanes(width: geo.size.width)
                    .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
                    .clipped()
                    .onAppear { editor.timelineWidthChanged(geo.size.width) }
                    .onChange(of: geo.size.width) { _, w in editor.timelineWidthChanged(w) }
            }
        }
        .frame(height: totalH)
        .background(Color.black.opacity(0.25))
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            guard let p = providers.first else { return false }
            _ = p.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                DispatchQueue.main.async { AppState.shared.handleDroppedFile(url) }
            }
            return true
        }
    }

    private var gutter: some View {
        VStack(spacing: laneGap) {
            Color.clear.frame(height: rulerH)
            ForEach(lanesShown, id: \.self) { l in
                Image(systemName: l.icon).font(.system(size: 11)).foregroundColor(Theme.textDim)
                    .frame(width: gutterW, height: l.height).help(l.help)
            }
            Spacer(minLength: 0)
        }
        .frame(width: gutterW)
        .background(Color.white.opacity(0.03))
    }

    private func x(_ t: Double) -> CGFloat { CGFloat(t * editor.pps - editor.scrollX) }
    private func time(_ px: CGFloat) -> Double { (Double(px) + editor.scrollX) / editor.pps }

    private func lanes(width: CGFloat) -> some View {
        let vTop = top(.video), zTop = top(.zoom), tTop = top(.text)
        let bTop = top(.blur), micTop = top(.mic)
        let wTop = top(.window), cTop = top(.camera), mTop = top(.music), sTop = top(.sfx)
        return ZStack(alignment: .topLeading) {
            ScrollCatcher(onPan: { dx in
                editor.scrollX -= dx
                editor.clampScroll()
            }, onZoom: { f, ax in
                let anchor = (Double(ax) + editor.scrollX) / editor.pps
                editor.setZoom(editor.pps * f, anchorTime: anchor)
            })

            Rectangle().fill(Color.white.opacity(0.001))
                .frame(width: width, height: totalH)
                .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("tl"))
                    .onChanged { v in
                        if v.startLocation.y < rulerH + laneGap { scrub(v.location.x) }
                    }
                    .onEnded { v in
                        if v.startLocation.y < rulerH + laneGap { endScrub() }
                        else if abs(v.translation.width) < 3 {
                            editor.selection = nil
                            editor.seek(to: time(v.location.x))
                        }
                    })
                .simultaneousGesture(SpatialTapGesture(count: 2, coordinateSpace: .named("tl")).onEnded { v in
                    let t = time(v.location.x)
                    let y = v.location.y
                    if y >= zTop && y < zTop + zoomH { editor.seek(to: t); editor.addZoom() }
                    else if y >= tTop && y < tTop + textH { editor.seek(to: t); editor.addText() }
                    else if y >= bTop && y < bTop + laneH { editor.seek(to: t); editor.addBlur() }
                    else if editor.hasWindows && y >= wTop && y < wTop + laneH { editor.seek(to: t); editor.addWindowAtPlayhead() }
                    else if editor.hasCamera && y >= cTop && y < cTop + laneH { editor.addCameraKeyframe(at: t) }
                })

            RulerView(editor: editor)
                .frame(width: width, height: rulerH)
                .allowsHitTesting(false)

            ForEach(lanesShown, id: \.self) { l in
                laneBG.frame(width: width, height: l.height).offset(y: top(l)).allowsHitTesting(false)
            }

            ForEach(editor.layout) { l in
                SegmentBlock(editor: editor, l: l, viewW: width).offset(y: vTop)
            }
            ForEach(editor.visibleAutoZooms) { z in
                ZoomBlock(editor: editor, id: z.id, start: z.start, end: z.end, scale: z.scale, kind: .auto, viewW: width)
                    .offset(y: zTop)
            }
            ForEach(editor.project.zoomRegions) { z in
                ZoomBlock(editor: editor, id: z.id, start: z.start, end: z.end, scale: z.scale, kind: .manual, viewW: width)
                    .offset(y: zTop)
            }
            if editor.project.zoomRegions.isEmpty && editor.visibleAutoZooms.isEmpty {
                hint("Двойной клик или «+ Зум», чтобы добавить", y: zTop)
            }
            ForEach(editor.project.texts) { t in
                TextBlock(editor: editor, t: t, viewW: width).offset(y: tTop)
            }
            if editor.project.texts.isEmpty { hint("Двойной клик или «+ Текст», чтобы добавить", y: tTop) }

            ForEach(editor.project.blurs) { b in
                BlurBlock(editor: editor, b: b, viewW: width).offset(y: bTop)
            }
            if editor.project.blurs.isEmpty { hint("Двойной клик или «Блюр» (B) — скрыть часть кадра", y: bTop) }

            if editor.hasWindows {
                ForEach(editor.project.windowCutouts) { w in
                    WindowBlock(editor: editor, w: w, viewW: width).offset(y: wTop)
                }
                if editor.project.windowCutouts.isEmpty { hint("Двойной клик или «+ Окно» — показать только одно окно", y: wTop) }
            }

            if editor.hasCamera {
                CameraLane(editor: editor, viewW: width).offset(y: cTop)
                if editor.project.camera.keyframes.isEmpty { hint("Двойной клик — добавить ключевой кадр камеры", y: cTop) }
            }
            if editor.hasMic {
                MicLane(editor: editor, viewW: width).offset(y: micTop).allowsHitTesting(false)
            }
            ForEach(editor.project.audioClips) { c in
                AudioBlock(editor: editor, clip: c, viewW: width).offset(y: c.isMusic ? mTop : sTop)
            }
            if !editor.project.audioClips.contains(where: { $0.isMusic }) { hint("Музыка: перетащите аудиофайл сюда", y: mTop) }
            if !editor.project.audioClips.contains(where: { !$0.isMusic }) { hint("Звуковые эффекты", y: sTop) }

            PlayheadView(x: x(editor.playhead), height: totalH)
                .allowsHitTesting(false)
        }
        .coordinateSpace(name: "tl")
    }

    private func hint(_ s: String, y: CGFloat) -> some View {
        Text(s).font(.system(size: 10.5)).foregroundColor(Theme.textDim.opacity(0.7))
            .offset(x: 10, y: y + 5).allowsHitTesting(false)
    }

    private var laneBG: some View {
        Rectangle().fill(Color.white.opacity(0.035))
    }

    private func scrub(_ px: CGFloat) {
        if !editor.isScrubbing {
            editor.isScrubbing = true
            editor.player.pause()
        }
        editor.seek(to: time(px), precise: false)
    }
    private func endScrub() {
        if editor.isScrubbing {
            editor.isScrubbing = false
            editor.seek(to: editor.playhead, precise: true)
        }
    }
}

private struct PlayheadView: View {
    let x: CGFloat
    let height: CGFloat
    var body: some View {
        ZStack(alignment: .topLeading) {
            Rectangle().fill(Color.white).frame(width: 1.5, height: height - 6).offset(x: x - 0.75, y: 6)
            Path { p in
                p.move(to: CGPoint(x: x - 6, y: 0)); p.addLine(to: CGPoint(x: x + 6, y: 0))
                p.addLine(to: CGPoint(x: x + 6, y: 8)); p.addLine(to: CGPoint(x: x, y: 15)); p.addLine(to: CGPoint(x: x - 6, y: 8))
                p.closeSubpath()
            }.fill(Color.white)
        }
        .opacity(x > -10 ? 1 : 0)
    }
}

// MARK: Ruler

private struct RulerView: View {
    @ObservedObject var editor: EditorModel

    var body: some View {
        Canvas { ctx, size in
            let pps = editor.pps, sx = editor.scrollX
            let steps: [Double] = [0.05, 0.1, 0.2, 0.5, 1, 2, 5, 10, 15, 30, 60, 120, 300, 600, 1800]
            let major = steps.first { $0 * pps >= 80 } ?? 1800
            let minor = major / 5
            let t0 = max(0, sx / pps), t1 = (sx + Double(size.width)) / pps
            var k = Int(floor(t0 / minor))
            var t = Double(k) * minor
            ctx.fill(Path(CGRect(x: 0, y: size.height - 1, width: size.width, height: 1)), with: .color(.white.opacity(0.1)))
            while t <= t1 + minor {
                let px = CGFloat(t * pps - sx)
                let isMajor = k % 5 == 0
                if t <= editor.outputDuration + 0.0001 {
                    let h: CGFloat = isMajor ? 10 : 5
                    ctx.fill(Path(CGRect(x: px, y: size.height - h, width: 1, height: h)), with: .color(.white.opacity(isMajor ? 0.5 : 0.25)))
                    if isMajor {
                        let label = Text(timecode(t + 0.0001, fine: major < 1)).font(.system(size: 10, design: .rounded).monospacedDigit()).foregroundColor(.white.opacity(0.6))
                        ctx.draw(label, at: CGPoint(x: px + 3, y: 8), anchor: .leading)
                    }
                }
                k += 1; t = Double(k) * minor
            }
            for c in editor.clickMarkers {
                let px = CGFloat(c * pps - sx)
                if px < -4 || px > size.width + 4 { continue }
                ctx.fill(Path(ellipseIn: CGRect(x: px - 2.5, y: size.height - 8, width: 5, height: 5)), with: .color(Color(hex: "#34D399")))
            }
        }
    }
}

// MARK: Segment block

private struct SegmentBlock: View {
    @ObservedObject var editor: EditorModel
    let l: SegmentLayout
    let viewW: CGFloat
    @State private var isDragging = false

    var body: some View {
        let x0 = CGFloat(l.outStart * editor.pps - editor.scrollX)
        let w = max(CGFloat((l.outEnd - l.outStart) * editor.pps), 3)
        let visX0 = max(x0, -10), visX1 = min(x0 + w, viewW + 10)
        if visX1 > visX0 {
            let selected = editor.selection == .segment(l.id)
            ZStack(alignment: .topLeading) {
                Filmstrip(editor: editor, l: l, shift: visX0 - x0, width: visX1 - visX0)
                Rectangle().fill(Color.black.opacity(0.18))
                if l.seg.speed != 1 {
                    Text(speedLabel(l.seg.speed))
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .padding(.horizontal, 5).padding(.vertical, 1.5)
                        .background(Capsule().fill(Color.orange))
                        .foregroundColor(.black)
                        .padding(4)
                }
                if l.seg.isMuted {
                    Image(systemName: "speaker.slash.fill").font(.system(size: 10)).foregroundColor(.white)
                        .padding(4).background(Circle().fill(Color.black.opacity(0.6)))
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing).padding(3)
                }
                if w > 70 {
                    Text(timecode(l.outEnd - l.outStart, fine: false))
                        .font(.system(size: 10, weight: .semibold, design: .rounded).monospacedDigit())
                        .padding(.horizontal, 4).background(Capsule().fill(Color.black.opacity(0.55)))
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading).padding(3)
                }
                if x0 >= visX0 - 0.5 { handle(leading: true) }
                if x0 + w <= visX1 + 0.5 { handle(leading: false) }
            }
            .frame(width: visX1 - visX0, height: videoH)
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(selected ? Color.white : Color.white.opacity(0.18), lineWidth: selected ? 2 : 1))
            .contentShape(Rectangle())
            .gesture(SpatialTapGesture(coordinateSpace: .named("tl")).onEnded { v in
                editor.selection = .segment(l.id)
                editor.seek(to: (Double(v.location.x) + editor.scrollX) / editor.pps)
            })
            .offset(x: visX0)
            .contextMenu {
                Button("Разрезать здесь") { editor.split() }
                Button("Дублировать") { editor.selection = .segment(l.id); editor.duplicateSelection() }
                Button(l.seg.isMuted ? "Включить звук" : "Без звука") { editor.toggleMute(l.id) }
                Button("Удалить", role: .destructive) { editor.selection = .segment(l.id); editor.deleteSelection() }
            }
        }
    }

    private func handle(leading: Bool) -> some View {
        Rectangle().fill(Color.white.opacity(0.001))
            .overlay(RoundedRectangle(cornerRadius: 1.5).fill(Color.white.opacity(0.85)).frame(width: 3, height: 22))
            .frame(width: 12, height: videoH)
            .frame(maxWidth: .infinity, alignment: leading ? .leading : .trailing)
            .onHover { inside in if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() } }
            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .named("tl"))
                .onChanged { v in
                    if !isDragging { editor.beginGesture(); isDragging = true; editor.selection = .segment(l.id) }
                    editor.trimSegment(id: l.id, leading: leading, dt: Double(v.translation.width) / editor.pps)
                }
                .onEnded { _ in editor.endGesture(); isDragging = false })
    }
}

func speedLabel(_ s: Double) -> String {
    let r = (s * 100).rounded() / 100
    return r == r.rounded() ? String(format: "%.0f×", r) : String(format: "%g×", r)
}

private struct Filmstrip: View {
    @ObservedObject var editor: EditorModel
    let l: SegmentLayout
    let shift: CGFloat
    let width: CGFloat

    var body: some View {
        Canvas { ctx, size in
            let thumbs = editor.thumbnails
            guard !thumbs.isEmpty else {
                ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(hex: "#23233A")))
                return
            }
            let aspect = CGFloat(editor.session.meta.width) / CGFloat(max(editor.session.meta.height, 1))
            let tileW = max(videoH * aspect, 24)
            let dur = editor.sourceDuration
            var idxTile = Int(shift / tileW)
            var px = CGFloat(idxTile) * tileW - shift
            while px < size.width {
                let localX = CGFloat(idxTile) * tileW + tileW / 2
                let outT = min(Double(localX) / editor.pps, l.outEnd - l.outStart)
                let src = l.seg.sourceStart + outT * l.seg.speed
                let i = min(max(Int(src / dur * Double(thumbs.count)), 0), thumbs.count - 1)
                ctx.draw(Image(decorative: thumbs[i], scale: 1), in: CGRect(x: px, y: 0, width: tileW + 0.5, height: videoH))
                px += tileW; idxTile += 1
            }
        }
        .frame(width: width, height: videoH)
    }
}

// MARK: Zoom / Text blocks

private struct ZoomBlock: View {
    enum Kind { case manual, auto }
    @ObservedObject var editor: EditorModel
    let id: UUID
    let start: Double, end: Double
    let scale: Double
    let kind: Kind
    let viewW: CGFloat
    @State private var dragging = false
    @State private var adopted = false

    var body: some View {
        let x0 = CGFloat(start * editor.pps - editor.scrollX)
        let w = max(CGFloat((end - start) * editor.pps), 4)
        let visX0 = max(x0, -10), visX1 = min(x0 + w, viewW + 10)
        if visX1 > visX0 {
            let isAuto = kind == .auto
            let selected = editor.selection == (isAuto ? .autoZoom(id) : .zoom(id))
            ZStack {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(zoomColor.opacity(isAuto ? 0.18 : 0.85))
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(selected ? Color.white : zoomColor.opacity(isAuto ? 0.7 : 0.0),
                                  style: StrokeStyle(lineWidth: selected ? 2 : 1, dash: isAuto && !selected ? [4, 3] : []))
                HStack(spacing: 3) {
                    Image(systemName: isAuto ? "wand.and.stars" : "plus.magnifyingglass").font(.system(size: 10))
                    if w > 44 { Text(String(format: "%.1f×", scale)).font(.system(size: 10.5, weight: .semibold, design: .rounded)) }
                }
                .foregroundColor(.white.opacity(isAuto ? 0.7 : 1))
                if !isAuto {
                    if x0 >= visX0 - 0.5 { edge(leading: true) }
                    if x0 + w <= visX1 + 0.5 { edge(leading: false) }
                } else {
                    // Auto suggestions show the same handles (dimmed); touching them turns the zoom into an editable one.
                    HStack {
                        RoundedRectangle(cornerRadius: 1).fill(Color.white.opacity(0.5)).frame(width: 2, height: 14)
                        Spacer()
                        RoundedRectangle(cornerRadius: 1).fill(Color.white.opacity(0.5)).frame(width: 2, height: 14)
                    }.padding(.horizontal, 5).allowsHitTesting(false)
                }
            }
            .frame(width: visX1 - visX0, height: zoomH)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 3, coordinateSpace: .named("tl"))
                .onChanged { v in
                    if isAuto {
                        if !adopted { adopted = true; editor.adoptAutoZooms(only: id); editor.inspectorTab = .zoom }
                        return
                    }
                    if !dragging { editor.beginGesture(); dragging = true; editor.selection = .zoom(id) }
                    editor.moveItem(id: id, isZoom: true, dt: Double(v.translation.width) / editor.pps)
                }
                .onEnded { _ in if dragging { editor.endGesture(); dragging = false } })
            .simultaneousGesture(TapGesture().onEnded {
                if isAuto { editor.adoptAutoZooms(only: id); editor.inspectorTab = .zoom; return }
                editor.selection = .zoom(id)
                editor.inspectorTab = .zoom
            })
            .help(isAuto ? "Автозум. Нажмите — он станет ручным, и его можно растягивать и двигать" : "Зум \(String(format: "%.1f", scale))×")
            .offset(x: visX0)
            .contextMenu {
                if isAuto {
                    Button("Сделать ручным") { editor.adoptAutoZooms(only: id) }
                } else {
                    Button("Дублировать") { editor.selection = .zoom(id); editor.duplicateSelection() }
                    Button("Удалить", role: .destructive) { editor.selection = .zoom(id); editor.deleteSelection() }
                }
            }
        }
    }

    private func edge(leading: Bool) -> some View {
        Rectangle().fill(Color.white.opacity(0.001)).frame(width: 12).contentShape(Rectangle())
            .overlay(RoundedRectangle(cornerRadius: 1).fill(Color.white.opacity(0.8)).frame(width: 2, height: 14))
            .frame(maxWidth: .infinity, alignment: leading ? .leading : .trailing)
            .onHover { inside in if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() } }
            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .named("tl"))
                .onChanged { v in
                    if !dragging { editor.beginGesture(); dragging = true; editor.selection = .zoom(id) }
                    editor.resizeItem(id: id, isZoom: true, leading: leading, dt: Double(v.translation.width) / editor.pps)
                }
                .onEnded { _ in editor.endGesture(); dragging = false })
    }
}

private struct TextBlock: View {
    @ObservedObject var editor: EditorModel
    let t: TextOverlay
    let viewW: CGFloat
    @State private var dragging = false

    var body: some View {
        let x0 = CGFloat(t.start * editor.pps - editor.scrollX)
        let w = max(CGFloat((t.end - t.start) * editor.pps), 4)
        let visX0 = max(x0, -10), visX1 = min(x0 + w, viewW + 10)
        if visX1 > visX0 {
            let selected = editor.selection == .text(t.id)
            ZStack {
                RoundedRectangle(cornerRadius: 6, style: .continuous).fill(textColor.opacity(0.85))
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(selected ? Color.white : .clear, lineWidth: 2)
                Text(t.text).font(.system(size: 10.5, weight: .semibold)).lineLimit(1)
                    .foregroundColor(.black.opacity(0.85)).padding(.horizontal, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if x0 >= visX0 - 0.5 { edge(leading: true) }
                if x0 + w <= visX1 + 0.5 { edge(leading: false) }
            }
            .frame(width: visX1 - visX0, height: textH)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 3, coordinateSpace: .named("tl"))
                .onChanged { v in
                    if !dragging { editor.beginGesture(); dragging = true; editor.selection = .text(t.id) }
                    editor.moveItem(id: t.id, isZoom: false, dt: Double(v.translation.width) / editor.pps)
                }
                .onEnded { _ in editor.endGesture(); dragging = false })
            .simultaneousGesture(TapGesture().onEnded { editor.selection = .text(t.id); editor.inspectorTab = .text })
            .offset(x: visX0)
            .contextMenu {
                Button("Дублировать") { editor.selection = .text(t.id); editor.duplicateSelection() }
                Button("Удалить", role: .destructive) { editor.selection = .text(t.id); editor.deleteSelection() }
            }
        }
    }

    private func edge(leading: Bool) -> some View {
        Rectangle().fill(Color.white.opacity(0.001)).frame(width: 12).contentShape(Rectangle())
            .overlay(RoundedRectangle(cornerRadius: 1).fill(Color.black.opacity(0.6)).frame(width: 2, height: 14))
            .frame(maxWidth: .infinity, alignment: leading ? .leading : .trailing)
            .onHover { inside in if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() } }
            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .named("tl"))
                .onChanged { v in
                    if !dragging { editor.beginGesture(); dragging = true; editor.selection = .text(t.id) }
                    editor.resizeItem(id: t.id, isZoom: false, leading: leading, dt: Double(v.translation.width) / editor.pps)
                }
                .onEnded { _ in editor.endGesture(); dragging = false })
    }
}


/// Waveform of the recorded microphone, laid out over the edited timeline (follows cuts and speed).
private struct MicLane: View {
    @ObservedObject var editor: EditorModel
    let viewW: CGFloat

    var body: some View {
        Canvas { ctx, size in
            guard let env = editor.micEnvelope else { return }
            let off = editor.session.meta.micOffset
            let muted = !editor.project.mic.enabled
            for l in editor.layout {
                let x0 = CGFloat(l.outStart * editor.pps - editor.scrollX), x1 = CGFloat(l.outEnd * editor.pps - editor.scrollX)
                if x1 < 0 || x0 > size.width { continue }
                var x = max(x0, 0)
                let end = min(x1, size.width)
                while x < end {
                    let t = l.outStart + Double(x + CGFloat(editor.scrollX) - CGFloat(l.outStart * editor.pps)) / editor.pps
                    let src = l.seg.sourceStart + (t - l.outStart) * l.seg.speed
                    let v = CGFloat(min(env.value(at: src - off), 1))
                    let h = max(1.5, v * size.height * 0.92)
                    ctx.fill(Path(roundedRect: CGRect(x: x, y: (size.height - h) / 2, width: 1.6, height: h), cornerRadius: 0.8),
                             with: .color(Color(hex: "#2DD4BF").opacity(muted || l.seg.isMuted ? 0.25 : 0.85)))
                    x += 2
                }
            }
        }
        .frame(width: viewW, height: laneH)
    }
}

private struct BlurBlock: View {
    @ObservedObject var editor: EditorModel
    let b: BlurRegion
    let viewW: CGFloat
    @State private var dragging = false

    var body: some View {
        let x0 = CGFloat(b.start * editor.pps - editor.scrollX)
        let w = max(CGFloat((b.end - b.start) * editor.pps), 4)
        let visX0 = max(x0, -10), visX1 = min(x0 + w, viewW + 10)
        if visX1 > visX0 {
            let selected = editor.selection == .blur(b.id)
            ZStack {
                RoundedRectangle(cornerRadius: 6, style: .continuous).fill(blurColor.opacity(0.85))
                RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(selected ? Color.white : .clear, lineWidth: 2)
                HStack(spacing: 4) {
                    Image(systemName: "drop.halffull").font(.system(size: 10))
                    if w > 60 { Text(b.kind.title).font(.system(size: 10.5, weight: .semibold)).lineLimit(1) }
                }
                .foregroundColor(.white).padding(.horizontal, 8).frame(maxWidth: .infinity, alignment: .leading)
                if x0 >= visX0 - 0.5 { edge(leading: true) }
                if x0 + w <= visX1 + 0.5 { edge(leading: false) }
            }
            .frame(width: visX1 - visX0, height: laneH)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 3, coordinateSpace: .named("tl"))
                .onChanged { v in
                    if !dragging { editor.beginGesture(); dragging = true; editor.selection = .blur(b.id) }
                    editor.moveBlur(id: b.id, dt: Double(v.translation.width) / editor.pps)
                }
                .onEnded { _ in editor.endGesture(); dragging = false })
            .simultaneousGesture(TapGesture().onEnded {
                editor.selection = .blur(b.id); editor.inspectorTab = .effects
                editor.seek(to: min(max(editor.playhead, b.start + 0.05), b.end - 0.05))
            })
            .offset(x: visX0)
            .contextMenu {
                Button("Дублировать") { editor.selection = .blur(b.id); editor.duplicateSelection() }
                Button("Удалить", role: .destructive) { editor.selection = .blur(b.id); editor.deleteSelection() }
            }
        }
    }

    private func edge(leading: Bool) -> some View {
        Rectangle().fill(Color.white.opacity(0.001)).frame(width: 12).contentShape(Rectangle())
            .overlay(RoundedRectangle(cornerRadius: 1).fill(Color.white.opacity(0.8)).frame(width: 2, height: 14))
            .frame(maxWidth: .infinity, alignment: leading ? .leading : .trailing)
            .onHover { inside in if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() } }
            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .named("tl"))
                .onChanged { v in
                    if !dragging { editor.beginGesture(); dragging = true; editor.selection = .blur(b.id) }
                    editor.resizeBlur(id: b.id, leading: leading, dt: Double(v.translation.width) / editor.pps)
                }
                .onEnded { _ in editor.endGesture(); dragging = false })
    }
}

// MARK: Window block

private struct WindowBlock: View {
    @ObservedObject var editor: EditorModel
    let w: WindowCutout
    let viewW: CGFloat
    @State private var dragging = false

    private var label: String {
        guard let tr = editor.windowTrack(w.windowID) else { return "Окно недоступно" }
        return tr.title.isEmpty ? tr.app : "\(tr.app) · \(tr.title)"
    }

    var body: some View {
        let x0 = CGFloat(w.start * editor.pps - editor.scrollX)
        let wd = max(CGFloat((w.end - w.start) * editor.pps), 4)
        let visX0 = max(x0, -10), visX1 = min(x0 + wd, viewW + 10)
        if visX1 > visX0 {
            let selected = editor.selection == .window(w.id)
            ZStack {
                RoundedRectangle(cornerRadius: 6, style: .continuous).fill(windowColor.opacity(0.85))
                RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(selected ? Color.white : .clear, lineWidth: 2)
                HStack(spacing: 4) {
                    Image(systemName: "macwindow").font(.system(size: 10))
                    if wd > 50 { Text(label).font(.system(size: 10.5, weight: .semibold)).lineLimit(1) }
                }
                .foregroundColor(.black.opacity(0.85)).padding(.horizontal, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
                if x0 >= visX0 - 0.5 { edge(leading: true) }
                if x0 + wd <= visX1 + 0.5 { edge(leading: false) }
            }
            .frame(width: visX1 - visX0, height: laneH)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 3, coordinateSpace: .named("tl"))
                .onChanged { v in
                    if !dragging { editor.beginGesture(); dragging = true; editor.selection = .window(w.id) }
                    editor.moveWindow(id: w.id, dt: Double(v.translation.width) / editor.pps)
                }
                .onEnded { _ in if dragging { editor.endGesture(); dragging = false } })
            .simultaneousGesture(TapGesture().onEnded { editor.selection = .window(w.id); editor.inspectorTab = .window })
            .help(label)
            .offset(x: visX0)
            .contextMenu {
                Button("Дублировать") { editor.selection = .window(w.id); editor.duplicateSelection() }
                Button("Разрезать здесь") { editor.selection = .window(w.id); editor.split() }
                Button("Удалить", role: .destructive) { editor.selection = .window(w.id); editor.deleteSelection() }
            }
        }
    }

    private func edge(leading: Bool) -> some View {
        Rectangle().fill(Color.white.opacity(0.001)).frame(width: 12).contentShape(Rectangle())
            .overlay(RoundedRectangle(cornerRadius: 1).fill(Color.black.opacity(0.6)).frame(width: 2, height: 14))
            .frame(maxWidth: .infinity, alignment: leading ? .leading : .trailing)
            .onHover { inside in if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() } }
            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .named("tl"))
                .onChanged { v in
                    if !dragging { editor.beginGesture(); dragging = true; editor.selection = .window(w.id) }
                    editor.resizeWindow(id: w.id, leading: leading, dt: Double(v.translation.width) / editor.pps)
                }
                .onEnded { _ in editor.endGesture(); dragging = false })
    }
}

// MARK: Camera lane

private struct CameraLane: View {
    @ObservedObject var editor: EditorModel
    let viewW: CGFloat
    private let camColor = Color(hex: "#22D3EE")

    var body: some View {
        let ks = editor.project.camera.keyframes
        ZStack(alignment: .topLeading) {
            Canvas { ctx, size in
                guard ks.count > 1 else { return }
                for i in 0..<(ks.count - 1) {
                    let a = CGFloat(ks[i].t * editor.pps - editor.scrollX), b = CGFloat(ks[i + 1].t * editor.pps - editor.scrollX)
                    ctx.fill(Path(roundedRect: CGRect(x: a, y: laneH / 2 - 3, width: max(b - a, 0), height: 6), cornerRadius: 3),
                             with: .color(camColor.opacity(0.35)))
                }
            }
            .frame(width: viewW, height: laneH).allowsHitTesting(false)
            ForEach(ks) { k in KeyDiamond(editor: editor, k: k, color: camColor) }
        }
        .frame(width: viewW, height: laneH, alignment: .topLeading)
    }
}

private struct KeyDiamond: View {
    @ObservedObject var editor: EditorModel
    let k: CameraKeyframe
    let color: Color
    @State private var dragging = false

    var body: some View {
        let px = CGFloat(k.t * editor.pps - editor.scrollX)
        let selected = editor.selection == .camera(k.id)
        if px > -12 && px < editor.timelineWidth + 12 {
            RoundedRectangle(cornerRadius: 3)
                .fill(selected ? Color.white : color)
                .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(Color.black.opacity(0.4), lineWidth: 1))
                .frame(width: 13, height: 13)
                .rotationEffect(.degrees(45))
                .frame(width: 22, height: laneH)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 2, coordinateSpace: .named("tl"))
                    .onChanged { v in
                        if !dragging { editor.beginGesture(); dragging = true; editor.selection = .camera(k.id) }
                        editor.moveCameraKey(id: k.id, dt: Double(v.translation.width) / editor.pps)
                    }
                    .onEnded { _ in if dragging { editor.endGesture(); dragging = false } })
                .simultaneousGesture(TapGesture().onEnded {
                    editor.selection = .camera(k.id); editor.seek(to: k.t); editor.inspectorTab = .camera
                })
                .offset(x: px - 11)
                .contextMenu {
                    Button("Удалить", role: .destructive) { editor.selection = .camera(k.id); editor.deleteSelection() }
                }
                .help("Ключевой кадр камеры · \(timecode(k.t))")
        }
    }
}

// MARK: Audio block

private struct AudioBlock: View {
    @ObservedObject var editor: EditorModel
    let clip: AudioClip
    let viewW: CGFloat
    @State private var dragging = false

    var body: some View {
        let len = editor.clipLength(clip)
        let x0 = CGFloat(clip.outputStart * editor.pps - editor.scrollX)
        let w = max(CGFloat(len * editor.pps), 12)
        let visX0 = max(x0, -10), visX1 = min(x0 + w, viewW + 10)
        if visX1 > visX0 {
            let selected = editor.selection == .audio(clip.id)
            let color = clip.isMusic ? Color(hex: "#10B981") : Color(hex: "#EC4899")
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 6, style: .continuous).fill(color.opacity(clip.isMuted ? 0.25 : 0.55))
                Waveform(editor: editor, clip: clip, len: len, shift: visX0 - x0, width: visX1 - visX0)
                Text(clip.name).font(.system(size: 10, weight: .semibold)).lineLimit(1)
                    .padding(.horizontal, 6).padding(.top, 1).foregroundColor(.white)
                if w >= 30 && x0 >= visX0 - 0.5 { edge(leading: true, w: w) }
                if w >= 30 && x0 + w <= visX1 + 0.5 && !(clip.loopToFitVideo && clip.isMusic) { edge(leading: false, w: w) }
            }
            .frame(width: visX1 - visX0, height: laneH)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(selected ? Color.white : .clear, lineWidth: 2))
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 3, coordinateSpace: .named("tl"))
                .onChanged { v in
                    if !dragging { editor.beginGesture(); dragging = true; editor.selection = .audio(clip.id) }
                    editor.moveAudio(id: clip.id, dt: Double(v.translation.width) / editor.pps)
                }
                .onEnded { _ in if dragging { editor.endGesture(); dragging = false } })
            .simultaneousGesture(TapGesture().onEnded { editor.selection = .audio(clip.id); editor.inspectorTab = .audio })
            .offset(x: visX0)
            .contextMenu {
                Button("Разрезать на плейхеде") { editor.selection = .audio(clip.id); editor.splitSelectedAudio() }
                Button("Дублировать") { editor.selection = .audio(clip.id); editor.duplicateSelection() }
                Button("Удалить", role: .destructive) { editor.selection = .audio(clip.id); editor.deleteSelection() }
            }
        }
    }

    private func edge(leading: Bool, w: CGFloat) -> some View {
        Rectangle().fill(Color.white.opacity(0.001)).frame(width: min(12, w * 0.25)).contentShape(Rectangle())
            .overlay(RoundedRectangle(cornerRadius: 1).fill(Color.white.opacity(0.8)).frame(width: 2, height: 12))
            .frame(maxWidth: .infinity, alignment: leading ? .leading : .trailing)
            .onHover { inside in if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() } }
            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .named("tl"))
                .onChanged { v in
                    if !dragging { editor.beginGesture(); dragging = true; editor.selection = .audio(clip.id) }
                    editor.trimAudio(id: clip.id, leading: leading, dt: Double(v.translation.width) / editor.pps)
                }
                .onEnded { _ in if dragging { editor.endGesture(); dragging = false } })
    }
}

private struct Waveform: View {
    @ObservedObject var editor: EditorModel
    let clip: AudioClip
    let len: Double
    let shift: CGFloat
    let width: CGFloat

    var body: some View {
        Canvas { ctx, size in
            guard let info = editor.audioInfos[clip.filePath], !info.waveform.isEmpty else { return }
            let wf = info.waveform
            let fileDur = max(info.duration, 0.01)
            let end = clip.sourceEnd ?? fileDur
            let span = max(end - clip.sourceStart, 0.05)
            var path = Path()
            var px: CGFloat = 0
            while px < size.width {
                let t = Double(px + shift) / editor.pps
                if t > len { break }
                var ft = clip.sourceStart + t
                if clip.loopToFitVideo && clip.isMusic { ft = clip.sourceStart + t.truncatingRemainder(dividingBy: span) }
                let bi = min(max(Int(ft / fileDur * Double(wf.count)), 0), wf.count - 1)
                let h = max(CGFloat(wf[bi]) * (size.height - 6), 1)
                path.addRect(CGRect(x: px, y: (size.height - h) / 2 + 2, width: 1.5, height: h))
                px += 2
            }
            ctx.fill(path, with: .color(.white.opacity(0.75)))
        }
        .frame(width: width, height: laneH).allowsHitTesting(false)
    }
}
