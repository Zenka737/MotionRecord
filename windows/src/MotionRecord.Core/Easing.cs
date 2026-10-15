namespace MotionRecord;

public static class Easing
{
    public static double Clamp01(double x) => Math.Min(Math.Max(x, 0), 1);

    /// <summary>Perlin smootherstep (C2).</summary>
    public static double Smootherstep(double x)
    {
        var t = Clamp01(x);
        return t * t * t * (t * (t * 6 - 15) + 10);
    }

    public static double Smoothstep(double x)
    {
        var t = Clamp01(x);
        return t * t * (3 - 2 * t);
    }

    public static double EaseOutCubic(double x)
    {
        var t = 1 - Clamp01(x);
        return 1 - t * t * t;
    }

    public static double Lerp(double a, double b, double t) => a + (b - a) * t;
}
