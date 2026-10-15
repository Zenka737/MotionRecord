import Foundation
import CoreGraphics
import CoreImage
import CoreText
import ImageIO
import AppKit

func parseHexColor(_ hex: String, fallback: (Double, Double, Double) = (0.3, 0.3, 0.9)) -> (Double, Double, Double) {
    var s = hex.trimmingCharacters(in: .whitespaces)
    if s.hasPrefix("#") { s.removeFirst() }
    guard s.count == 6, let v = UInt32(s, radix: 16) else { return fallback }
    return (Double((v >> 16) & 0xFF) / 255, Double((v >> 8) & 0xFF) / 255, Double(v & 0xFF) / 255)
}

/// Output-time <-> source-time table (pure, cheap).
struct SegmentMap {
    struct Item { var outStart: Double; var outEnd: Double; var srcStart: Double; var speed: Double }
    let items: [Item]
    let total: Double

    init(segments: [ClipSegment]) {
        var acc = 0.0
        var arr: [Item] = []
        for s in segments {
            let sp = max(s.speed, 0.01)
            let d = max(0, s.sourceEnd - s.sourceStart) / sp
            arr.append(Item(outStart: acc, outEnd: acc + d, srcStart: s.sourceStart, speed: sp))
            acc += d
        }
        items = arr; total = acc
    }

    func lookup(output t: Double) -> (src: Double, speed: Double, segSrcStart: Double) {
        for it in items where t < it.outEnd {
            return (it.srcStart + max(0, t - it.outStart) * it.speed, it.speed, it.srcStart)
        }
        if let l = items.last { return (l.srcStart + (l.outEnd - l.outStart) * l.speed, l.speed, l.srcStart) }
        return (0, 1, 0)
    }
}

/// Voice loudness (0...1.15) that drives Mochi, mapped from the OUTPUT timeline.
final class MochiLevels: @unchecked Sendable {
    struct ClipEnv { var clip: AudioClip; var env: AudioEnvelope }
    var mic: AudioEnvelope?
    var micOffset: Double = 0
    var voice: [ClipEnv] = []
    var music: [ClipEnv] = []

    var isEmpty: Bool { mic == nil && voice.isEmpty && music.isEmpty }

    /// `t` = output time, `srcT` = source (recording) time.
    func level(outputT t: Double, srcT: Double) -> Double {
        var v: Float = 0
        if let mic { v = max(v, mic.value(at: srcT - micOffset)) }
        func clipValue(_ c: ClipEnv) -> Float {
            let len = (c.clip.sourceEnd ?? c.env.duration) - c.clip.sourceStart
            guard len > 0.01 else { return 0 }
            var u = t - c.clip.outputStart
            if u < 0 { return 0 }
            if c.clip.loopToFitVideo { u = u.truncatingRemainder(dividingBy: len) } else if u > len { return 0 }
            return c.env.value(at: c.clip.sourceStart + u)
        }
        for c in voice { v = max(v, clipValue(c)) }
        for c in music { v = max(v, clipValue(c)) }
        return Double(v)
    }
}

/// Immutable after init, so it is safe to call `render` concurrently from AVFoundation's handler.
final class FrameCompositor: @unchecked Sendable {
    struct Config {
        var srcSize: CGSize           // ORIENTED source pixel size
        var outSize: CGSize           // output canvas pixel size (even)
        var pointSize: CGSize         // display size in points
        var project: EditProject
        var sourceDuration: Double
        var hasCamera: Bool = false
        var levels: MochiLevels? = nil
    }

    /// Lazily renders (and caches) the text image for a given number of visible characters.
    final class TypedImages: @unchecked Sendable {
        private let lock = NSLock()
        private var cache: [Int: CIImage] = [:]
        private let make: (Int) -> CIImage?
        init(make: @escaping (Int) -> CIImage?) { self.make = make }
        func image(_ k: Int) -> CIImage? {
            lock.lock(); defer { lock.unlock() }
            if let c = cache[k] { return c }
            guard let i = make(k) else { return nil }
            cache[k] = i
            return i
        }
    }

    struct TextItem {
        var overlay: TextOverlay
        var image: CIImage            // positioned in output CI coordinates (full text)
        var typed: TypedImages? = nil
    }

    let ctx: CIContext
    let outRect: CGRect
    let srcW: CGFloat, srcH: CGFloat
    let outSize: CGSize
    let contentRect: CGRect           // integer-aligned, CI coordinates (bottom-left origin)
    let pxPerPointSrc: CGFloat
    let backdrop: CIImage             // static background (+ shadow) or shadow-only for blurredVideo
    let blurredBackground: Bool
    let mask: CIImage
    let sprite: CursorSprite
    /// Recorded real cursor shapes (only used with the default "macArrow" style); changes sorted by time.
    let shapeSprites: [String: CursorSprite]
    let shapeChanges: [CursorChange]
    let camera: CameraTrack
    let cursor: SmoothedCursorPath
    let timeline: ClickTimeline
    let pointSize: CGSize
    let settings: RenderSettings
    let style: EditStyle
    let segmentMap: SegmentMap
    let texts: [TextItem]
    let blurs: [BlurRegion]
    let mochi: MochiOverlay
    let levels: MochiLevels?
    let zoomPeriods: [ZoomPeriod]
    let rippleDuration = 0.6
    let drawCursor: Bool
    let cameraLayer: CameraLayer?
    /// Window cut-outs (only those whose window track exists), plus their smoothed rect paths.
    struct CutoutRuntime { var cutout: WindowCutout; var path: WindowRectPath; var zoom: CameraTrack? = nil }
    private(set) var cutouts: [CutoutRuntime] = []
    let plainBackdrop: CIImage        // background WITHOUT the static screen shadow (used while a cut-out is visible)
    let baseRadiusPx: CGFloat
    let overlayCache = CutoutOverlayCache()

    init(config: Config, session: RecordingSession, ciContext: CIContext) {
        let project = config.project
        let s = project.render
        ctx = ciContext
        settings = s
        style = project.style
        srcW = config.srcSize.width
        srcH = config.srcSize.height
        outSize = config.outSize
        pointSize = config.pointSize
        outRect = CGRect(origin: .zero, size: config.outSize)
        pxPerPointSrc = srcW / max(config.pointSize.width, 1)

        let outW = config.outSize.width, outH = config.outSize.height
        let k = 1 - 2 * min(max(s.padding, 0), 0.3)
        var cw = (outW * k).rounded()
        var ch = (cw * srcH / srcW).rounded()
        if ch > outH * k + 1 { ch = (outH * k).rounded(); cw = (ch * srcW / srcH).rounded() }
        let cx = ((outW - cw) / 2).rounded(), cy = ((outH - ch) / 2).rounded()
        contentRect = CGRect(x: cx, y: cy, width: max(cw, 2), height: max(ch, 2))
        let radius = CGFloat(max(0, s.cornerRadius)) * contentRect.width / max(config.pointSize.width, 1)
        baseRadiusPx = radius

        blurredBackground = project.style.backgroundKind == .blurredVideo
        backdrop = FrameCompositor.makeBackdrop(size: config.outSize, content: contentRect, radius: radius,
                                                settings: s, style: project.style)
        mask = FrameCompositor.makeMask(rect: contentRect, radius: radius)
        var noShadow = s; noShadow.shadow = false
        sprite = CursorSprite.make(settings: s)
        var shapes: [String: CursorSprite] = [:]
        if s.cursorStyle == "macArrow" {
            for d in session.meta.cursorShapes {
                let url = session.directory.appendingPathComponent("cursors/\(d.id).png")
                guard let img = NSImage(contentsOf: url) else { continue }
                img.size = NSSize(width: d.w, height: d.h)
                shapes[d.id] = CursorSprite.make(image: img, hotspot: CGPoint(x: d.hotX, y: d.hotY))
            }
        }
        shapeSprites = shapes
        shapeChanges = shapes.isEmpty ? [] : session.meta.cursorChanges.sorted { $0.t < $1.t }

        let meta = session.meta
        let sd = max(config.sourceDuration, 0.01)
        let dur = max(sd, meta.clicks.last?.t ?? 0, meta.cursor.last?.t ?? 0)
        segmentMap = SegmentMap(segments: project.effectiveSegments(sourceDuration: sd))
        let outDur = max(segmentMap.total, 0.01)

        let fallback = CGPoint(x: config.pointSize.width / 2, y: config.pointSize.height / 2)
        let path = CursorSmoother.smooth(samples: meta.cursor, clicks: meta.clicks, duration: dur,
                                         smoothing: s.cursorSmoothing, fallback: fallback)
        cursor = path
        timeline = ClickTimeline(clicks: meta.clicks)
        drawCursor = project.style.showCursor && !path.isEmpty

        var rts: [CutoutRuntime] = []
        var paths: [Int: WindowRectPath] = [:]
        for c in project.windowCutouts where c.end - c.start > 0.05 {
            if paths[c.windowID] == nil, let tr = meta.windows.first(where: { $0.id == c.windowID }),
               let p = WindowCutoutMath.buildPath(track: tr, display: config.pointSize, duration: dur) { paths[c.windowID] = p }
            if let p = paths[c.windowID] { rts.append(CutoutRuntime(cutout: c, path: p)) }
        }
        plainBackdrop = rts.isEmpty ? backdrop
            : FrameCompositor.makeBackdrop(size: config.outSize, content: contentRect, radius: radius, settings: noShadow, style: project.style)
        let baseRts = rts

        let params = CameraParams(s)
        // Zoom is suppressed inside window cut-outs (periods starting there are dropped; ones already running are blended out).
        let periods = VideoRenderer.zoomPeriods(session: session, project: project, sourceDuration: sd,
                                                pointSize: config.pointSize, includeManual: true).filter { per in
            !rts.contains { per.start >= $0.cutout.start - 0.001 && per.start <= $0.cutout.end }
        }
        zoomPeriods = periods
        let map = segmentMap
        camera = CameraPlanner.buildTrack(periods: periods,
                                          cursorAt: { path.isEmpty ? nil : path.position(at: map.lookup(output: $0).src) },
                                          pointSize: config.pointSize, params: params, duration: outDur)
        texts = FrameCompositor.makeTexts(project.texts, outSize: config.outSize)
        blurs = project.blurs.filter { $0.end - $0.start > 0.02 && $0.w > 0.002 && $0.h > 0.002 }
        mochi = project.mochi
        levels = project.mochi.enabled ? config.levels : nil
        cameraLayer = config.hasCamera && project.camera.enabled ? CameraLayer(settings: project.camera, outSize: config.outSize) : nil
        cutouts = baseRts.map { rt in
            var r = rt
            r.zoom = FrameCompositor.buildCutoutZoom(rt, project: project, meta: meta, map: map, cursor: path,
                                                     display: config.pointSize, params: params, outDur: outDur, sourceDuration: sd)
            return r
        }
    }

    // MARK: Static layers

    static func makeBackdrop(size: CGSize, content: CGRect, radius: CGFloat, settings s: RenderSettings, style: EditStyle) -> CIImage {
        let w = Int(size.width), h = Int(size.height)
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let top = parseHexColor(s.backgroundTop), bot = parseHexColor(s.backgroundBottom, fallback: (0.8, 0.3, 0.9))
        func gradient() {
            let grad = CGGradient(colorsSpace: cs, colors: [
                CGColor(colorSpace: cs, components: [top.0, top.1, top.2, 1])!,
                CGColor(colorSpace: cs, components: [bot.0, bot.1, bot.2, 1])!] as CFArray, locations: [0, 1])!
            ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: CGFloat(h)), end: CGPoint(x: 0, y: 0),
                                   options: [.drawsAfterEndLocation, .drawsBeforeStartLocation])
        }
        switch style.backgroundKind {
        case .gradient: gradient()
        case .solid:
            ctx.setFillColor(CGColor(colorSpace: cs, components: [top.0, top.1, top.2, 1])!)
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        case .image:
            if let p = style.backgroundImagePath, !p.isEmpty,
               let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: p) as CFURL, nil),
               let img = CGImageSourceCreateThumbnailAtIndex(src, max(0, min(CGImageSourceGetPrimaryImageIndex(src), CGImageSourceGetCount(src) - 1)), [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceShouldCacheImmediately: true,
                    kCGImageSourceThumbnailMaxPixelSize: max(w, h)] as CFDictionary) {
                let iw = CGFloat(img.width), ih = CGFloat(img.height)
                let sc = max(CGFloat(w) / iw, CGFloat(h) / ih)
                let r = CGRect(x: (CGFloat(w) - iw * sc) / 2, y: (CGFloat(h) - ih * sc) / 2, width: iw * sc, height: ih * sc)
                ctx.interpolationQuality = .high
                ctx.draw(img, in: r)
            } else { gradient() }
        case .blurredVideo:
            break   // transparent: the per-frame blurred video goes underneath
        }

        if s.shadow { drawShadow(ctx: ctx, cs: cs, content: content, radius: radius, style: style, strength: 1) }
        return CIImage(cgImage: ctx.makeImage()!)
    }

    /// Soft two-layer drop shadow of a rounded rect (CG coordinates of `ctx`).
    static func drawShadow(ctx: CGContext, cs: CGColorSpace, content: CGRect, radius: CGFloat, style: EditStyle, strength: Double) {
        let intensity = min(max(style.shadowIntensity, 0), 1)
        guard intensity > 0.001, strength > 0.001 else { return }
        let inset = content.insetBy(dx: 2, dy: 2)
        let path = CGPath(roundedRect: inset, cornerWidth: max(radius - 2, 0), cornerHeight: max(radius - 2, 0), transform: nil)
        let unit = content.width / 1920
        let gain = intensity * 2 * strength
        for (dy, blur, alpha) in [(-30.0, 90.0, 0.42), (-8.0, 22.0, 0.30)] {
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: dy * unit), blur: blur * unit,
                          color: CGColor(colorSpace: cs, components: [0, 0, 0, min(alpha * gain, 0.95)])!)
            ctx.addPath(path)
            ctx.setFillColor(CGColor(colorSpace: cs, components: [0, 0, 0, 1])!)
            ctx.fillPath()
            ctx.restoreGState()
        }
    }

    static func makeMask(rect: CGRect, radius: CGFloat) -> CIImage {
        let w = Int(rect.width), h = Int(rect.height)
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(colorSpace: cs, components: [1, 1, 1, 1])!)
        let r = min(radius, CGFloat(min(w, h)) / 2)
        ctx.addPath(CGPath(roundedRect: CGRect(x: 0, y: 0, width: w, height: h), cornerWidth: r, cornerHeight: r, transform: nil))
        ctx.fillPath()
        return CIImage(cgImage: ctx.makeImage()!).transformed(by: CGAffineTransform(translationX: rect.minX, y: rect.minY))
    }

    // MARK: Text overlays

    static func makeTexts(_ overlays: [TextOverlay], outSize: CGSize) -> [TextItem] {
        let unit = min(outSize.width, outSize.height) / 1080
        var items: [TextItem] = []
        for o in overlays where !o.text.isEmpty && o.end > o.start {
            let px = max(6, CGFloat(o.fontSize) * unit)
            let font = CTFontCreateWithName("HelveticaNeue-Bold" as CFString, px, nil)
            let col = parseHexColor(o.colorHex, fallback: (1, 1, 1))
            let cs = CGColorSpace(name: CGColorSpace.sRGB)!
            let cgCol = CGColor(colorSpace: cs, components: [col.0, col.1, col.2, 1])!
            let lines = o.text.components(separatedBy: "\n").map { line -> (CTLine, CGFloat) in
                let attr = NSAttributedString(string: line.isEmpty ? " " : line, attributes: [
                    NSAttributedString.Key(kCTFontAttributeName as String): font,
                    NSAttributedString.Key(kCTForegroundColorAttributeName as String): cgCol])
                let l = CTLineCreateWithAttributedString(attr)
                return (l, CGFloat(CTLineGetTypographicBounds(l, nil, nil, nil)))
            }
            let lineH = px * 1.25
            let textW = lines.map { $0.1 }.max() ?? 1
            let textH = lineH * CGFloat(lines.count)
            let padX = o.hasBackground ? px * 0.55 : px * 0.3
            let padY = o.hasBackground ? px * 0.3 : px * 0.2
            let w = Int(ceil(textW + padX * 2)), h = Int(ceil(textH + padY * 2))
            guard w > 0, h > 0, w < 16000, h < 16000 else { continue }
            let ascent = CTFontGetAscent(font)
            let rawLines = o.text.components(separatedBy: "\n")
            var cxp = (CGFloat(o.x) * outSize.width - CGFloat(w) / 2).rounded()
            var cyp = ((1 - CGFloat(o.y)) * outSize.height - CGFloat(h) / 2).rounded()
            cxp = min(max(cxp, 0), max(outSize.width - CGFloat(w), 0))
            cyp = min(max(cyp, 0), max(outSize.height - CGFloat(h), 0))
            let drawn = lines
            let bg = o.hasBackground
            let draw: (Int) -> CIImage? = { limit in
                guard let c = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
                c.setAllowsAntialiasing(true); c.setShouldSmoothFonts(false)
                if bg {
                    c.setFillColor(CGColor(colorSpace: cs, components: [0, 0, 0, 0.58])!)
                    let r = min(px * 0.4, CGFloat(h) / 2)
                    c.addPath(CGPath(roundedRect: CGRect(x: 0, y: 0, width: w, height: h), cornerWidth: r, cornerHeight: r, transform: nil))
                    c.fillPath()
                } else {
                    c.setShadow(offset: CGSize(width: 0, height: -px * 0.04), blur: px * 0.12,
                                color: CGColor(colorSpace: cs, components: [0, 0, 0, 0.6])!)
                }
                var remaining = limit
                for (i, ln) in drawn.enumerated() {
                    let chars = rawLines[i].count
                    let take = min(chars, max(remaining, 0))
                    remaining -= chars + 1
                    if take <= 0 { continue }
                    let line: CTLine
                    if take >= chars { line = ln.0 } else {
                        let prefix = String(rawLines[i].prefix(take))
                        let attr = NSAttributedString(string: prefix, attributes: [
                            NSAttributedString.Key(kCTFontAttributeName as String): font,
                            NSAttributedString.Key(kCTForegroundColorAttributeName as String): cgCol])
                        line = CTLineCreateWithAttributedString(attr)
                    }
                    let baseY = CGFloat(h) - padY - lineH * CGFloat(i) - (lineH - px) / 2 - ascent
                    // Typed text is left-aligned inside the full-text box so letters don't jump around.
                    let x = limit >= o.text.count ? (CGFloat(w) - ln.1) / 2 : (CGFloat(w) - ln.1) / 2
                    c.textPosition = CGPoint(x: x, y: baseY)
                    CTLineDraw(line, c)
                }
                guard let cg = c.makeImage() else { return nil }
                return CIImage(cgImage: cg).transformed(by: CGAffineTransform(translationX: cxp, y: cyp))
            }
            guard let full = draw(Int.max) else { continue }
            items.append(TextItem(overlay: o, image: full, typed: o.typewriter ? TypedImages(make: draw) : nil))
        }
        return items
    }

    // MARK: Per-frame

    @inline(__always) func srcPixel(fromPoint p: CGPoint) -> CGPoint {
        CGPoint(x: p.x / pointSize.width * srcW, y: (1 - p.y / pointSize.height) * srcH)
    }

    func blurredBackdrop(from img: CIImage) -> CIImage {
        let fill = max(outSize.width / srcW, outSize.height / srcH)
        let small: CGFloat = 0.12
        let s0 = fill * small
        var b = img.transformed(by: CGAffineTransform(scaleX: s0, y: s0))
        let ext = b.extent
        b = b.clampedToExtent().applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: max(4, outSize.width * small * 0.035)])
            .cropped(to: ext)
        b = b.applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 1.25, kCIInputBrightnessKey: -0.08])
        let up = 1 / small
        b = b.transformed(by: CGAffineTransform(scaleX: up, y: up))
        let e = b.extent
        b = b.transformed(by: CGAffineTransform(translationX: (outSize.width - e.width) / 2 - e.minX,
                                                y: (outSize.height - e.height) / 2 - e.minY))
        return b.cropped(to: outRect)
    }

    /// The recorded cursor shape (arrow / hand / I-beam ...) active at source time `t`; plain arrow when none was recorded.
    func shapeSprite(at t: Double) -> CursorSprite {
        guard !shapeChanges.isEmpty else { return sprite }
        var lo = 0, hi = shapeChanges.count - 1, found = -1
        while lo <= hi {
            let mid = (lo + hi) / 2
            if shapeChanges[mid].t <= t { found = mid; lo = mid + 1 } else { hi = mid - 1 }
        }
        let id = shapeChanges[max(found, 0)].id
        return shapeSprites[id] ?? sprite
    }

    /// Click ripples + cursor drawn on `img` through `toOut` (display points -> canvas px). `visibility` fades by point.
    func overlayCursor(on base: CIImage, srcT: Double, m: (src: Double, speed: Double, segSrcStart: Double),
                       toOut: (CGPoint) -> CGPoint, outPxPerPoint: CGFloat, visibility: (CGPoint) -> Double) -> CIImage {
        var img = base

        if settings.showClickRipple {
            for c in timeline.downs {
                let age = (srcT - c.t) / m.speed
                if srcT < c.t { break }
                if age > rippleDuration || c.t < m.segSrcStart - 0.001 { continue }
                let u = age / rippleDuration
                let r = (22.0 + 20.0 * Easing.easeOutCubic(u)) * Double(outPxPerPoint) * max(settings.cursorScale, 0.5) / 1.6
                let vis = visibility(CGPoint(x: c.x, y: c.y))
                if vis < 0.004 { continue }
                let alpha = pow(1 - u, 1.4) * 0.9 * vis
                let k = CGFloat(r) / sprite.rippleRadiusPx
                let pos = toOut(CGPoint(x: c.x, y: c.y))
                var rip = sprite.ripple
                    .applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: CGFloat(alpha))])
                rip = rip.transformed(by: CGAffineTransform(translationX: -128, y: -128)
                    .concatenating(CGAffineTransform(scaleX: k, y: k))
                    .concatenating(CGAffineTransform(translationX: pos.x, y: pos.y)))
                img = rip.composited(over: img)
            }
        }

        let curPt = cursor.position(at: srcT)
        let curVis = visibility(curPt)
        if curVis < 0.004 { return img }
        let pos = toOut(curPt)
        let clickK = timeline.clickScale(at: srcT, shrink: settings.clickShrinkScale, duration: settings.clickAnimDuration)
        let scale = CGFloat(max(settings.cursorScale, 0.2)) * CGFloat(clickK)
        let need = outPxPerPoint * scale
        let lvl = shapeSprite(at: srcT).level(forPxPerPoint: need)
        let k = need / lvl.pxPerPoint
        let cur = lvl.image.transformed(by: CGAffineTransform(translationX: -lvl.hotspot.x, y: -lvl.hotspot.y)
            .concatenating(CGAffineTransform(scaleX: k, y: k))
            .concatenating(CGAffineTransform(translationX: pos.x, y: pos.y)))
        var curImg = cur
        if curVis < 0.999 { curImg = cur.applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: CGFloat(curVis))]) }
        return curImg.composited(over: img)
    }

    private func renderScreen(source: CIImage, t: Double) -> CIImage {
        let m = segmentMap.lookup(output: t)
        let srcT = m.src
        if !cutouts.isEmpty {
            let act = WindowCutoutMath.active(cutouts.map { $0.cutout }, at: t)
            if !act.isEmpty { return renderCutout(source: source, t: t, srcT: srcT, m: m, active: act) }
        }
        let cam = camera.sample(at: t)
        let z = CGFloat(cam.z)
        let sx = contentRect.width / srcW * z
        let sy = contentRect.height / srcH * z
        let centerPix = CGPoint(x: CGFloat(cam.cx) * srcW, y: (1 - CGFloat(cam.cy)) * srcH)
        let tx = contentRect.midX - centerPix.x * sx
        let ty = contentRect.midY - centerPix.y * sy

        var base = source
        if base.extent.origin != .zero {
            base = base.transformed(by: CGAffineTransform(translationX: -base.extent.minX, y: -base.extent.minY))
        }
        var img = base
        if abs(sx - 1) > 0.0005 || abs(sy - 1) > 0.0005 {
            let name = sy < 1 ? "CILanczosScaleTransform" : "CIBicubicScaleTransform"
            if let f = CIFilter(name: name) {
                f.setValue(img, forKey: kCIInputImageKey)
                f.setValue(sy, forKey: kCIInputScaleKey)
                f.setValue(sx / sy, forKey: kCIInputAspectRatioKey)
                if let o = f.outputImage { img = o } else { img = img.transformed(by: CGAffineTransform(scaleX: sx, y: sy)) }
            } else {
                img = img.transformed(by: CGAffineTransform(scaleX: sx, y: sy))
            }
        }
        img = img.transformed(by: CGAffineTransform(translationX: tx, y: ty))
        if !blurs.isEmpty {
            let wSx = srcW * sx, hSy = srcH * sy
            img = applyBlurs(img, t: t, anchor: .screen) { b in
                CGRect(x: tx + CGFloat(b.x) * wSx, y: ty + CGFloat(1 - b.y - b.h) * hSy, width: CGFloat(b.w) * wSx, height: CGFloat(b.h) * hSy)
            }
        }

        if drawCursor {
            let toOut: (CGPoint) -> CGPoint = { p in
                let sp = self.srcPixel(fromPoint: p)
                return CGPoint(x: sp.x * sx + tx, y: sp.y * sy + ty)
            }
            img = overlayCursor(on: img, srcT: srcT, m: m, toOut: toOut, outPxPerPoint: pxPerPointSrc * sx, visibility: { _ in 1 })
        }

        let clipped = img.cropped(to: contentRect)
            .applyingFilter("CISourceInCompositing", parameters: [kCIInputBackgroundImageKey: mask])
        var bg = backdrop
        if blurredBackground { bg = backdrop.composited(over: blurredBackdrop(from: base)) }
        return clipped.composited(over: bg)
    }

    // MARK: Blur / pixelate / cover

    /// Fade in / out of a timed effect (0...1).
    @inline(__always) private func fade(_ t: Double, _ start: Double, _ end: Double, _ d: Double = 0.18) -> Double {
        max(0, min(1, (t - start) / d, (end - t) / d))
    }

    /// Applies the blur regions whose anchor == `anchor` on `img`. `rectFor` maps a normalized rect (top-left origin) to CI pixels.
    private func applyBlurs(_ img: CIImage, t: Double, anchor: BlurAnchor, rectFor: (BlurRegion) -> CGRect) -> CIImage {
        var out = img
        let unit = outSize.height / 1080
        for b in blurs where b.anchor == anchor {
            let a = fade(t, b.start, b.end)
            if a <= 0.001 { continue }
            let r = rectFor(b).integral.intersection(out.extent)
            if r.width < 2 || r.height < 2 { continue }
            var filtered: CIImage
            switch b.kind {
            case .blur:
                let radius = (4 + 52 * b.strength) * unit
                filtered = out.clampedToExtent().applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: radius]).cropped(to: r)
            case .pixelate:
                let scale = max(4, (6 + 70 * b.strength) * unit)
                filtered = out.applyingFilter("CIPixellate", parameters: [kCIInputCenterKey: CIVector(x: r.minX, y: r.minY),
                                                                         kCIInputScaleKey: scale]).cropped(to: r)
            case .cover:
                filtered = CIImage(color: CIColor(red: 0.04, green: 0.04, blue: 0.05)).cropped(to: r)
            }
            let radius = CGFloat(b.cornerRadius) * min(r.width, r.height) / 2
            let gen = CIFilter(name: "CIRoundedRectangleGenerator")
            gen?.setValue(CIVector(cgRect: r), forKey: "inputExtent")
            gen?.setValue(radius, forKey: "inputRadius")
            gen?.setValue(CIColor(red: 1, green: 1, blue: 1, alpha: CGFloat(a)), forKey: "inputColor")
            if let mask = gen?.outputImage {
                filtered = filtered.applyingFilter("CISourceInCompositing", parameters: [kCIInputBackgroundImageKey: mask])
            }
            out = filtered.composited(over: out)
        }
        return out
    }

    // MARK: Mochi

    private func drawMochi(over out: CIImage, t: Double) -> CIImage {
        let w = CGFloat(mochi.size) * outSize.height
        guard w >= 8 else { return out }
        // loudness
        var level = 0.0
        if let lv = levels, !lv.isEmpty {
            let srcT = segmentMap.lookup(output: t).src
            level = lv.level(outputT: t, srcT: srcT) * mochi.sensitivity
        }
        level = max(0, min(level, 1.15))
        let bounce = mochi.bounce
        var pose = MochiSprite.Pose()
        pose.level = level
        pose.blink = (t + 0.7).truncatingRemainder(dividingBy: 3.4) < 0.12 && level < 0.2
        pose.look = 0.5 * sin(t * 0.7)
        pose.tilt = 0.035 * sin(t * 1.1) + 0.05 * level * sin(t * 9) * bounce
        let breath = 0.015 * sin(t * 2.2)
        pose.squash = 1 + breath - 0.07 * min(level, 1) * bounce
        guard let sp = MochiSprite.render(pxWidth: w, hat: mochi.hat, dark: mochi.darkBody, mouth: mochi.mouth, pose: pose) else { return out }
        let hop = CGFloat(min(level, 1)) * w * 0.20 * CGFloat(bounce)
        let cx = CGFloat(mochi.x) * outSize.width, cy = (1 - CGFloat(mochi.y)) * outSize.height + hop
        let placed = sp.image.transformed(by: CGAffineTransform(translationX: cx - sp.bodyCenter.x, y: cy - sp.bodyCenter.y))
        return placed.composited(over: out)
    }

    /// Screen-space geometry the editor needs to place boxes over the preview: maps normalized SOURCE coords
    /// (top-left origin) to normalized OUTPUT-frame coords (top-left origin) at output time `t`.
    func screenToFrame(at t: Double) -> (sx: Double, sy: Double, tx: Double, ty: Double) {
        let cam = camera.sample(at: t)
        let z = CGFloat(cam.z)
        let sx = contentRect.width / srcW * z, sy = contentRect.height / srcH * z
        let centerPix = CGPoint(x: CGFloat(cam.cx) * srcW, y: (1 - CGFloat(cam.cy)) * srcH)
        let txp = contentRect.midX - centerPix.x * sx, typ = contentRect.midY - centerPix.y * sy
        // normalized source (u, v top-left) -> normalized output: X = sx*u + tx ; Y = sy*v + ty
        let H = outSize.height, W = outSize.width
        return (Double(srcW * sx / W), Double(srcH * sy / H), Double(txp / W), Double((H - srcH * sy - typ) / H))
    }

    /// `t` is OUTPUT (composition) time. `source` = oriented screen frame, `camera` = oriented webcam frame.
    func render(source: CIImage, camera camImage: CIImage? = nil, t: Double) -> CIImage {
        var camOut: (layer: CIImage, full: Bool)?
        if let cl = cameraLayer, let ci = camImage { camOut = cl.render(camera: ci, t: t) }
        var out: CIImage
        if let co = camOut, co.full {
            out = co.layer.composited(over: CIImage(color: .black).cropped(to: outRect))
        } else {
            out = renderScreen(source: source, t: t)
            if !blurs.isEmpty {
                let W = outSize.width, H = outSize.height
                out = applyBlurs(out, t: t, anchor: .frame) { b in
                    CGRect(x: CGFloat(b.x) * W, y: CGFloat(1 - b.y - b.h) * H, width: CGFloat(b.w) * W, height: CGFloat(b.h) * H)
                }
            }
            if let co = camOut { out = co.layer.composited(over: out) }
        }
        if mochi.enabled { out = drawMochi(over: out, t: t) }
        for item in texts {
            let o = item.overlay
            let fade = min(0.45, max(0.2, (o.end - o.start) / 4))
            let a = min(1, (t - o.start) / fade, (o.end - t) / fade)
            if a <= 0 { continue }
            var ti = item.image
            if let typed = item.typed {
                guard let img = typed.image(o.typedCount(at: t)) else { continue }
                ti = img
            }
            if a < 0.999 {
                ti = ti.applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: CGFloat(a))])
            }
            out = ti.composited(over: out)
        }
        return out.cropped(to: outRect)
    }
}
