using System.Globalization;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace MotionRecord;

/// <summary>JSON compatible with the macOS app: camelCase keys, ISO8601 dates, string enums, nulls omitted.</summary>
public static class Json
{
    sealed class Iso8601Converter : JsonConverter<DateTime>
    {
        public override DateTime Read(ref Utf8JsonReader r, Type t, JsonSerializerOptions o)
        {
            if (r.TokenType == JsonTokenType.Number) // Swift default Date strategy: seconds since 2001-01-01
                return new DateTime(2001, 1, 1, 0, 0, 0, DateTimeKind.Utc).AddSeconds(r.GetDouble());
            return DateTime.Parse(r.GetString()!, CultureInfo.InvariantCulture,
                DateTimeStyles.AdjustToUniversal | DateTimeStyles.AssumeUniversal);
        }
        public override void Write(Utf8JsonWriter w, DateTime v, JsonSerializerOptions o) =>
            w.WriteStringValue(v.ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", CultureInfo.InvariantCulture));
    }

    public static readonly JsonSerializerOptions Options = Make();

    static JsonSerializerOptions Make()
    {
        var o = new JsonSerializerOptions
        {
            PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
            DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
            WriteIndented = true,
            NumberHandling = JsonNumberHandling.AllowReadingFromString,
        };
        o.Converters.Add(new JsonStringEnumConverter());
        o.Converters.Add(new Iso8601Converter());
        return o;
    }

    public static string Serialize<T>(T v) => JsonSerializer.Serialize(v, Options);
    public static T? Deserialize<T>(string s) => JsonSerializer.Deserialize<T>(s, Options);

    public static RecordingMetadata LoadMeta(string dir) =>
        Deserialize<RecordingMetadata>(File.ReadAllText(Path.Combine(dir, "meta.json")))!;

    public static void SaveMeta(string dir, RecordingMetadata m)
    {
        var tmp = Path.Combine(dir, "meta.json.tmp");
        File.WriteAllText(tmp, Serialize(m));
        File.Move(tmp, Path.Combine(dir, "meta.json"), true);
    }

    public static EditProject LoadProject(string dir)
    {
        var p = Path.Combine(dir, "project.json");
        if (!File.Exists(p)) return new EditProject();
        try { return Deserialize<EditProject>(File.ReadAllText(p)) ?? new EditProject(); }
        catch (JsonException) { return new EditProject(); }
    }

    public static void SaveProject(string dir, EditProject p)
    {
        var tmp = Path.Combine(dir, "project.json.tmp");
        File.WriteAllText(tmp, Serialize(p));
        File.Move(tmp, Path.Combine(dir, "project.json"), true);
    }
}
