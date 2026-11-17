using System.Text.Json;
using System.Text.Json.Serialization;
using System.Windows;

namespace Velinshot.Core;

/// <summary>JSON settings that mirror Swift's default <c>JSONEncoder</c> output, so presets,
/// edit states and history metadata written by either app can be read by the other:
/// camelCase keys, omitted nils, CGPoint as <c>[x, y]</c>, CGRect as <c>[[x, y], [w, h]]</c>,
/// uppercase UUIDs and dates as seconds since 2001-01-01.</summary>
public static class VelinshotJson
{
    public static readonly JsonSerializerOptions Options = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
        PropertyNameCaseInsensitive = false,
        NumberHandling = JsonNumberHandling.AllowNamedFloatingPointLiterals,
        WriteIndented = false
    };

    public static byte[] Serialize<T>(T value) => JsonSerializer.SerializeToUtf8Bytes(value, Options);
    public static T Deserialize<T>(byte[] data) =>
        JsonSerializer.Deserialize<T>(data, Options) ?? throw new JsonException("Empty JSON document.");
}

public sealed class CamelEnum<T> : JsonStringEnumConverter<T> where T : struct, Enum
{
    public CamelEnum() : base(JsonNamingPolicy.CamelCase, allowIntegerValues: false) { }
}

internal sealed class UpperGuidConverter : JsonConverter<Guid>
{
    public override Guid Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options) =>
        Guid.TryParse(reader.GetString(), out var value) ? value : throw new JsonException("Invalid identifier.");
    public override void Write(Utf8JsonWriter writer, Guid value, JsonSerializerOptions options) =>
        writer.WriteStringValue(value.ToString("D").ToUpperInvariant());
}

internal sealed class ReferenceDateConverter : JsonConverter<DateTimeOffset>
{
    private static readonly DateTimeOffset Reference = new(2001, 1, 1, 0, 0, 0, TimeSpan.Zero);
    public override DateTimeOffset Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options)
    {
        var seconds = reader.GetDouble();
        if (!double.IsFinite(seconds) || Math.Abs(seconds) > 1e11) throw new JsonException("Invalid date.");
        // Whole milliseconds survive the double round trip exactly, so metadata compares equal.
        return Reference.AddMilliseconds(Math.Round(seconds * 1000));
    }
    public override void Write(Utf8JsonWriter writer, DateTimeOffset value, JsonSerializerOptions options) =>
        writer.WriteNumberValue((value - Reference).TotalSeconds);
}

internal sealed class WatermarkPositionConverter : JsonConverter<WatermarkPosition>
{
    public override WatermarkPosition Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options) =>
        reader.GetString() switch
        {
            "topLeft" => WatermarkPosition.TopLeft,
            "topRight" => WatermarkPosition.TopRight,
            "bottomLeft" => WatermarkPosition.BottomLeft,
            _ => WatermarkPosition.BottomRight
        };
    public override void Write(Utf8JsonWriter writer, WatermarkPosition value, JsonSerializerOptions options) =>
        writer.WriteStringValue(value switch
        {
            WatermarkPosition.TopLeft => "topLeft",
            WatermarkPosition.TopRight => "topRight",
            WatermarkPosition.BottomLeft => "bottomLeft",
            _ => "bottomRight"
        });
}

internal static class JsonPairs
{
    public static (double, double) ReadPair(ref Utf8JsonReader reader)
    {
        if (reader.TokenType != JsonTokenType.StartArray) throw new JsonException("Expected a coordinate pair.");
        reader.Read(); var first = reader.GetDouble();
        reader.Read(); var second = reader.GetDouble();
        reader.Read();
        if (reader.TokenType != JsonTokenType.EndArray) throw new JsonException("Expected two coordinates.");
        return (first, second);
    }

    public static void WritePair(Utf8JsonWriter writer, double first, double second)
    {
        writer.WriteStartArray(); writer.WriteNumberValue(first); writer.WriteNumberValue(second); writer.WriteEndArray();
    }
}

internal sealed class PointListConverter : JsonConverter<List<Point>>
{
    public override List<Point> Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options)
    {
        if (reader.TokenType != JsonTokenType.StartArray) throw new JsonException("Expected points.");
        var points = new List<Point>();
        while (reader.Read() && reader.TokenType != JsonTokenType.EndArray)
        {
            var (x, y) = JsonPairs.ReadPair(ref reader);
            points.Add(new Point(x, y));
        }
        return points;
    }

    public override void Write(Utf8JsonWriter writer, List<Point> value, JsonSerializerOptions options)
    {
        writer.WriteStartArray();
        foreach (var point in value) JsonPairs.WritePair(writer, point.X, point.Y);
        writer.WriteEndArray();
    }
}

internal sealed class NullableRectConverter : JsonConverter<Rect?>
{
    public override bool HandleNull => true;

    public override Rect? Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options)
    {
        if (reader.TokenType == JsonTokenType.Null) return null;
        if (reader.TokenType != JsonTokenType.StartArray) throw new JsonException("Expected a rectangle.");
        reader.Read(); var (x, y) = JsonPairs.ReadPair(ref reader);
        reader.Read(); var (width, height) = JsonPairs.ReadPair(ref reader);
        reader.Read();
        if (reader.TokenType != JsonTokenType.EndArray) throw new JsonException("Expected origin and size.");
        // Standardize like CGRect so a negative size from another writer still describes the same area.
        if (width < 0) { x += width; width = -width; }
        if (height < 0) { y += height; height = -height; }
        if (!double.IsFinite(x + y + width + height)) throw new JsonException("Invalid rectangle.");
        return new Rect(x, y, width, height);
    }

    public override void Write(Utf8JsonWriter writer, Rect? value, JsonSerializerOptions options)
    {
        if (value is not { } rect) { writer.WriteNullValue(); return; }
        writer.WriteStartArray();
        JsonPairs.WritePair(writer, rect.X, rect.Y);
        JsonPairs.WritePair(writer, rect.Width, rect.Height);
        writer.WriteEndArray();
    }
}
