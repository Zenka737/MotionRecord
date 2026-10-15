using Xunit;

namespace MotionRecord.Tests;

/// <summary>meta.json / project.json compatibility with the macOS app (keys, dates, old files).</summary>
public class JsonCompatTests
{
    // Shape written by the macOS app (Swift JSONEncoder, iso8601 dates, no `windows` / `cursorShapes` = old recording).
    const string MacMeta = """
    {"videoFileName":"raw.mov","width":3024,"height":1964,"pointWidth":1512,"pointHeight":982,"fps":60,"duration":12.5,
     "startedAt":"2026-10-13T16:57:53Z",
     "cursor":[{"t":0,"x":100,"y":200},{"t":0.004,"x":101.5,"y":200}],
     "clicks":[{"t":1.2,"x":300,"y":400,"button":0,"isDown":true}],
     "keys":[{"t":2,"kind":1}]}
    """;

    [Fact]
    public void OldMacMeta_LoadsWithDefaults()
    {
        var m = Json.Deserialize<RecordingMetadata>(MacMeta)!;
        Assert.Equal(3024, m.Width); Assert.Equal(1512, m.PointWidth);
        Assert.Equal(new DateTime(2026, 10, 13, 16, 57, 53, DateTimeKind.Utc), m.StartedAt.ToUniversalTime());
        Assert.Equal(2, m.Cursor.Count); Assert.True(m.Clicks[0].IsDown);
        Assert.Empty(m.Windows); Assert.Empty(m.CursorShapes); Assert.Null(m.CameraFileName); Assert.Equal(0, m.MicOffset);
    }

    [Fact]
    public void Meta_WritesSwiftCompatibleKeys()
    {
        var m = new RecordingMetadata { VideoFileName = "raw.mp4", Width = 1920, Height = 1080, PointWidth = 1920, PointHeight = 1080,
            Duration = 3, StartedAt = new DateTime(2026, 1, 2, 3, 4, 5, DateTimeKind.Utc) };
        m.Clicks.Add(new ClickEvent(1, 2, 3, 0, true));
        var s = Json.Serialize(m);
        foreach (var key in new[] { "\"videoFileName\"", "\"pointWidth\"", "\"startedAt\": \"2026-01-02T03:04:05Z\"", "\"isDown\": true",
                                    "\"cursorShapes\"", "\"cursorChanges\"", "\"micOffset\"" })
            Assert.Contains(key, s);
        Assert.DoesNotContain("\"cameraFileName\"", s); // null omitted like Swift
    }

    [Fact]
    public void Project_FromMac_KeepsUnknownFields_AndMissingGetDefaults()
    {
        const string proj = """
        {"render":{"zoomScale":3},"style":{"aspect":"square1x1"},"segments":[],"exportFormat":"mp4H264",
         "texts":[{"start":1,"end":3,"text":"Hi"}],
         "camera":{"enabled":true,"mirror":true,"keyframes":[]},"mochi":{"enabled":true,"x":0.4}}
        """;
        var p = Json.Deserialize<EditProject>(proj)!;
        Assert.Equal(3, p.Render.ZoomScale); Assert.Equal(0.7, p.Render.ZoomDuration); // default kept
        Assert.Equal(AspectPreset.square1x1, p.Style.Aspect);
        Assert.Equal(ExportFormat.mp4H264, p.ExportFormat);
        Assert.Equal(48, p.Texts[0].FontSize);
        var back = Json.Serialize(p);
        Assert.Contains("\"mochi\"", back); Assert.Contains("\"camera\"", back); // not lost
    }

    [Fact]
    public void Project_RoundTrip_AndSaveLoad()
    {
        var dir = Path.Combine(Path.GetTempPath(), "mr_test_" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(dir);
        try
        {
            var p = new EditProject();
            p.Segments.Add(new ClipSegment(1, 4, 2));
            p.ZoomRegions.Add(new ZoomRegion { Start = 1, End = 2, Scale = 2.5 });
            Json.SaveProject(dir, p);
            var q = Json.LoadProject(dir);
            Assert.Equal(2, q.Segments[0].Speed); Assert.Equal(2.5, q.ZoomRegions[0].Scale);
            Assert.Equal(p.Segments[0].Id, q.Segments[0].Id);
            File.WriteAllText(Path.Combine(dir, "project.json"), "{ broken");
            Assert.Empty(Json.LoadProject(dir).Segments); // corrupt file -> defaults, no crash
        }
        finally { Directory.Delete(dir, true); }
    }
}
