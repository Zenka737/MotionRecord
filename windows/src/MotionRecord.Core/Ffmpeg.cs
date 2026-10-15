using System.Diagnostics;
using SkiaSharp;

namespace MotionRecord;

/// <summary>Finds ffmpeg(.exe): next to the app, in ./tools, in MOTIONRECORD_FFMPEG, or on PATH.</summary>
public static class Ffmpeg
{
    public static string? Locate()
    {
        var exe = OperatingSystem.IsWindows() ? "ffmpeg.exe" : "ffmpeg";
        var env = Environment.GetEnvironmentVariable("MOTIONRECORD_FFMPEG");
        if (!string.IsNullOrEmpty(env) && File.Exists(env)) return env;
        foreach (var d in new[] { AppContext.BaseDirectory, Path.Combine(AppContext.BaseDirectory, "tools"), Path.Combine(AppContext.BaseDirectory, "ffmpeg") })
        {
            var p = Path.Combine(d, exe);
            if (File.Exists(p)) return p;
        }
        foreach (var d in (Environment.GetEnvironmentVariable("PATH") ?? "").Split(Path.PathSeparator, StringSplitOptions.RemoveEmptyEntries))
        {
            try { var p = Path.Combine(d.Trim('"'), exe); if (File.Exists(p)) return p; } catch { }
        }
        return null;
    }

    public static Process Start(string ffmpeg, string args, bool redirectIn, bool redirectOut)
    {
        var psi = new ProcessStartInfo(ffmpeg, args)
        {
            UseShellExecute = false, CreateNoWindow = true,
            RedirectStandardInput = redirectIn, RedirectStandardOutput = redirectOut, RedirectStandardError = true,
        };
        var p = Process.Start(psi) ?? throw new InvalidOperationException("ffmpeg did not start");
        p.ErrorDataReceived += (_, _) => { }; // drain stderr so ffmpeg never blocks
        p.BeginErrorReadLine();
        return p;
    }
}

/// <summary>Sequential BGRA frame reader for raw.mp4 (restarts ffmpeg on backward / far-forward seeks).</summary>
public sealed class FrameSource : IDisposable
{
    readonly string _ffmpeg, _file;
    readonly int _w, _h;
    readonly double _fps;
    Process? _proc;
    Stream? _stream;
    int _idx = -1;               // index of the frame currently in _frame
    readonly SKBitmap _frame;
    readonly int _frameBytes;
    readonly byte[] _buf;

    public FrameSource(string ffmpeg, string file, int width, int height, double fps)
    {
        _ffmpeg = ffmpeg; _file = file; _w = width; _h = height; _fps = Math.Max(fps, 1);
        _frame = new SKBitmap(new SKImageInfo(width, height, SKColorType.Bgra8888, SKAlphaType.Opaque));
        _frameBytes = width * height * 4;
        _buf = new byte[_frameBytes];
    }

    void Restart(int startIdx)
    {
        Close();
        var ss = (startIdx / _fps).ToString("0.######", System.Globalization.CultureInfo.InvariantCulture);
        var args = $"-v error -ss {ss} -i \"{_file}\" -f rawvideo -pix_fmt bgra -";
        _proc = Ffmpeg.Start(_ffmpeg, args, false, true);
        _stream = _proc.StandardOutput.BaseStream;
        _idx = startIdx - 1;
    }

    bool ReadNext()
    {
        if (_stream == null) return false;
        var read = 0;
        var buf = _buf;
        while (read < _frameBytes)
        {
            var n = _stream.Read(buf, read, _frameBytes - read);
            if (n <= 0) return false;
            read += n;
        }
        System.Runtime.InteropServices.Marshal.Copy(buf, 0, _frame.GetPixels(), _frameBytes);
        _idx++;
        return true;
    }

    /// <summary>Frame for a SOURCE time (null if the file has no frame there).</summary>
    public SKBitmap? GetFrame(double sourceT)
    {
        var want = Math.Max(0, (int)Math.Floor(sourceT * _fps + 1e-6));
        if (_stream == null || want < _idx || want > _idx + (int)_fps) Restart(want);
        while (_idx < want)
            if (!ReadNext()) return _idx >= 0 ? _frame : null; // past the end: keep last frame
        return _frame;
    }

    void Close()
    {
        try { _stream?.Dispose(); } catch { }
        try { if (_proc != null && !_proc.HasExited) _proc.Kill(); } catch { }
        _proc?.Dispose(); _proc = null; _stream = null;
    }

    public void Dispose() { Close(); _frame.Dispose(); }
}

public static class Exporter
{
    public static string BuildEncoderArgs(int w, int h, int fps, ExportFormat fmt, string outFile)
    {
        var codec = fmt == ExportFormat.mp4HEVC
            ? "-c:v libx265 -preset medium -crf 22 -tag:v hvc1"
            : "-c:v libx264 -preset medium -crf 18";
        return $"-y -v error -f rawvideo -pix_fmt bgra -s {w}x{h} -r {fps} -i - {codec} -pix_fmt yuv420p -movflags +faststart \"{outFile}\"";
    }

    /// <summary>Renders the whole project to a video file. Returns when finished; progress 0..1.</summary>
    public static void Export(string recordingDir, RecordingMetadata meta, EditProject project, string outFile,
        IProgress<double>? progress, CancellationToken ct)
    {
        var ffmpeg = Ffmpeg.Locate() ?? throw new FileNotFoundException("ffmpeg not found (put ffmpeg.exe next to the app or set MOTIONRECORD_FFMPEG)");
        var (w, h) = FrameRenderer.OutputSize(meta, project);
        var fps = Math.Min(project.Render.OutputFPS > 0 ? project.Render.OutputFPS : meta.Fps, 60);
        var renderer = new FrameRenderer(meta, project, w, h);
        var frames = (int)Math.Ceiling(renderer.OutputDuration * fps);

        using var src = new FrameSource(ffmpeg, Path.Combine(recordingDir, meta.VideoFileName), meta.Width, meta.Height, meta.Fps);
        using var enc = Ffmpeg.Start(ffmpeg, BuildEncoderArgs(w, h, fps, project.ExportFormat, outFile), true, false);
        using var surface = SKSurface.Create(new SKImageInfo(w, h, SKColorType.Bgra8888, SKAlphaType.Premul));
        var stdin = enc.StandardInput.BaseStream;
        var buf = new byte[w * h * 4];
        try
        {
        for (var i = 0; i < frames; i++)
        {
            ct.ThrowIfCancellationRequested();
            var t = i / (double)fps;
            var frame = src.GetFrame(renderer.SourceTime(t));
            surface.Canvas.Clear(SKColors.Black);
            renderer.Render(surface.Canvas, frame, t);
            using (var pm = surface.PeekPixels())
                System.Runtime.InteropServices.Marshal.Copy(pm.GetPixels(), buf, 0, buf.Length);
            stdin.Write(buf, 0, buf.Length);
            if (i % 5 == 0) progress?.Report((double)i / frames);
        }
        }
        catch { try { if (!enc.HasExited) enc.Kill(); } catch { } throw; }
        stdin.Flush(); stdin.Close();
        enc.WaitForExit();
        if (enc.ExitCode != 0) throw new InvalidOperationException($"ffmpeg encoder exited with code {enc.ExitCode}");
        progress?.Report(1);
    }
}
