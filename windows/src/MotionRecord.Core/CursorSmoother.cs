namespace MotionRecord;

public readonly record struct Pt(double X, double Y);

/// <summary>Uniformly sampled smoothed cursor path (display units, top-left origin).</summary>
public sealed class SmoothedCursorPath
{
    public double Hz { get; }
    public double[] Xs { get; }
    public double[] Ys { get; }
    /// <summary>True when there was no cursor data at all (renderer should not draw a cursor).</summary>
    public bool IsEmpty { get; }

    public SmoothedCursorPath(double hz, double[] xs, double[] ys, bool isEmpty)
    { Hz = hz; Xs = xs; Ys = ys; IsEmpty = isEmpty; }

    public Pt Position(double t)
    {
        if (Xs.Length <= 1) return new Pt(Xs.Length > 0 ? Xs[0] : 0, Ys.Length > 0 ? Ys[0] : 0);
        var f = Math.Min(Math.Max(t * Hz, 0), Xs.Length - 1);
        var i = Math.Min((int)f, Xs.Length - 2);
        var a = f - i;
        return new Pt(Xs[i] * (1 - a) + Xs[i + 1] * a, Ys[i] * (1 - a) + Ys[i + 1] * a);
    }
}

public static class CursorSmoother
{
    public const double Hz = 240;

    /// <summary>cursorSmoothing 0...1 -> per-pass exponential time constant (seconds).</summary>
    public static double TimeConstant(double smoothing)
    {
        var s = Easing.Clamp01(smoothing);
        return s * s * 0.10 + s * 0.10;
    }

    /// <summary>Zero-phase low-pass of raw samples + click snap so the cursor lands exactly on every click.</summary>
    public static SmoothedCursorPath Smooth(IReadOnlyList<CursorSample> samples, IReadOnlyList<ClickEvent> clicks,
        double duration, double smoothing, Pt fallback)
    {
        var raw = samples.OrderBy(s => s.T).ToList();
        var endT = duration;
        if (raw.Count > 0) endT = Math.Max(endT, raw[^1].T);
        if (clicks.Count > 0) endT = Math.Max(endT, clicks.Max(c => c.T));
        endT = Math.Max(endT, 0.01);
        var n = (int)Math.Ceiling(endT * Hz) + 2;
        var dt = 1.0 / Hz;

        var xs = Enumerable.Repeat(fallback.X, n).ToArray();
        var ys = Enumerable.Repeat(fallback.Y, n).ToArray();
        if (raw.Count == 0) return new SmoothedCursorPath(Hz, xs, ys, true);

        var j = 0;
        for (var i = 0; i < n; i++)
        {
            var t = i * dt;
            while (j + 1 < raw.Count && raw[j + 1].T <= t) j++;
            if (t <= raw[0].T) { xs[i] = raw[0].X; ys[i] = raw[0].Y; continue; }
            if (j + 1 >= raw.Count) { xs[i] = raw[^1].X; ys[i] = raw[^1].Y; continue; }
            var a = raw[j]; var b = raw[j + 1];
            var u = (t - a.T) / Math.Max(b.T - a.T, 1e-9);
            xs[i] = a.X + (b.X - a.X) * u;
            ys[i] = a.Y + (b.Y - a.Y) * u;
        }

        var tau = TimeConstant(smoothing);
        if (tau > 0.002)
        {
            var tp = tau * 0.65;
            for (var pass = 0; pass < 2; pass++)
            {
                xs = ForwardBackward(xs, tp, dt);
                ys = ForwardBackward(ys, tp, dt);
            }
        }

        var snaps = clicks.OrderBy(c => c.T).ToList();
        if (snaps.Count > 0)
        {
            var halfWidth = 0.16 + tau * 0.8;
            var wN = (int)(halfWidth * Hz);
            for (var iter = 0; iter < 4; iter++)
            {
                foreach (var c in snaps)
                {
                    var f = Math.Min(Math.Max(c.T * Hz, 0), n - 1);
                    var i0 = Math.Min((int)f, n - 2);
                    var a = f - i0;
                    var cx = xs[i0] * (1 - a) + xs[i0 + 1] * a;
                    var cy = ys[i0] * (1 - a) + ys[i0 + 1] * a;
                    var dx = c.X - cx; var dy = c.Y - cy;
                    if (Math.Abs(dx) < 1e-4 && Math.Abs(dy) < 1e-4) continue;
                    var centerIdx = (int)Math.Round(f, MidpointRounding.AwayFromZero);
                    for (var k = Math.Max(0, centerIdx - wN); k <= Math.Min(n - 1, centerIdx + wN); k++)
                    {
                        var u = (k * dt - c.T) / halfWidth;
                        if (Math.Abs(u) >= 1) continue;
                        var w = 0.5 * (1 + Math.Cos(Math.PI * u));
                        xs[k] += dx * w;
                        ys[k] += dy * w;
                    }
                }
            }
        }
        return new SmoothedCursorPath(Hz, xs, ys, false);
    }

    public static double[] ForwardBackward(double[] input, double tau, double dt)
    {
        if (input.Length <= 1) return input;
        var a = 1 - Math.Exp(-dt / tau);
        var o = (double[])input.Clone();
        var y = input[0];
        for (var i = 0; i < o.Length; i++) { y += a * (o[i] - y); o[i] = y; }
        y = o[^1];
        for (var i = o.Length - 1; i >= 0; i--) { y += a * (o[i] - y); o[i] = y; }
        return o;
    }
}

/// <summary>Press / ripple timeline derived from click events (pure).</summary>
public sealed class ClickTimeline
{
    public sealed record Press(double Down, double Up);
    public IReadOnlyList<ClickEvent> Downs { get; }
    public IReadOnlyList<Press> Presses { get; }

    public ClickTimeline(IEnumerable<ClickEvent> clicks)
    {
        var sorted = clicks.OrderBy(c => c.T).ToList();
        Downs = sorted.Where(c => c.IsDown).ToList();
        var ps = new List<Press>();
        foreach (var d in Downs)
        {
            var up = sorted.FirstOrDefault(c => !c.IsDown && c.Button == d.Button && c.T >= d.T)?.T ?? (d.T + 0.12);
            ps.Add(new Press(d.T, Math.Max(up, d.T + 0.10)));
        }
        Presses = ps;
    }

    /// <summary>0 = released, 1 = fully pressed.</summary>
    public double PressAmount(double t)
    {
        var best = 0.0;
        foreach (var p in Presses)
        {
            if (t < p.Down) break;
            if (t > p.Up + 0.2) continue;
            var a = Easing.Smoothstep((t - p.Down) / 0.06);
            var r = 1 - Easing.Smoothstep((t - p.Up) / 0.14);
            best = Math.Max(best, a * r);
        }
        return best;
    }

    /// <summary>Cursor scale from the click animation: eases to `shrink` on press, springs back on release.</summary>
    public double ClickScale(double t, double shrink, double duration)
    {
        var D = Math.Max(duration, 0.03);
        var sh = Math.Min(Math.Max(shrink, 0.2), 1.5);
        for (var i = Presses.Count - 1; i >= 0; i--)
        {
            var p = Presses[i];
            if (t < p.Down) continue;
            var held = Math.Min(t, p.Up);
            var v0 = 1 + (sh - 1) * Easing.EaseOutCubic((held - p.Down) / D);
            if (t <= p.Up) return v0;
            var tau = t - p.Up;
            if (tau > 0.6) return 1;
            const double zeta = 0.4, omega = 40.0;
            var wd = omega * Math.Sqrt(1 - zeta * zeta);
            var d = (v0 - 1) * Math.Exp(-zeta * omega * tau) * (Math.Cos(wd * tau) + zeta * omega / wd * Math.Sin(wd * tau));
            return 1 + d;
        }
        return 1;
    }
}
