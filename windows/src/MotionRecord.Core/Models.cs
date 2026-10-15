using System.Text.Json.Serialization;

namespace MotionRecord;

// Shared contracts. Same JSON keys/semantics as the macOS app (Models.swift / EditProject.swift).
// Only ADD fields, always with defaults (System.Text.Json keeps the initializer when a key is missing).
//
// Time t = seconds since the first video frame (SOURCE time). OUTPUT time = after cuts/speed.
// Cursor/click/window positions: display units, origin TOP-LEFT, y grows down.
// On Windows the app is per-monitor DPI aware and "points" == physical pixels (pointWidth == width).

public sealed class RecordingSettings
{
    public int Fps { get; set; } = 60;
    public uint DisplayID { get; set; } = 0;
    public bool ShowNotchIndicator { get; set; } = true;
    public bool RecordCamera { get; set; } = false;
    public string? CameraDeviceID { get; set; }
    public bool RecordKeys { get; set; } = true;
    public bool RecordMic { get; set; } = false;
    public string? MicDeviceID { get; set; }
}

public sealed class CursorSample
{
    public double T { get; set; }
    public double X { get; set; }
    public double Y { get; set; }
    public CursorSample() { }
    public CursorSample(double t, double x, double y) { T = t; X = x; Y = y; }
}

public sealed class CursorShapeDef
{
    public string Id { get; set; } = "";
    public double W { get; set; }
    public double H { get; set; }
    public double HotX { get; set; }
    public double HotY { get; set; }
}

public sealed class CursorChange
{
    public double T { get; set; }
    public string Id { get; set; } = "";
}

public sealed class ClickEvent
{
    public double T { get; set; }
    public double X { get; set; }
    public double Y { get; set; }
    /// <summary>0 = left, 1 = right, 2+ = other</summary>
    public int Button { get; set; }
    public bool IsDown { get; set; }
    public ClickEvent() { }
    public ClickEvent(double t, double x, double y, int button, bool isDown)
    { T = t; X = x; Y = y; Button = button; IsDown = isDown; }
}

public sealed class KeyPress
{
    public double T { get; set; }
    public int Kind { get; set; }
}

public sealed class WindowSample
{
    public double T { get; set; }
    public double X { get; set; }
    public double Y { get; set; }
    public double W { get; set; }
    public double H { get; set; }
    public int Z { get; set; }
    public bool Visible { get; set; } = true;
}

public sealed class WindowTrack
{
    public int Id { get; set; }
    public string App { get; set; } = "";
    public string Title { get; set; } = "";
    public int Pid { get; set; }
    public List<WindowSample> Samples { get; set; } = new();
}

public sealed class RecordingMetadata
{
    public string VideoFileName { get; set; } = "raw.mov";
    public int Width { get; set; }
    public int Height { get; set; }
    public double PointWidth { get; set; }
    public double PointHeight { get; set; }
    public int Fps { get; set; } = 60;
    public double Duration { get; set; }
    public DateTime StartedAt { get; set; } = DateTime.UtcNow;
    public List<CursorSample> Cursor { get; set; } = new();
    public List<ClickEvent> Clicks { get; set; } = new();
    public string? CameraFileName { get; set; }
    public double CameraOffset { get; set; }
    public string? MicFileName { get; set; }
    public double MicOffset { get; set; }
    public List<KeyPress> Keys { get; set; } = new();
    public List<WindowTrack> Windows { get; set; } = new();
    public List<CursorShapeDef> CursorShapes { get; set; } = new();
    public List<CursorChange> CursorChanges { get; set; } = new();
}

public sealed class RenderSettings
{
    public bool AutoZoom { get; set; } = true;
    public double ZoomScale { get; set; } = 2.0;
    public double ZoomDuration { get; set; } = 0.7;
    public double ZoomHold { get; set; } = 1.4;
    public double CameraSmoothing { get; set; } = 0.55;

    public double CursorSmoothing { get; set; } = 0.5;
    public double CursorScale { get; set; } = 1.6;
    public string CursorStyle { get; set; } = "macArrow";
    public string? CustomCursorPath { get; set; }
    public double CustomCursorHotspotX { get; set; }
    public double CustomCursorHotspotY { get; set; }
    public double ClickShrinkScale { get; set; } = 0.78;
    public double ClickAnimDuration { get; set; } = 0.14;
    public bool ShowClickRipple { get; set; } = true;

    public double Padding { get; set; } = 0.05;
    public double CornerRadius { get; set; } = 16;
    public bool Shadow { get; set; } = true;
    public string BackgroundTop { get; set; } = "#5B3DF5";
    public string BackgroundBottom { get; set; } = "#D946EF";

    public int OutputFPS { get; set; } = 0;
    public int OutputHeight { get; set; } = 0;
}
