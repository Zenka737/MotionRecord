using System.Windows.Media.Imaging;
using SkiaSharp;

namespace MotionRecord.App;

/// <summary>Background frame renderer: only the LATEST requested time is rendered (scrubbing never queues up).</summary>
public sealed class PreviewService : IDisposable
{
    readonly EditorModel _m;
    readonly FrameSource? _src;
    readonly Thread _thread;
    readonly AutoResetEvent _wake = new(false);
    readonly Action<WriteableBitmap> _onFrame;
    readonly System.Windows.Threading.Dispatcher _ui;
    double _req = -1;
    volatile bool _quit;
    public int PreviewHeight = 540;
    WriteableBitmap? _wb;

    public PreviewService(EditorModel m, Action<WriteableBitmap> onFrame)
    {
        _m = m; _onFrame = onFrame; _ui = System.Windows.Application.Current.Dispatcher;
        var ff = Ffmpeg.Locate();
        if (ff != null) _src = new FrameSource(ff, Path.Combine(m.Dir, m.Meta.VideoFileName), m.Meta.Width, m.Meta.Height, m.Meta.Fps);
        _thread = new Thread(Loop) { IsBackground = true, Name = "mr-preview" };
        _thread.Start();
    }

    public bool HasFfmpeg => _src != null;

    public void Request(double outputT) { Interlocked.Exchange(ref _req, outputT); _wake.Set(); }

    void Loop()
    {
        while (!_quit)
        {
            _wake.WaitOne();
            if (_quit) break;
            var t = Interlocked.Exchange(ref _req, -1);
            if (t < 0) continue;
            try
            {
                var (w, h) = FrameRenderer.OutputSize(_m.Meta, _m.Project);
                var s = (double)PreviewHeight / h;
                int pw = Math.Max(2, (int)(w * s) & ~1), ph = Math.Max(2, (int)(h * s) & ~1);
                var r = _m.Renderer(pw, ph);
                var frame = _src?.GetFrame(r.SourceTime(Math.Min(t, r.OutputDuration)));
                using var surface = SKSurface.Create(new SKImageInfo(pw, ph, SKColorType.Bgra8888, SKAlphaType.Premul));
                surface.Canvas.Clear(SKColors.Black);
                r.Render(surface.Canvas, frame, t);
                using var pm = surface.PeekPixels();
                var data = new byte[pw * ph * 4];
                System.Runtime.InteropServices.Marshal.Copy(pm.GetPixels(), data, 0, data.Length);
                _ui.BeginInvoke(() =>
                {
                    if (_wb == null || _wb.PixelWidth != pw || _wb.PixelHeight != ph)
                        _wb = new WriteableBitmap(pw, ph, 96, 96, System.Windows.Media.PixelFormats.Bgra32, null);
                    _wb.WritePixels(new System.Windows.Int32Rect(0, 0, pw, ph), data, pw * 4, 0);
                    _onFrame(_wb);
                });
            }
            catch { /* a bad frame must not kill the preview thread */ }
        }
    }

    public void Dispose() { _quit = true; _wake.Set(); _thread.Join(500); _src?.Dispose(); }
}
