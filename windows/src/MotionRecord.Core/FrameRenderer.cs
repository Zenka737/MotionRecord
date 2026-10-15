using SkiaSharp;

namespace MotionRecord;

/// <summary>
/// Composes one output frame: gradient background, rounded/shadowed screen with auto/manual zoom,
/// smoothed cursor (drawn separately from the video), click ripple and text overlays.
/// Pure drawing on an SKCanvas, so it works for preview and export alike (and runs on any OS).
/// </summary>
public sealed class FrameRenderer
{
    public RecordingMetadata Meta { get; }
    public EditProject Project { get; }
    public int Width { get; }
    public int Height { get; }
    public double OutputDuration { get; }

    readonly SmoothedCursorPath _path;
    readonly ClickTimeline _clicks;
    readonly CameraTrack _track;
    readonly double _scaleToCanvas;

    public FrameRenderer(RecordingMetadata meta, EditProject project, int width, int height)
    {
        Meta = meta; Project = project; Width = width; Height = height;
        var rs = project.Render;
        OutputDuration = Math.Max(project.OutputDuration(meta.Duration), 0.01);
        _scaleToCanvas = height / 1080.0;

        _path = CursorSmoother.Smooth(meta.Cursor, meta.Clicks, meta.Duration, rs.CursorSmoothing,
            new Pt(meta.PointWidth / 2, meta.PointHeight / 2));
        _clicks = new ClickTimeline(meta.Clicks);

        // Auto zoom works in OUTPUT time: convert click times (clicks inside cut-out ranges are dropped).
        var outClicks = new List<ClickEvent>();
        foreach (var c in meta.Clicks)
            if (project.OutputTime(c.T, meta.Duration) is double ot)
                outClicks.Add(new ClickEvent(ot, c.X, c.Y, c.Button, c.IsDown));
        var prm = new CameraParams(rs);
        var periods = CameraPlanner.Plan(outClicks, project.ZoomRegions, meta.PointWidth, meta.PointHeight, prm, rs.AutoZoom);
        _track = CameraPlanner.BuildTrack(periods,
            ot => _path.IsEmpty ? null : _path.Position(project.SourceTime(ot, meta.Duration)),
            meta.PointWidth, meta.PointHeight, prm, OutputDuration);
    }

    /// <summary>Output size for the project's aspect/height settings (always even numbers).</summary>
    public static (int w, int h) OutputSize(RecordingMetadata meta, EditProject project)
    {
        var h = project.Render.OutputHeight > 0 ? project.Render.OutputHeight : meta.Height;
        var ratio = project.Style.Aspect.Ratio() ?? (double)meta.Width / Math.Max(meta.Height, 1);
        var w = (int)Math.Round(h * ratio);
        return (Math.Max(2, w & ~1), Math.Max(2, h & ~1));
    }

    public double SourceTime(double outputT) => Project.SourceTime(outputT, Meta.Duration);

    public void Render(SKCanvas canvas, SKBitmap? source, double outputT)
    {
        var rs = Project.Render;
        DrawBackground(canvas, rs);

        // Where the screen sits on the canvas.
        var pad = rs.Padding * Width;
        var availW = Width - 2 * pad; var availH = Height - 2 * pad;
        var srcAspect = (double)Meta.Width / Math.Max(Meta.Height, 1);
        double dw = availW, dh = availW / srcAspect;
        if (dh > availH) { dh = availH; dw = availH * srcAspect; }
        var dx = (Width - dw) / 2; var dy = (Height - dh) / 2;
        var dest = new SKRect((float)dx, (float)dy, (float)(dx + dw), (float)(dy + dh));
        var radius = (float)(rs.CornerRadius * _scaleToCanvas);

        var (cx, cy, z) = _track.Sample(outputT);
        // visible region of the source in normalized coordinates
        var vw = 1.0 / z; var vh = 1.0 / z;
        var vx = cx - vw / 2; var vy = cy - vh / 2;

        if (rs.Shadow)
        {
            using var sp = new SKPaint
            {
                Color = new SKColor(0, 0, 0, (byte)Math.Min(255, 220 * Project.Style.ShadowIntensity)),
                IsAntialias = true,
                MaskFilter = SKMaskFilter.CreateBlur(SKBlurStyle.Normal, (float)(28 * _scaleToCanvas)),
            };
            var sr = dest; sr.Offset(0, (float)(14 * _scaleToCanvas));
            canvas.DrawRoundRect(sr, radius, radius, sp);
        }

        canvas.Save();
        using (var rr = new SKRoundRect(dest, radius, radius)) canvas.ClipRoundRect(rr, SKClipOperation.Intersect, true);
        if (source != null)
        {
            var srect = new SKRect((float)(vx * source.Width), (float)(vy * source.Height),
                                   (float)((vx + vw) * source.Width), (float)((vy + vh) * source.Height));
            using var p = new SKPaint { IsAntialias = true, FilterQuality = SKFilterQuality.High };
            canvas.DrawBitmap(source, srect, dest, p);
        }
        else
        {
            using var p = new SKPaint { Color = new SKColor(20, 20, 24) };
            canvas.DrawRect(dest, p);
        }
        canvas.Restore();

        if (Project.Style.ShowCursor && !_path.IsEmpty) DrawCursor(canvas, outputT, dest, vx, vy, vw, vh, z);
        foreach (var t in Project.Texts) DrawText(canvas, t, outputT);
    }

    void DrawBackground(SKCanvas canvas, RenderSettings rs)
    {
        using var p = new SKPaint { IsAntialias = true };
        if (Project.Style.BackgroundKind == BackgroundKind.solid)
            p.Color = SafeColor(rs.BackgroundTop, new SKColor(30, 30, 40));
        else
            p.Shader = SKShader.CreateLinearGradient(new SKPoint(0, 0), new SKPoint(Width * 0.35f, Height),
                new[] { SafeColor(rs.BackgroundTop, new SKColor(0x5B, 0x3D, 0xF5)), SafeColor(rs.BackgroundBottom, new SKColor(0xD9, 0x46, 0xEF)) },
                null, SKShaderTileMode.Clamp);
        canvas.DrawRect(0, 0, Width, Height, p);
    }

    static SKColor SafeColor(string hex, SKColor fallback) => SKColor.TryParse(hex, out var c) ? c : fallback;

    void DrawCursor(SKCanvas canvas, double outputT, SKRect dest, double vx, double vy, double vw, double vh, double zoom)
    {
        var rs = Project.Render;
        var st = SourceTime(outputT);
        var cp = _path.Position(st);
        var nx = cp.X / Meta.PointWidth; var ny = cp.Y / Meta.PointHeight;
        var px = dest.Left + (nx - vx) / vw * dest.Width;
        var py = dest.Top + (ny - vy) / vh * dest.Height;
        if (px < dest.Left - 40 || px > dest.Right + 40 || py < dest.Top - 40 || py > dest.Bottom + 40) return;

        // Click ripple
        if (rs.ShowClickRipple)
        {
            foreach (var d in _clicks.Downs)
            {
                var age = st - d.T;
                if (age < 0 || age > 0.55) continue;
                var u = Easing.EaseOutCubic(age / 0.55);
                var rx = dest.Left + (d.X / Meta.PointWidth - vx) / vw * dest.Width;
                var ry = dest.Top + (d.Y / Meta.PointHeight - vy) / vh * dest.Height;
                using var rp = new SKPaint
                {
                    IsAntialias = true, Style = SKPaintStyle.Stroke,
                    StrokeWidth = (float)(3 * _scaleToCanvas * (1 - u) + 1),
                    Color = new SKColor(255, 255, 255, (byte)(200 * (1 - u))),
                };
                canvas.DrawCircle((float)rx, (float)ry, (float)((10 + 38 * u) * _scaleToCanvas), rp);
            }
        }

        var scale = rs.CursorScale * _scaleToCanvas * _clicks.ClickScale(st, rs.ClickShrinkScale, rs.ClickAnimDuration);
        DrawArrow(canvas, (float)px, (float)py, (float)scale);
    }

    static void DrawArrow(SKCanvas canvas, float x, float y, float s)
    {
        using var path = new SKPath();
        path.MoveTo(0, 0); path.LineTo(0, 17); path.LineTo(4.2f, 13.2f); path.LineTo(7f, 19.5f);
        path.LineTo(9.4f, 18.5f); path.LineTo(6.7f, 12.3f); path.LineTo(12f, 12.3f); path.Close();
        canvas.Save();
        canvas.Translate(x, y);
        canvas.Scale(s, s);
        using (var shadow = new SKPaint { IsAntialias = true, Color = new SKColor(0, 0, 0, 90),
            MaskFilter = SKMaskFilter.CreateBlur(SKBlurStyle.Normal, 1.6f) })
        { canvas.Translate(1f, 1.5f); canvas.DrawPath(path, shadow); canvas.Translate(-1f, -1.5f); }
        using (var stroke = new SKPaint { IsAntialias = true, Style = SKPaintStyle.Stroke, StrokeWidth = 1.6f,
            StrokeJoin = SKStrokeJoin.Round, Color = SKColors.Black })
            canvas.DrawPath(path, stroke);
        using (var fill = new SKPaint { IsAntialias = true, Color = SKColors.White })
            canvas.DrawPath(path, fill);
        canvas.Restore();
    }

    void DrawText(SKCanvas canvas, TextOverlay o, double t)
    {
        if (t < o.Start || t > o.End || o.Text.Length == 0) return;
        var fade = Math.Min(Easing.Clamp01((t - o.Start) / 0.2), Easing.Clamp01((o.End - t) / 0.2));
        var shown = o.Text.Substring(0, o.TypedCount(t));
        if (shown.Length == 0) return;
        var size = (float)(o.FontSize * _scaleToCanvas);
        using var tf = SKTypeface.FromFamilyName("Segoe UI", SKFontStyle.Bold) ?? SKTypeface.Default;
        using var meas = new SKPaint { Typeface = tf, TextSize = size, IsAntialias = true };
        var full = meas.MeasureText(o.Text);
        var cx = (float)(o.X * Width); var cy = (float)(o.Y * Height);
        var alpha = (byte)(255 * fade);
        if (o.HasBackground)
        {
            using var bg = new SKPaint { IsAntialias = true, Color = new SKColor(0, 0, 0, (byte)(150 * fade)) };
            var padX = size * 0.5f; var padY = size * 0.3f;
            canvas.DrawRoundRect(new SKRect(cx - full / 2 - padX, cy - size * 0.95f - padY + size * 0.2f,
                cx + full / 2 + padX, cy + size * 0.3f + padY), size * 0.3f, size * 0.3f, bg);
        }
        var col = SafeColor(o.ColorHex, SKColors.White).WithAlpha(alpha);
        using var tp = new SKPaint { IsAntialias = true, Color = col, Typeface = tf, TextSize = size };
        canvas.DrawText(shown, cx - full / 2, cy, tp);
    }
}
