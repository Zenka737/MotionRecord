namespace MotionRecord;

public sealed class CameraParams
{
    public double ZoomScale, ZoomDuration, ZoomHold, CameraSmoothing;
    public CameraParams(RenderSettings s)
    {
        ZoomScale = Math.Max(1.0, s.ZoomScale);
        ZoomDuration = Math.Max(0.1, s.ZoomDuration);
        ZoomHold = Math.Max(0.1, s.ZoomHold);
        CameraSmoothing = Easing.Clamp01(s.CameraSmoothing);
    }
}

/// <summary>One continuous zoomed-in period (a cluster of nearby-in-time clicks).</summary>
public sealed class ZoomPeriod
{
    public double Start;     // zoom-in ramp begins
    public double HoldEnd;   // zoom-out ramp begins
    public double OutEnd;    // zoom-out ramp ends
    public Pt Focus;         // normalized (0...1, top-left origin)
    public double Scale;     // 0 = use CameraParams.ZoomScale
    public double Ramp;      // 0 = use CameraParams.ZoomDuration
    public bool Follow = true;
    public bool Manual;
}

/// <summary>Precomputed camera track; cx/cy normalized (top-left origin), clamped to the frame.</summary>
public sealed class CameraTrack
{
    public double Hz { get; }
    public double[] Cx { get; }
    public double[] Cy { get; }
    public double[] Z { get; }
    public CameraTrack(double hz, double[] cx, double[] cy, double[] z) { Hz = hz; Cx = cx; Cy = cy; Z = z; }

    public static CameraTrack Identity => new(1, new[] { 0.5, 0.5 }, new[] { 0.5, 0.5 }, new[] { 1.0, 1.0 });

    public (double cx, double cy, double z) Sample(double t)
    {
        var f = Math.Min(Math.Max(t * Hz, 0), Z.Length - 1);
        var i = Math.Min((int)f, Z.Length - 2);
        var a = f - i;
        return (Cx[i] * (1 - a) + Cx[i + 1] * a, Cy[i] * (1 - a) + Cy[i + 1] * a, Z[i] * (1 - a) + Z[i + 1] * a);
    }

    public bool IsIdentity => Z.All(z => z <= 1.0000001);
}

public static class CameraPlanner
{
    public const double Hz = 240;

    public static double Lead(CameraParams p) => Math.Min(0.35, p.ZoomDuration * 0.5);

    public static List<ZoomPeriod> Periods(IReadOnlyList<ClickEvent> clicks, double pointW, double pointH, CameraParams p)
    {
        var downs = clicks.Where(c => c.IsDown).OrderBy(c => c.T).ToList();
        if (downs.Count == 0 || pointW <= 0 || pointH <= 0) return new();
        var ld = Lead(p);
        Pt Norm(ClickEvent c) => new(c.X / pointW, c.Y / pointH);

        var groups = new List<List<ClickEvent>>();
        var curEnd = double.NegativeInfinity;
        foreach (var c in downs)
        {
            var start = Math.Max(0, c.T - ld);
            if (groups.Count > 0 && start < curEnd + p.ZoomDuration) groups[^1].Add(c);
            else groups.Add(new List<ClickEvent> { c });
            curEnd = Math.Max(c.T + p.ZoomHold, Math.Max(0, groups[^1][0].T - ld) + p.ZoomDuration);
        }
        return groups.Select(g =>
        {
            var first = g[0]; var last = g[^1];
            var start = Math.Max(0, first.T - ld);
            var holdEnd = Math.Max(last.T + p.ZoomHold, start + p.ZoomDuration);
            var f0 = Norm(first);
            var near = g.Where(c => c.T - first.T < p.ZoomHold &&
                Math.Sqrt(Math.Pow(Norm(c).X - f0.X, 2) + Math.Pow(Norm(c).Y - f0.Y, 2)) < 0.25).ToList();
            var fx = near.Sum(c => Norm(c).X) / near.Count;
            var fy = near.Sum(c => Norm(c).Y) / near.Count;
            return new ZoomPeriod { Start = start, HoldEnd = holdEnd, OutEnd = holdEnd + p.ZoomDuration, Focus = new Pt(fx, fy) };
        }).ToList();
    }

    /// <summary>Zoom progress 0...1 (eased) for a period at time t.</summary>
    public static double Progress(ZoomPeriod per, double t, CameraParams p)
    {
        var ramp = Math.Max(per.Ramp > 0 ? per.Ramp : p.ZoomDuration, 0.02);
        if (t <= per.Start) return 0;
        if (t < per.HoldEnd) return Easing.Smootherstep((t - per.Start) / ramp);
        if (t >= per.OutEnd) return 0;
        var inV = Easing.Smootherstep((per.HoldEnd - per.Start) / ramp);
        return inV * (1 - Easing.Smootherstep((t - per.HoldEnd) / ramp));
    }

    public static double ClampCenter(double c, double zoom)
    {
        var h = 0.5 / Math.Max(zoom, 1);
        return Math.Min(Math.Max(c, h), 1 - h);
    }

    /// <summary>Merges auto periods (clicks in OUTPUT time) with manual regions (manual wins on overlap).</summary>
    public static List<ZoomPeriod> Plan(IReadOnlyList<ClickEvent> autoClicks, IReadOnlyList<ZoomRegion> manual,
        double pointW, double pointH, CameraParams p, bool autoZoom)
    {
        var man = new List<ZoomPeriod>();
        foreach (var r in manual.Where(r => r.End - r.Start > 0.05 && r.Scale > 1.001))
        {
            var ramp = Math.Min(p.ZoomDuration, (r.End - r.Start) / 2);
            man.Add(new ZoomPeriod
            {
                Start = Math.Max(0, r.Start), HoldEnd = r.End - ramp, OutEnd = r.End,
                Focus = new Pt(Easing.Clamp01(r.FocusX), Easing.Clamp01(r.FocusY)),
                Scale = r.Scale, Ramp = ramp, Follow = r.FollowCursor, Manual = true,
            });
        }
        var auto = new List<ZoomPeriod>();
        if (autoZoom && p.ZoomScale > 1.001)
            auto = Periods(autoClicks, pointW, pointH, p)
                .Where(a => !man.Any(m => a.Start < m.OutEnd && a.OutEnd > m.Start)).ToList();
        var all = man.Concat(auto).OrderBy(x => x.Start).ToList();
        var i = 0;
        while (i + 1 < all.Count)
        {
            if (all[i + 1].Start < all[i].OutEnd)
            {
                all[i].OutEnd = all[i + 1].Start;
                all[i].HoldEnd = Math.Min(all[i].HoldEnd, all[i].OutEnd);
                if (all[i].OutEnd - all[i].Start < 0.05) { all.RemoveAt(i); continue; }
            }
            i++;
        }
        return all;
    }

    /// <summary>Camera track in OUTPUT time. cursorAt returns the smoothed cursor (display units) or null.</summary>
    public static CameraTrack BuildTrack(IReadOnlyList<ZoomPeriod> pers, Func<double, Pt?> cursorAt,
        double pointW, double pointH, CameraParams p, double duration)
    {
        var n = (int)Math.Ceiling(Math.Max(duration, 0.01) * Hz) + 2;
        var dt = 1.0 / Hz;
        if (pers.Count == 0 || pointW <= 0 || pointH <= 0)
            return new CameraTrack(Hz, Enumerable.Repeat(0.5, n).ToArray(), Enumerable.Repeat(0.5, n).ToArray(),
                Enumerable.Repeat(1.0, n).ToArray());

        var tau = 0.05 + 0.40 * p.CameraSmoothing;
        var omega = 1.0 / tau;
        var cxs = Enumerable.Repeat(0.5, n).ToArray();
        var cys = Enumerable.Repeat(0.5, n).ToArray();
        var zs = Enumerable.Repeat(1.0, n).ToArray();

        double tcx = 0.5, tcy = 0.5, ccx = 0.5, ccy = 0.5, vx = 0, vy = 0;
        var activeIdx = -1;
        var pi = 0;
        for (var i = 0; i < n; i++)
        {
            var t = i * dt;
            while (pi < pers.Count && t >= pers[pi].OutEnd) pi++;
            var f = 0.0;
            var scale = p.ZoomScale;
            if (pi < pers.Count && t >= pers[pi].Start)
            {
                var per = pers[pi];
                scale = per.Scale > 1.001 ? per.Scale : p.ZoomScale;
                var hv = 0.5 / scale;
                var dead = 0.45 * hv;
                f = Progress(per, t, p);
                if (activeIdx != pi)
                {
                    activeIdx = pi;
                    tcx = ClampCenter(per.Focus.X, scale);
                    tcy = ClampCenter(per.Focus.Y, scale);
                    ccx = tcx; ccy = tcy; vx = 0; vy = 0;
                }
                if (per.Follow && t < per.HoldEnd && cursorAt(t) is Pt c)
                {
                    var nx = c.X / pointW; var ny = c.Y / pointH;
                    if (nx - tcx > dead) tcx = nx - dead; else if (tcx - nx > dead) tcx = nx + dead;
                    if (ny - tcy > dead) tcy = ny - dead; else if (tcy - ny > dead) tcy = ny + dead;
                    tcx = ClampCenter(tcx, scale);
                    tcy = ClampCenter(tcy, scale);
                }
                var ax = omega * omega * (tcx - ccx) - 2 * omega * vx;
                var ay = omega * omega * (tcy - ccy) - 2 * omega * vy;
                vx += ax * dt; vy += ay * dt;
                ccx += vx * dt; ccy += vy * dt;
            }
            var zoom = 1 + (scale - 1) * f;
            zs[i] = zoom;
            cxs[i] = ClampCenter(Easing.Lerp(0.5, ccx, f), zoom);
            cys[i] = ClampCenter(Easing.Lerp(0.5, ccy, f), zoom);
        }
        return new CameraTrack(Hz, cxs, cys, zs);
    }
}
