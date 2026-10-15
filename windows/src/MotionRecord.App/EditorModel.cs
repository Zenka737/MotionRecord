namespace MotionRecord.App;

public enum SelKind { None, Segment, Zoom, Text }

/// <summary>Editing state + operations on the project (all times in OUTPUT time unless stated). No UI code.</summary>
public sealed class EditorModel
{
    public string Dir { get; }
    public RecordingMetadata Meta { get; }
    public EditProject Project { get; private set; }
    public SelKind SelKind { get; private set; }
    public Guid SelId { get; private set; }
    public int Version { get; private set; }
    public event Action? Changed;

    readonly List<string> _undo = new();

    public EditorModel(string dir)
    {
        Dir = dir;
        Meta = Json.LoadMeta(dir);
        Project = Json.LoadProject(dir);
    }

    public double OutputDuration => Math.Max(Project.OutputDuration(Meta.Duration), 0.01);

    public void Select(SelKind k, Guid id) { SelKind = k; SelId = id; Changed?.Invoke(); }

    /// <summary>Applies a mutation as one undo step, autosaves project.json and raises Changed.</summary>
    public void Commit(Action<EditProject> mutate)
    {
        _undo.Add(Json.Serialize(Project));
        if (_undo.Count > 100) _undo.RemoveAt(0);
        mutate(Project);
        Touch();
    }

    /// <summary>Live change (slider drag): no undo entry per tick; call <see cref="Checkpoint"/> before the drag.</summary>
    public void Checkpoint() { _undo.Add(Json.Serialize(Project)); if (_undo.Count > 100) _undo.RemoveAt(0); }
    public void Live(Action<EditProject> mutate) { mutate(Project); Touch(); }

    public bool Undo()
    {
        if (_undo.Count == 0) return false;
        Project = Json.Deserialize<EditProject>(_undo[^1]) ?? new EditProject();
        _undo.RemoveAt(_undo.Count - 1);
        Touch();
        return true;
    }

    void Touch()
    {
        Version++;
        try { Json.SaveProject(Dir, Project); } catch { /* disk busy: next edit saves again */ }
        Changed?.Invoke();
    }

    // ---- segments -------------------------------------------------------------------------------------------------
    List<ClipSegment> Materialize() =>
        Project.Segments.Count == 0 ? Project.EffectiveSegments(Meta.Duration) : Project.Segments;

    /// <summary>Splits the segment under the playhead in two.</summary>
    public void SplitAt(double outT)
    {
        var src = Project.SourceTime(outT, Meta.Duration);
        var segs = Materialize();
        var i = segs.FindIndex(s => src > s.SourceStart + 0.05 && src < s.SourceEnd - 0.05);
        if (i < 0) return;
        Commit(p =>
        {
            var list = Materialize().ToList();
            var s = list[i];
            var right = new ClipSegment(src, s.SourceEnd, s.Speed) { IsMuted = s.IsMuted };
            var left = new ClipSegment(s.SourceStart, src, s.Speed) { Id = s.Id, IsMuted = s.IsMuted };
            list[i] = left; list.Insert(i + 1, right);
            p.Segments = list;
        });
    }

    public void DeleteSelected()
    {
        var id = SelId;
        switch (SelKind)
        {
            case SelKind.Segment:
                if (Materialize().Count <= 1) return;
                Commit(p => { p.Segments = Materialize().Where(s => s.Id != id).ToList(); });
                break;
            case SelKind.Zoom: Commit(p => p.ZoomRegions.RemoveAll(z => z.Id == id)); break;
            case SelKind.Text: Commit(p => p.Texts.RemoveAll(t => t.Id == id)); break;
            default: return;
        }
        SelKind = SelKind.None;
        Changed?.Invoke();
    }

    public void SetSpeed(double speed)
    {
        if (SelKind != SelKind.Segment) return;
        var id = SelId;
        Commit(p =>
        {
            var list = Materialize().ToList();
            foreach (var s in list.Where(s => s.Id == id)) s.Speed = Math.Clamp(speed, 0.25, 8);
            p.Segments = list;
        });
    }

    /// <summary>Trim a segment edge in SOURCE time (drag on the timeline).</summary>
    public void TrimSegment(Guid id, double? newStart, double? newEnd)
    {
        Commit(p =>
        {
            var list = Materialize().ToList();
            var s = list.First(x => x.Id == id);
            if (newStart is double a) s.SourceStart = Math.Clamp(a, 0, s.SourceEnd - 0.1);
            if (newEnd is double b) s.SourceEnd = Math.Clamp(b, s.SourceStart + 0.1, Meta.Duration);
            p.Segments = list;
        });
    }

    // ---- zoom / text ----------------------------------------------------------------------------------------------
    public void AddZoom(double outT)
    {
        var dur = OutputDuration;
        var start = Math.Min(outT, Math.Max(0, dur - 1.0));
        var end = Math.Min(dur, start + 2.5);
        // Focus = where the cursor is at that moment (normalized, top-left origin).
        double fx = 0.5, fy = 0.5;
        if (Meta.Cursor.Count > 0 && Meta.PointWidth > 0)
        {
            var path = CursorSmoother.Smooth(Meta.Cursor, Meta.Clicks, Meta.Duration, Project.Render.CursorSmoothing, new Pt(0, 0));
            var c = path.Position(Project.SourceTime(start, Meta.Duration));
            fx = Easing.Clamp01(c.X / Meta.PointWidth); fy = Easing.Clamp01(c.Y / Meta.PointHeight);
        }
        var z = new ZoomRegion { Start = start, End = end, Scale = Project.Render.ZoomScale, FocusX = fx, FocusY = fy };
        Commit(p => p.ZoomRegions.Add(z));
        Select(SelKind.Zoom, z.Id);
    }

    public void AddText(double outT, string text)
    {
        var t = new TextOverlay { Start = outT, End = Math.Min(OutputDuration, outT + 3), Text = text };
        Commit(p => p.Texts.Add(t));
        Select(SelKind.Text, t.Id);
    }

    /// <summary>Move (dStart==dEnd) or trim a zoom/text item on the OUTPUT timeline.</summary>
    public void MoveItem(SelKind kind, Guid id, double newStart, double newEnd)
    {
        var dur = OutputDuration;
        newStart = Math.Clamp(newStart, 0, dur - 0.1);
        newEnd = Math.Clamp(newEnd, newStart + 0.1, dur);
        Commit(p =>
        {
            if (kind == SelKind.Zoom) foreach (var z in p.ZoomRegions.Where(z => z.Id == id)) { z.Start = newStart; z.End = newEnd; }
            if (kind == SelKind.Text) foreach (var t in p.Texts.Where(t => t.Id == id)) { t.Start = newStart; t.End = newEnd; }
        });
    }

    // ---- rendering ------------------------------------------------------------------------------------------------
    FrameRenderer? _renderer; int _rv = -1, _rw, _rh;
    public FrameRenderer Renderer(int w, int h)
    {
        lock (this)
        {
            if (_renderer == null || _rv != Version || _rw != w || _rh != h)
            { _renderer = new FrameRenderer(Meta, Project, w, h); _rv = Version; _rw = w; _rh = h; }
            return _renderer;
        }
    }
}
