import Foundation
import CoreGraphics

/// Helpers for the editor UI. All "display points" are in the captured display's space: origin TOP-LEFT,
/// size = meta.pointWidth x meta.pointHeight (same space as cursor positions and WindowSample frames).
/// "Preview coordinates" are in the preview canvas (origin TOP-LEFT, size `canvas`).
enum WindowQueries {
    private static func display(_ meta: RecordingMetadata) -> CGSize { CGSize(width: meta.pointWidth, height: meta.pointHeight) }

    /// Visible windows at SOURCE time t, sorted front-to-back (smallest z first). Rects are the interpolated frames in
    /// display points, clamped to the display.
    static func windows(at sourceTime: Double, in meta: RecordingMetadata) -> [(track: WindowTrack, rect: CGRect)] {
        var res: [(track: WindowTrack, rect: CGRect, z: Int)] = []
        for tr in meta.windows {
            guard let i = WindowCutoutMath.sampleIndex(tr.samples, at: sourceTime), tr.samples[i].visible,
                  let raw = WindowCutoutMath.rawRect(of: tr, at: sourceTime),
                  let r = WindowCutoutMath.clamp(raw, display: display(meta)) else { continue }
            res.append((tr, r, tr.samples[i].z))
        }
        return res.sorted { $0.z < $1.z }.map { (track: $0.track, rect: $0.rect) }
    }

    /// Frontmost window containing `point` (display points) at SOURCE time t.
    static func topWindow(at sourceTime: Double, point: CGPoint, in meta: RecordingMetadata) -> WindowTrack? {
        windows(at: sourceTime, in: meta).first { $0.rect.contains(point) }?.track
    }

    /// Source-time span in which the window exists: first sample ... first sample with visible == false
    /// (or the recording end).
    static func lifetime(of track: WindowTrack, meta: RecordingMetadata) -> ClosedRange<Double> {
        guard let first = track.samples.first(where: { $0.visible }) else { return 0...0 }
        let end = track.samples.first(where: { !$0.visible && $0.t > first.t })?.t ?? meta.duration
        return first.t...max(first.t, end)
    }

    /// Whole-screen content rect in preview coordinates (top-left origin) for the normal, unzoomed look.
    static func screenRect(project: EditProject, meta: RecordingMetadata, canvas: CGSize) -> CGRect {
        let ci = WindowCutoutMath.contentRect(outSize: canvas, srcSize: CGSize(width: meta.width, height: meta.height),
                                              padding: project.render.padding)
        return CGRect(x: ci.minX, y: canvas.height - ci.maxY, width: ci.width, height: ci.height)
    }

    /// Where a window frame (display points) appears in the PREVIEW while the whole screen is shown (unzoomed):
    /// use for hover/selection highlights. Top-left origin, canvas units.
    static func previewRect(forWindow rect: CGRect, project: EditProject, meta: RecordingMetadata, canvas: CGSize) -> CGRect {
        let s = screenRect(project: project, meta: meta, canvas: canvas)
        let kx = s.width / max(meta.pointWidth, 1), ky = s.height / max(meta.pointHeight, 1)
        return CGRect(x: s.minX + rect.minX * kx, y: s.minY + rect.minY * ky, width: rect.width * kx, height: rect.height * ky)
    }

    /// Where the window sits in the preview while FULLY cut out (aspect kept, centered, `padding` fraction). Top-left origin.
    static func cutoutRect(forWindow rect: CGRect, padding: Double = 0.06, canvas: CGSize) -> CGRect {
        let d = WindowCutoutMath.windowDest(rect: rect, padding: padding, outSize: canvas)
        let w = rect.width * d.scale, h = rect.height * d.scale
        return CGRect(x: d.center.x - w / 2, y: canvas.height - d.center.y - h / 2, width: w, height: h)
    }

    /// Preview point (whole-screen, unzoomed look) -> display points. Clamped to the display.
    static func displayPoint(fromPreview p: CGPoint, project: EditProject, meta: RecordingMetadata, canvas: CGSize) -> CGPoint {
        let s = screenRect(project: project, meta: meta, canvas: canvas)
        let x = (p.x - s.minX) / max(s.width, 1) * meta.pointWidth, y = (p.y - s.minY) / max(s.height, 1) * meta.pointHeight
        return CGPoint(x: min(max(x, 0), meta.pointWidth), y: min(max(y, 0), meta.pointHeight))
    }

    /// Display points -> preview point (whole-screen, unzoomed look).
    static func previewPoint(fromDisplay p: CGPoint, project: EditProject, meta: RecordingMetadata, canvas: CGSize) -> CGPoint {
        let r = previewRect(forWindow: CGRect(origin: p, size: .zero), project: project, meta: meta, canvas: canvas)
        return r.origin
    }
}
