using System.Globalization;
using System.Windows;
using System.Windows.Input;
using System.Windows.Media;

namespace MotionRecord.App;

/// <summary>Three-lane timeline in OUTPUT time: video segments, zoom regions (auto zooms shown dimmed), texts.</summary>
public sealed class TimelineControl : FrameworkElement
{
    public EditorModel? Model { get; set; }
    public double Playhead { get; set; }
    public event Action<double>? Seek;

    const double LaneH = 34, Gap = 6, RulerH = 22, Handle = 7;
    static readonly Brush BgBrush = new SolidColorBrush(Color.FromRgb(26, 26, 32));
    static readonly Brush SegBrush = new SolidColorBrush(Color.FromRgb(58, 110, 220));
    static readonly Brush ZoomBrush = new SolidColorBrush(Color.FromRgb(139, 92, 246));
    static readonly Brush AutoBrush = new SolidColorBrush(Color.FromArgb(90, 139, 92, 246));
    static readonly Brush TextBrush = new SolidColorBrush(Color.FromRgb(214, 158, 46));
    static readonly Pen SelPen = new(Brushes.White, 2);
    static readonly Typeface Face = new("Segoe UI");

    enum Drag { None, Scrub, Move, TrimL, TrimR }
    Drag _drag; SelKind _dKind; Guid _dId; double _dStartT, _dItemStart, _dItemEnd, _dGrabOffset;

    public TimelineControl() { Height = RulerH + 3 * (LaneH + Gap) + 6; ClipToBounds = true; Focusable = true; }

    double Dur => Model?.OutputDuration ?? 1;
    double X(double t) => t / Dur * ActualWidth;
    double T(double x) => Math.Clamp(x / Math.Max(ActualWidth, 1) * Dur, 0, Dur);
    static double LaneY(int lane) => RulerH + lane * (LaneH + Gap);

    record Block(SelKind Kind, Guid Id, int Lane, double Start, double End, string Label, Brush Fill, bool Auto = false);

    IEnumerable<Block> Blocks()
    {
        if (Model == null) yield break;
        var p = Model.Project;
        double acc = 0;
        foreach (var s in p.EffectiveSegments(Model.Meta.Duration))
        {
            var d = (s.SourceEnd - s.SourceStart) / Math.Max(s.Speed, 0.01);
            yield return new Block(SelKind.Segment, s.Id, 0, acc, acc + d,
                s.Speed == 1 ? $"{s.SourceStart:0.0}–{s.SourceEnd:0.0}" : $"{s.Speed:0.##}×", SegBrush);
            acc += d;
        }
        foreach (var z in p.ZoomRegions) yield return new Block(SelKind.Zoom, z.Id, 1, z.Start, z.End, $"{z.Scale:0.#}×", ZoomBrush);
        foreach (var t in p.Texts) yield return new Block(SelKind.Text, t.Id, 2, t.Start, t.End, t.Text, TextBrush);
    }

    IEnumerable<(double s, double e)> AutoZooms()
    {
        if (Model == null || !Model.Project.Render.AutoZoom) yield break;
        var m = Model.Meta; var p = Model.Project;
        var outClicks = m.Clicks.Select(c => (c, o: p.OutputTime(c.T, m.Duration))).Where(x => x.o != null)
            .Select(x => new ClickEvent(x.o!.Value, x.c.X, x.c.Y, x.c.Button, x.c.IsDown)).ToList();
        foreach (var per in CameraPlanner.Plan(outClicks, p.ZoomRegions, m.PointWidth, m.PointHeight, new CameraParams(p.Render), true).Where(q => !q.Manual))
            yield return (per.Start, per.OutEnd);
    }

    protected override void OnRender(DrawingContext dc)
    {
        var w = ActualWidth;
        dc.DrawRectangle(BgBrush, null, new Rect(0, 0, w, ActualHeight));
        if (Model == null) return;

        // ruler
        var step = Dur > 120 ? 10 : Dur > 40 ? 5 : Dur > 15 ? 2 : 1;
        for (double t = 0; t <= Dur; t += step)
        {
            var x = X(t);
            dc.DrawLine(new Pen(Brushes.Gray, 1), new Point(x, RulerH - 6), new Point(x, RulerH));
            var ft = new FormattedText($"{(int)t / 60}:{(int)t % 60:00}", CultureInfo.InvariantCulture, FlowDirection.LeftToRight,
                Face, 10, Brushes.Gray, 1.0);
            dc.DrawText(ft, new Point(x + 3, 2));
        }
        foreach (var (s, e) in AutoZooms())
            dc.DrawRoundedRectangle(AutoBrush, null, new Rect(X(s), LaneY(1), Math.Max(X(e) - X(s), 2), LaneH), 4, 4);

        foreach (var b in Blocks())
        {
            var r = new Rect(X(b.Start), LaneY(b.Lane), Math.Max(X(b.End) - X(b.Start), 3), LaneH);
            var sel = Model.SelKind == b.Kind && Model.SelId == b.Id;
            dc.DrawRoundedRectangle(b.Fill, sel ? SelPen : new Pen(new SolidColorBrush(Color.FromArgb(120, 0, 0, 0)), 1), r, 5, 5);
            if (r.Width > 36)
            {
                var ft = new FormattedText(b.Label, CultureInfo.InvariantCulture, FlowDirection.LeftToRight, Face, 11, Brushes.White, 1.0)
                { MaxTextWidth = r.Width - 10, MaxTextHeight = LaneH, Trimming = TextTrimming.CharacterEllipsis };
                dc.DrawText(ft, new Point(r.X + 6, r.Y + 9));
            }
        }
        var px = X(Playhead);
        dc.DrawLine(new Pen(Brushes.OrangeRed, 2), new Point(px, 0), new Point(px, ActualHeight));
    }

    Block? HitBlock(Point pt) =>
        Blocks().Reverse().FirstOrDefault(b => pt.Y >= LaneY(b.Lane) && pt.Y <= LaneY(b.Lane) + LaneH && pt.X >= X(b.Start) - 2 && pt.X <= X(b.End) + 2);

    protected override void OnMouseDown(MouseButtonEventArgs e)
    {
        if (Model == null) return;
        Focus(); CaptureMouse();
        var pt = e.GetPosition(this);
        var hit = pt.Y < RulerH ? null : HitBlock(pt);
        if (hit == null)
        {
            _drag = Drag.Scrub;
            if (pt.Y >= RulerH) Model.Select(SelKind.None, Guid.Empty);
            Seek?.Invoke(T(pt.X));
            return;
        }
        Model.Select(hit.Kind, hit.Id);
        _dKind = hit.Kind; _dId = hit.Id; _dStartT = T(pt.X); _dItemStart = hit.Start; _dItemEnd = hit.End;
        _dGrabOffset = T(pt.X) - hit.Start;
        var wpx = X(hit.End) - X(hit.Start);
        _drag = wpx > Handle * 3 && pt.X < X(hit.Start) + Handle ? Drag.TrimL
              : wpx > Handle * 3 && pt.X > X(hit.End) - Handle ? Drag.TrimR
              : hit.Kind == SelKind.Segment ? Drag.Scrub : Drag.Move;
        if (_drag == Drag.Scrub) Seek?.Invoke(T(pt.X));
        InvalidateVisual();
    }

    protected override void OnMouseMove(MouseEventArgs e)
    {
        if (Model == null) return;
        var pt = e.GetPosition(this);
        if (_drag == Drag.None)
        {
            var h = pt.Y >= RulerH ? HitBlock(pt) : null;
            Cursor = h == null ? Cursors.Arrow
                : (X(h.End) - X(h.Start) > Handle * 3 && (pt.X < X(h.Start) + Handle || pt.X > X(h.End) - Handle)) ? Cursors.SizeWE : Cursors.Hand;
            return;
        }
        if (e.LeftButton != MouseButtonState.Pressed) return;
        var t = T(pt.X);
        if (_drag == Drag.Scrub) { Seek?.Invoke(t); return; }
        // Live feedback is the preview; the edit itself is committed on mouse-up.
        _pendingStart = _dItemStart; _pendingEnd = _dItemEnd;
        switch (_drag)
        {
            case Drag.Move: var len = _dItemEnd - _dItemStart; _pendingStart = Math.Clamp(t - _dGrabOffset, 0, Dur - len); _pendingEnd = _pendingStart + len; break;
            case Drag.TrimL: _pendingStart = Math.Min(t, _dItemEnd - 0.1); break;
            case Drag.TrimR: _pendingEnd = Math.Max(t, _dItemStart + 0.1); break;
        }
        _moved = true;
        Seek?.Invoke(Math.Clamp(_drag == Drag.TrimR ? _pendingEnd : _pendingStart, 0, Dur));
    }

    double _pendingStart, _pendingEnd; bool _moved;

    protected override void OnMouseUp(MouseButtonEventArgs e)
    {
        ReleaseMouseCapture();
        if (Model != null && _moved && _drag != Drag.Scrub && _drag != Drag.None)
        {
            if (_dKind == SelKind.Segment)
            {
                // Segment trim: convert the edge's OUTPUT time back to SOURCE time.
                var seg = Model.Project.EffectiveSegments(Model.Meta.Duration).First(s => s.Id == _dId);
                if (_drag == Drag.TrimL) Model.TrimSegment(_dId, seg.SourceStart + (_pendingStart - _dItemStart) * seg.Speed, null);
                else if (_drag == Drag.TrimR) Model.TrimSegment(_dId, null, seg.SourceEnd + (_pendingEnd - _dItemEnd) * seg.Speed);
            }
            else Model.MoveItem(_dKind, _dId, _pendingStart, _pendingEnd);
        }
        _drag = Drag.None; _moved = false;
        InvalidateVisual();
    }
}
