using SkiaSharp;
using Xunit;

namespace MotionRecord.Tests;

public class RendererTests
{
    static RecordingMetadata Meta() => new()
    {
        VideoFileName = "raw.mp4", Width = 1920, Height = 1080, PointWidth = 1920, PointHeight = 1080, Fps = 30, Duration = 4,
        Cursor = Enumerable.Range(0, 480).Select(i => new CursorSample(i / 120.0, 400 + i * 2, 500)).ToList(),
        Clicks = { new ClickEvent(1, 800, 500, 0, true), new ClickEvent(1.1, 800, 500, 0, false) },
    };

    [Fact]
    public void OutputSize_IsEvenAndFollowsAspect()
    {
        var (w, h) = FrameRenderer.OutputSize(Meta(), new EditProject());
        Assert.Equal(1080, h); Assert.Equal(1920, w);
        var p = new EditProject(); p.Style.Aspect = AspectPreset.square1x1; p.Render.OutputHeight = 721;
        var (w2, h2) = FrameRenderer.OutputSize(Meta(), p);
        Assert.True(w2 % 2 == 0 && h2 % 2 == 0);
    }

    [Fact]
    public void Render_DrawsBackgroundAndScreen_WithoutVideo()
    {
        var r = new FrameRenderer(Meta(), new EditProject(), 640, 360);
        using var bmp = new SKBitmap(640, 360);
        using var canvas = new SKCanvas(bmp);
        r.Render(canvas, null, 0.5);
        var corner = bmp.GetPixel(2, 2);
        Assert.True(corner.Red > 40 || corner.Blue > 100);            // gradient, not black
        Assert.Equal(new SKColor(20, 20, 24), bmp.GetPixel(320, 300)); // screen placeholder inside the frame
    }
}
