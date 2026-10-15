namespace MotionRecord;

public sealed class ClipSegment
{
    public Guid Id { get; set; } = Guid.NewGuid();
    public double SourceStart { get; set; }
    public double SourceEnd { get; set; }
    /// <summary>0.25 ... 8. Output duration = (end - start) / speed.</summary>
    public double Speed { get; set; } = 1.0;
    public bool IsMuted { get; set; }
    public ClipSegment() { }
    public ClipSegment(double start, double end, double speed = 1.0) { SourceStart = start; SourceEnd = end; Speed = speed; }
}

/// <summary>Manual zoom region on the OUTPUT timeline.</summary>
public sealed class ZoomRegion
{
    public Guid Id { get; set; } = Guid.NewGuid();
    public double Start { get; set; }
    public double End { get; set; }
    public double Scale { get; set; } = 2.0;
    public double FocusX { get; set; } = 0.5;
    public double FocusY { get; set; } = 0.5;
    public bool FollowCursor { get; set; } = true;
}

public sealed class TextOverlay
{
    public const double TypeLead = 0.15;
    public Guid Id { get; set; } = Guid.NewGuid();
    public double Start { get; set; }
    public double End { get; set; }
    public string Text { get; set; } = "";
    public double X { get; set; } = 0.5;
    public double Y { get; set; } = 0.85;
    public double FontSize { get; set; } = 48;
    public string ColorHex { get; set; } = "#FFFFFF";
    public bool HasBackground { get; set; } = true;
    public bool Typewriter { get; set; }
    public double TypeSpeed { get; set; } = 16;
    public bool TypeSound { get; set; }

    public double EffectiveTypeSpeed
    {
        get
        {
            var avail = Math.Max(End - Start - TypeLead - 0.4, 0.2);
            return Math.Max(TypeSpeed, Text.Length / avail);
        }
    }

    public int TypedCount(double t)
    {
        if (!Typewriter) return Text.Length;
        var k = (int)Math.Floor((t - Start - TypeLead) * EffectiveTypeSpeed) + 1;
        return Math.Min(Math.Max(k, 0), Text.Length);
    }
}

public enum AspectPreset { original, landscape16x9, vertical9x16, square1x1, portrait4x5, standard4x3 }
public enum BackgroundKind { gradient, solid, image, blurredVideo }
public enum ExportFormat { mp4HEVC, mp4H264, mov, gif }

public static class AspectExt
{
    public static double? Ratio(this AspectPreset a) => a switch
    {
        AspectPreset.original => null,
        AspectPreset.landscape16x9 => 16.0 / 9,
        AspectPreset.vertical9x16 => 9.0 / 16,
        AspectPreset.square1x1 => 1.0,
        AspectPreset.portrait4x5 => 4.0 / 5,
        AspectPreset.standard4x3 => 4.0 / 3,
        _ => null,
    };
}

public sealed class EditStyle
{
    public AspectPreset Aspect { get; set; } = AspectPreset.landscape16x9;
    public BackgroundKind BackgroundKind { get; set; } = BackgroundKind.gradient;
    public string? BackgroundImagePath { get; set; }
    public double ShadowIntensity { get; set; } = 0.5;
    public bool ShowCursor { get; set; } = true;
    public bool CutoutScreenBackdrop { get; set; }
}

/// <summary>
/// Project file (project.json). Only the fields the Windows MVP edits are typed; fields it does not know
/// (camera, audio, mochi, windowCutouts, blurs, ... written by macOS) are preserved verbatim in <see cref="Extra"/>
/// so opening and saving never loses data.
/// </summary>
public sealed class EditProject
{
    public RenderSettings Render { get; set; } = new();
    public EditStyle Style { get; set; } = new();
    public List<ClipSegment> Segments { get; set; } = new();
    public List<ZoomRegion> ZoomRegions { get; set; } = new();
    public List<TextOverlay> Texts { get; set; } = new();
    public double OriginalVolume { get; set; } = 1.0;
    public ExportFormat ExportFormat { get; set; } = ExportFormat.mp4HEVC;

    [System.Text.Json.Serialization.JsonExtensionData]
    public Dictionary<string, System.Text.Json.JsonElement>? Extra { get; set; }

    public List<ClipSegment> EffectiveSegments(double sourceDuration) =>
        Segments.Count == 0 ? new List<ClipSegment> { new(0, sourceDuration) } : Segments;

    public double OutputDuration(double sourceDuration) =>
        EffectiveSegments(sourceDuration).Sum(s => (s.SourceEnd - s.SourceStart) / Math.Max(s.Speed, 0.01));

    /// <summary>output time -> source time</summary>
    public double SourceTime(double outputT, double sourceDuration)
    {
        double acc = 0;
        var segs = EffectiveSegments(sourceDuration);
        foreach (var s in segs)
        {
            var d = (s.SourceEnd - s.SourceStart) / Math.Max(s.Speed, 0.01);
            if (outputT < acc + d) return s.SourceStart + (outputT - acc) * s.Speed;
            acc += d;
        }
        return segs.Count > 0 ? segs[^1].SourceEnd : 0;
    }

    /// <summary>source time -> output time (null if that source time was cut out)</summary>
    public double? OutputTime(double sourceT, double sourceDuration)
    {
        double acc = 0;
        foreach (var s in EffectiveSegments(sourceDuration))
        {
            if (sourceT >= s.SourceStart && sourceT <= s.SourceEnd)
                return acc + (sourceT - s.SourceStart) / Math.Max(s.Speed, 0.01);
            acc += (s.SourceEnd - s.SourceStart) / Math.Max(s.Speed, 0.01);
        }
        return null;
    }
}
