using System.Text.Json;
using Xunit;

namespace MotionRecord.Tests;

/// <summary>
/// Compares the C# port against values produced by the ORIGINAL macOS Swift code
/// (tools/gen_golden.sh -> golden.json). Same inputs, same outputs within 1e-6.
/// </summary>
public class GoldenTests
{
    static readonly JsonElement G = JsonDocument.Parse(File.ReadAllText(Path.Combine(AppContext.BaseDirectory, "golden.json"))).RootElement;
    const double Eps = 1e-6;

    static List<double[]> Rows(string key) =>
        G.GetProperty(key).EnumerateArray().Select(r => r.EnumerateArray().Select(v => v.GetDouble()).ToArray()).ToList();

    static List<CursorSample> Samples() => Rows("samples").Select(r => new CursorSample(r[0], r[1], r[2])).ToList();
    static List<ClickEvent> Clicks() => Rows("clicks").Select(r => new ClickEvent(r[0], r[1], r[2], (int)r[3], r[4] > 0.5)).ToList();

    static void Near(double expected, double actual, string what) =>
        Assert.True(Math.Abs(expected - actual) < Eps, $"{what}: expected {expected}, got {actual}");

    [Fact]
    public void CursorSmoother_MatchesSwift()
    {
        foreach (var c in G.GetProperty("smooth").EnumerateArray())
        {
            var s = c.GetProperty("smoothing").GetDouble();
            var path = CursorSmoother.Smooth(Samples(), Clicks(), 6, s, new Pt(5, 6));
            Assert.Equal(c.GetProperty("count").GetInt32(), path.Xs.Length);
            Near(c.GetProperty("tau").GetDouble(), CursorSmoother.TimeConstant(s), "tau");
            foreach (var r in c.GetProperty("points").EnumerateArray().Select(a => a.EnumerateArray().Select(v => v.GetDouble()).ToArray()))
            {
                var p = path.Position(r[0]);
                Near(r[1], p.X, $"x@{r[0]} s={s}");
                Near(r[2], p.Y, $"y@{r[0]} s={s}");
            }
        }
    }

    [Fact]
    public void CursorSmoother_LandsExactlyOnClicks()
    {
        var path = CursorSmoother.Smooth(Samples(), Clicks(), 6, 1.0, new Pt(0, 0));
        // Only the isolated click (4.5 s): the first two are 0.9 s apart and their snap bumps overlap (same in the Swift original).
        foreach (var c in Clicks().Where(c => c.T > 4))
        {
            var p = path.Position(c.T);
            Assert.True(Math.Abs(p.X - c.X) < 0.5 && Math.Abs(p.Y - c.Y) < 0.5, $"click at {c.T}: {p} vs ({c.X},{c.Y})");
        }
    }

    [Fact]
    public void CursorSmoother_NoSamples_IsEmptyAndFallback()
    {
        var path = CursorSmoother.Smooth(new List<CursorSample>(), new List<ClickEvent>(), 2, 0.5, new Pt(5, 6));
        Assert.True(path.IsEmpty);
        Near(5, path.Position(1).X, "fx"); Near(6, path.Position(1).Y, "fy");
    }

    [Fact]
    public void ClickTimeline_MatchesSwift()
    {
        var ct = new ClickTimeline(Clicks());
        foreach (var r in Rows("pressAmount")) Near(r[1], ct.PressAmount(r[0]), $"press@{r[0]}");
        foreach (var r in Rows("clickScale")) Near(r[1], ct.ClickScale(r[0], 0.78, 0.14), $"scale@{r[0]}");
    }

    static CameraParams Params() => new(new RenderSettings());

    [Fact]
    public void ZoomPeriods_MatchSwift()
    {
        var pers = CameraPlanner.Periods(Clicks(), 1920, 1080, Params());
        var exp = Rows("periods");
        Assert.Equal(exp.Count, pers.Count);
        for (var i = 0; i < exp.Count; i++)
        {
            Near(exp[i][0], pers[i].Start, "start"); Near(exp[i][1], pers[i].HoldEnd, "holdEnd");
            Near(exp[i][2], pers[i].OutEnd, "outEnd"); Near(exp[i][3], pers[i].Focus.X, "fx"); Near(exp[i][4], pers[i].Focus.Y, "fy");
        }
    }

    static List<ZoomPeriod> Planned() =>
        CameraPlanner.Plan(Clicks(), new[] { new ZoomRegion { Start = 3, End = 4, Scale = 2.5, FocusX = 0.3, FocusY = 0.6, FollowCursor = false } },
            1920, 1080, Params(), true);

    [Fact]
    public void ZoomPlan_ManualWinsOverAuto_MatchesSwift()
    {
        var pl = Planned();
        var exp = Rows("planned");
        Assert.Equal(exp.Count, pl.Count);
        for (var i = 0; i < exp.Count; i++)
        {
            Near(exp[i][0], pl[i].Start, "start"); Near(exp[i][1], pl[i].HoldEnd, "holdEnd"); Near(exp[i][2], pl[i].OutEnd, "outEnd");
            Near(exp[i][3], pl[i].Focus.X, "fx"); Near(exp[i][4], pl[i].Focus.Y, "fy");
            Near(exp[i][5], pl[i].Scale, "scale"); Assert.Equal(exp[i][6] > 0.5, pl[i].Manual);
        }
    }

    [Fact]
    public void CameraTrack_MatchesSwift()
    {
        var path = CursorSmoother.Smooth(Samples(), Clicks(), 6, new RenderSettings().CursorSmoothing, new Pt(0, 0));
        var track = CameraPlanner.BuildTrack(CameraPlanner.Periods(Clicks(), 1920, 1080, Params()), t => path.Position(t), 1920, 1080, Params(), 6);
        foreach (var r in Rows("track")) { var s = track.Sample(r[0]); Near(r[1], s.cx, $"cx@{r[0]}"); Near(r[2], s.cy, $"cy@{r[0]}"); Near(r[3], s.z, $"z@{r[0]}"); }
        var track2 = CameraPlanner.BuildTrack(Planned(), t => path.Position(t), 1920, 1080, Params(), 6);
        foreach (var r in Rows("track2")) { var s = track2.Sample(r[0]); Near(r[1], s.cx, $"cx2@{r[0]}"); Near(r[2], s.cy, $"cy2@{r[0]}"); Near(r[3], s.z, $"z2@{r[0]}"); }
    }

    [Fact]
    public void CameraTrack_NoClicks_IsIdentity()
    {
        var t = CameraPlanner.BuildTrack(new List<ZoomPeriod>(), _ => null, 1920, 1080, Params(), 3);
        Assert.True(t.IsIdentity);
    }

    [Fact]
    public void CameraCenter_NeverLeavesFrame()
    {
        var track = CameraPlanner.BuildTrack(CameraPlanner.Periods(Clicks(), 1920, 1080, Params()), _ => new Pt(1900, 1070), 1920, 1080, Params(), 6);
        for (var i = 0; i < track.Z.Length; i++)
        {
            var h = 0.5 / track.Z[i];
            Assert.InRange(track.Cx[i], h - 1e-9, 1 - h + 1e-9);
            Assert.InRange(track.Cy[i], h - 1e-9, 1 - h + 1e-9);
        }
    }

    static EditProject CutProject() => new()
    {
        Segments = { new ClipSegment(0, 2), new ClipSegment(3, 5, 2), new ClipSegment(5, 6, 0.5) }
    };

    [Fact]
    public void TimeConversion_MatchesSwift()
    {
        var p = CutProject();
        Near(G.GetProperty("outDur").GetDouble(), p.OutputDuration(6), "outDur");
        foreach (var r in Rows("sourceForOutput")) Near(r[1], p.SourceTime(r[0], 6), $"src@{r[0]}");
        foreach (var r in Rows("outputForSource"))
        {
            var o = p.OutputTime(r[0], 6);
            if (r[2] > 0.5) { Assert.NotNull(o); Near(r[1], o!.Value, $"out@{r[0]}"); } else Assert.Null(o);
        }
    }

    [Fact]
    public void TimeConversion_RoundTrips()
    {
        var p = CutProject();
        foreach (var s in new[] { 0.3, 1.9, 3.5, 4.9, 5.2 })
            Near(s, p.SourceTime(p.OutputTime(s, 6)!.Value, 6), $"roundtrip {s}");
        Assert.Equal(6, new EditProject().OutputDuration(6));
    }

    [Fact]
    public void Typewriter_MatchesSwift()
    {
        foreach (var r in Rows("typed"))
        {
            var o = new TextOverlay { Start = 0, End = 2, Text = "Hello world", Typewriter = true };
            Assert.Equal((int)r[1], o.TypedCount(r[0]));
            Near(r[2], o.EffectiveTypeSpeed, "speed");
        }
    }
}
