using System.Diagnostics;
using System.Drawing;
using System.Drawing.Imaging;

namespace MotionRecord.App;

/// <summary>
/// Records the primary display to raw.mp4 (cursor is NOT in the picture: CopyFromScreen leaves it out) and writes
/// the cursor track + clicks to meta.json (same format as the macOS app). t = seconds since the first captured frame.
/// MVP backend = GDI BitBlt piped to ffmpeg; Windows.Graphics.Capture is the planned replacement (same output contract).
/// </summary>
public sealed class ScreenRecorder
{
    readonly string _dir;
    readonly int _fps;
    readonly string _ffmpeg;
    readonly Stopwatch _clock = new();
    readonly List<CursorSample> _cursor = new();
    readonly List<ClickEvent> _clicks = new();
    readonly object _lock = new();
    volatile bool _stop;
    Thread? _capThread, _inputThread;
    Exception? _error;
    double _firstFrameT = -1;
    double _lastFrameT;
    int _w, _h;
    DateTime _startedAt;

    public string Directory => _dir;
    public Exception? Error => _error;
    public bool IsRunning { get; private set; }

    public ScreenRecorder(string libraryRoot, int fps, string ffmpegPath)
    {
        _fps = fps; _ffmpeg = ffmpegPath;
        _dir = Path.Combine(libraryRoot, DateTime.Now.ToString("yyyy-MM-dd_HH-mm-ss"));
    }

    public void Start()
    {
        System.IO.Directory.CreateDirectory(_dir);
        _w = Native.GetSystemMetrics(Native.SM_CXSCREEN) & ~1;   // even for yuv420p
        _h = Native.GetSystemMetrics(Native.SM_CYSCREEN) & ~1;
        _startedAt = DateTime.UtcNow;
        Native.timeBeginPeriod(1);
        IsRunning = true;
        _clock.Start();
        _inputThread = new Thread(InputLoop) { IsBackground = true, Name = "mr-input", Priority = ThreadPriority.AboveNormal };
        _capThread = new Thread(CaptureLoop) { IsBackground = true, Name = "mr-capture" };
        _inputThread.Start();
        _capThread.Start();
    }

    /// <summary>Stops, finalizes raw.mp4, writes meta.json and an empty-default project.json. Returns the folder.</summary>
    public string Stop()
    {
        _stop = true;
        _capThread?.Join();
        _inputThread?.Join();
        Native.timeEndPeriod(1);
        IsRunning = false;
        if (_error != null) throw new InvalidOperationException("Запись не удалась: " + _error.Message, _error);

        var t0 = _firstFrameT < 0 ? 0 : _firstFrameT;
        var meta = new RecordingMetadata
        {
            VideoFileName = "raw.mp4", Width = _w, Height = _h, PointWidth = _w, PointHeight = _h, Fps = _fps,
            Duration = Math.Max(_lastFrameT - t0 + 1.0 / _fps, 0.05), StartedAt = _startedAt,
        };
        lock (_lock)
        {
            meta.Cursor = _cursor.Where(c => c.T >= t0).Select(c => new CursorSample(c.T - t0, c.X, c.Y)).ToList();
            meta.Clicks = _clicks.Where(c => c.T >= t0).Select(c => new ClickEvent(c.T - t0, c.X, c.Y, c.Button, c.IsDown)).ToList();
        }
        Json.SaveMeta(_dir, meta);
        if (!File.Exists(Path.Combine(_dir, "project.json"))) Json.SaveProject(_dir, new EditProject { ExportFormat = ExportFormat.mp4H264 });
        return _dir;
    }

    void InputLoop()
    {
        bool[] down = new bool[3];
        int[] vks = { Native.VK_LBUTTON, Native.VK_RBUTTON, Native.VK_MBUTTON };
        double lastX = double.NaN, lastY = double.NaN, lastT = -1;
        var next = 0.0;
        while (!_stop)
        {
            var t = _clock.Elapsed.TotalSeconds;
            if (Native.GetCursorPos(out var p))
            {
                var moved = p.X != lastX || p.Y != lastY;
                lock (_lock)
                {
                    if (moved || t - lastT > 0.05) { _cursor.Add(new CursorSample(t, p.X, p.Y)); lastT = t; lastX = p.X; lastY = p.Y; }
                    for (var b = 0; b < 3; b++)
                    {
                        var isDown = (Native.GetAsyncKeyState(vks[b]) & 0x8000) != 0;
                        if (isDown != down[b]) { down[b] = isDown; _clicks.Add(new ClickEvent(t, p.X, p.Y, b, isDown)); }
                    }
                }
            }
            next += 1.0 / 240;
            var wait = next - _clock.Elapsed.TotalSeconds;
            if (wait > 0) Thread.Sleep((int)(wait * 1000)); else next = _clock.Elapsed.TotalSeconds;
        }
    }

    void CaptureLoop()
    {
        Process? enc = null;
        try
        {
            var args = $"-y -v error -f rawvideo -pix_fmt bgra -s {_w}x{_h} -r {_fps} -i - -c:v libx264 -preset ultrafast -crf 16 -pix_fmt yuv420p -movflags +faststart \"{Path.Combine(_dir, "raw.mp4")}\"";
            enc = Ffmpeg.Start(_ffmpeg, args, true, false);
            var stdin = enc.StandardInput.BaseStream;
            using var bmp = new Bitmap(_w, _h, PixelFormat.Format32bppArgb);
            using var g = Graphics.FromImage(bmp);
            var buf = new byte[_w * _h * 4];
            var written = 0;           // frames written
            double t0 = -1;
            while (!_stop)
            {
                var now = _clock.Elapsed.TotalSeconds;
                if (t0 < 0) { t0 = now; _firstFrameT = now; }
                // CaptureBlt includes layered (transparent) windows; the mouse cursor is never drawn by CopyFromScreen.
                g.CopyFromScreen(0, 0, 0, 0, new Size(_w, _h), CopyPixelOperation.SourceCopy | CopyPixelOperation.CaptureBlt);
                var data = bmp.LockBits(new Rectangle(0, 0, _w, _h), ImageLockMode.ReadOnly, PixelFormat.Format32bppArgb);
                System.Runtime.InteropServices.Marshal.Copy(data.Scan0, buf, 0, buf.Length);
                bmp.UnlockBits(data);

                // Constant frame rate: write as many frames as the wall clock demands (repeat the last one if we lag).
                var due = (int)Math.Floor((_clock.Elapsed.TotalSeconds - t0) * _fps) + 1;
                if (due <= written) due = written + 1;
                for (; written < due; written++) stdin.Write(buf, 0, buf.Length);
                _lastFrameT = t0 + (written - 1) / (double)_fps;

                var nextAt = t0 + written / (double)_fps;
                var sleep = nextAt - _clock.Elapsed.TotalSeconds;
                if (sleep > 0.001) Thread.Sleep((int)(sleep * 1000));
            }
            stdin.Flush(); stdin.Close();
            enc.WaitForExit();
            if (enc.ExitCode != 0) _error = new InvalidOperationException($"ffmpeg завершился с кодом {enc.ExitCode}");
        }
        catch (Exception e) { _error = e; _stop = true; try { enc?.Kill(); } catch { } }
    }
}
