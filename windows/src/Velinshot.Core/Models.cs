using System.Globalization;
using System.Text.Json.Serialization;
using System.Windows;
using System.Windows.Media;

namespace Velinshot.Core;

/// <summary>An sRGB color with straight (non-premultiplied) alpha, stored as 0–1 channels.
/// JSON keys match the macOS app so presets and history stay portable.</summary>
public readonly record struct Rgba
{
    public double Red { get; init; }
    public double Green { get; init; }
    public double Blue { get; init; }
    public double Alpha { get; init; }

    public Rgba(double red, double green, double blue, double alpha = 1)
    {
        Red = red; Green = green; Blue = blue; Alpha = alpha;
    }

    public static Rgba FromHex(string hex)
    {
        var cleaned = hex.Trim().TrimStart('#');
        if ((cleaned.Length == 6 || cleaned.Length == 8) &&
            ulong.TryParse(cleaned, NumberStyles.HexNumber, CultureInfo.InvariantCulture, out var value))
        {
            var hasAlpha = cleaned.Length == 8;
            return new Rgba(((value >> (hasAlpha ? 24 : 16)) & 255) / 255.0,
                            ((value >> (hasAlpha ? 16 : 8)) & 255) / 255.0,
                            ((value >> (hasAlpha ? 8 : 0)) & 255) / 255.0,
                            hasAlpha ? (value & 255) / 255.0 : 1);
        }
        return new Rgba(0, 0, 0);
    }

    public static Rgba FromColor(Color color) => new(color.R / 255.0, color.G / 255.0, color.B / 255.0, color.A / 255.0);

    public Color ToColor() => Color.FromArgb(Byte(Alpha), Byte(Red), Byte(Green), Byte(Blue));

    public Rgba WithAlpha(double alpha) => this with { Alpha = alpha };

    [JsonIgnore]
    public string Hex => $"#{Byte(Red):X2}{Byte(Green):X2}{Byte(Blue):X2}";

    internal static double Clamp(double value) => double.IsFinite(value) ? Math.Min(1, Math.Max(0, value)) : 0;
    private static byte Byte(double value) => (byte)Math.Round(Clamp(value) * 255);
}

[JsonConverter(typeof(CamelEnum<AnnotationKind>))]
public enum AnnotationKind { Pen, Line, Arrow, Rectangle, Ellipse, Text, Highlighter, Blur, Redact, Number }

public sealed class Annotation
{
    [JsonConverter(typeof(UpperGuidConverter))]
    public Guid Id { get; set; } = Guid.NewGuid();
    public AnnotationKind Kind { get; set; }
    [JsonConverter(typeof(PointListConverter))]
    public List<Point> Points { get; set; } = new();
    public Rgba Color { get; set; } = Rgba.FromHex("6757DA");
    public double LineWidth { get; set; } = 5;
    public string Text { get; set; } = "";
    public double FontSize { get; set; } = 28;

    public Annotation() { }

    public Annotation(AnnotationKind kind, IEnumerable<Point> points, Rgba? color = null, double lineWidth = 5,
                      string text = "", double fontSize = 28)
    {
        Kind = kind; Points = points.ToList(); Color = color ?? Rgba.FromHex("6757DA");
        LineWidth = lineWidth; Text = text; FontSize = fontSize;
    }

    public Annotation Clone() => new()
    {
        Id = Id, Kind = Kind, Points = new List<Point>(Points), Color = Color,
        LineWidth = LineWidth, Text = Text, FontSize = FontSize
    };

    public bool ContentEquals(Annotation other) =>
        Id == other.Id && Kind == other.Kind && Color == other.Color && LineWidth.Equals(other.LineWidth) &&
        Text == other.Text && FontSize.Equals(other.FontSize) && Points.SequenceEqual(other.Points);
}

[JsonConverter(typeof(CamelEnum<BackgroundKind>))]
public enum BackgroundKind { Solid, Gradient, Image, Transparent }

[JsonConverter(typeof(WatermarkPositionConverter))]
public enum WatermarkPosition { TopLeft, TopRight, BottomLeft, BottomRight }

/// <summary>Frame appearance. Immutable: change it with <c>with</c> expressions.
/// Padding, inset and corner units are original source pixels.</summary>
public sealed record CanvasStyle
{
    public double Padding { get; init; } = 64;
    public double CornerRadius { get; init; } = 20;
    public double Shadow { get; init; } = 24;
    public BackgroundKind Background { get; init; } = BackgroundKind.Gradient;
    public Rgba Color1 { get; init; } = Rgba.FromHex("B7AEF8");
    public Rgba Color2 { get; init; } = Rgba.FromHex("E6E3FF");
    public double GradientAngle { get; init; } = 35;
    public double RatioWidth { get; init; }
    public double RatioHeight { get; init; }
    public double OutputScale { get; init; } = 1;
    public double BorderWidth { get; init; }
    [JsonPropertyName("backgroundAssetID")]
    public string? BackgroundAssetId { get; init; }
    public double Inset { get; init; }
    public Rgba InsetColor { get; init; } = Rgba.FromHex("FFFFFF");
    public bool AutoInsetColor { get; init; }
    public int? FixedWidth { get; init; }
    public int? FixedHeight { get; init; }
    public bool AutoBalance { get; init; } = true;
    public bool AutoColor { get; init; }
    public string WatermarkText { get; init; } = "";
    public double WatermarkFontSize { get; init; } = 20;
    public Rgba WatermarkColor { get; init; } = new(24.0 / 255, 26.0 / 255, 36.0 / 255, 0.7);
    public WatermarkPosition WatermarkPosition { get; init; } = WatermarkPosition.BottomRight;
}

public sealed class EditState
{
    public CanvasStyle Style { get; set; } = new();
    public List<Annotation> Annotations { get; set; } = new();
    [JsonConverter(typeof(NullableRectConverter))]
    public Rect? Crop { get; set; }

    public EditState() { }
    public EditState(CanvasStyle style, IEnumerable<Annotation>? annotations = null, Rect? crop = null)
    {
        Style = style; Annotations = annotations?.ToList() ?? new(); Crop = crop;
    }

    public EditState Clone() => new() { Style = Style, Annotations = Annotations.Select(a => a.Clone()).ToList(), Crop = Crop };

    public bool ContentEquals(EditState other) =>
        Style == other.Style && Nullable.Equals(Crop, other.Crop) && Annotations.Count == other.Annotations.Count &&
        Annotations.Zip(other.Annotations).All(pair => pair.First.ContentEquals(pair.Second));
}

/// <summary>Composition geometry in original source pixels.</summary>
public sealed record RenderLayout(Size CanvasSize, Rect ImageRect, Rect CropRect, Size ExportSize, Rect PanelRect)
{
    public Point SourceOriginInCanvas => new(ImageRect.X - CropRect.X, ImageRect.Y - CropRect.Y);

    public Rect CanvasBoundsInSource =>
        new(-SourceOriginInCanvas.X, -SourceOriginInCanvas.Y, CanvasSize.Width, CanvasSize.Height);

    public Point CompositionPoint(Point source) => new(source.X + SourceOriginInCanvas.X, source.Y + SourceOriginInCanvas.Y);
    public Point SourcePoint(Point composition) => new(composition.X - SourceOriginInCanvas.X, composition.Y - SourceOriginInCanvas.Y);
}

public enum VelinshotErrorKind
{
    InvalidImage, ImageTooLarge, InvalidStyle, InvalidCrop, RenderingFailed, EncodingFailed,
    CorruptHistory, InvalidHistoryPath, InvalidPreset, TextRecognitionUnavailable
}

public sealed class VelinshotException : Exception
{
    public VelinshotErrorKind Kind { get; }
    public string Reason { get; }

    public VelinshotException(VelinshotErrorKind kind, string reason = "") : base(Describe(kind, reason))
    {
        Kind = kind; Reason = reason;
    }

    private static string Describe(VelinshotErrorKind kind, string reason) => kind switch
    {
        VelinshotErrorKind.InvalidImage => $"This image could not be opened. {reason}".Trim(),
        VelinshotErrorKind.ImageTooLarge => "This image is too large. Use an image below 40 megapixels and 16,384 pixels per side, or reduce the export scale.",
        VelinshotErrorKind.InvalidStyle => $"These appearance settings cannot be rendered. {reason}".Trim(),
        VelinshotErrorKind.InvalidCrop => "The crop must contain at least one pixel inside the screenshot.",
        VelinshotErrorKind.RenderingFailed => "The screenshot could not be rendered. Try a smaller export size.",
        VelinshotErrorKind.EncodingFailed => "The image could not be encoded. Try another format.",
        VelinshotErrorKind.CorruptHistory => $"A history item could not be restored. {reason}".Trim(),
        VelinshotErrorKind.InvalidHistoryPath => "This history item refers to a file outside the history folder.",
        VelinshotErrorKind.InvalidPreset => $"The saved presets could not be read. {reason}".Trim(),
        VelinshotErrorKind.TextRecognitionUnavailable => $"Text recognition is unavailable. {reason}".Trim(),
        _ => reason
    };

    public static VelinshotException InvalidImage(string reason) => new(VelinshotErrorKind.InvalidImage, reason);
    public static VelinshotException TooLarge() => new(VelinshotErrorKind.ImageTooLarge);
    public static VelinshotException InvalidStyle(string reason) => new(VelinshotErrorKind.InvalidStyle, reason);
    public static VelinshotException InvalidCrop() => new(VelinshotErrorKind.InvalidCrop);
    public static VelinshotException RenderingFailed() => new(VelinshotErrorKind.RenderingFailed);
    public static VelinshotException EncodingFailed() => new(VelinshotErrorKind.EncodingFailed);
    public static VelinshotException CorruptHistory(string reason) => new(VelinshotErrorKind.CorruptHistory, reason);
    public static VelinshotException InvalidHistoryPath() => new(VelinshotErrorKind.InvalidHistoryPath);
    public static VelinshotException InvalidPreset(string reason) => new(VelinshotErrorKind.InvalidPreset, reason);
}

public static class ImageLimits
{
    public const int MaximumPixels = 40_000_000;
    public const int MaximumDimension = 16_384;

    public static void Validate(int width, int height)
    {
        if (width <= 0 || height <= 0) throw VelinshotException.InvalidImage("The dimensions are empty.");
        if (width > MaximumDimension || height > MaximumDimension || width > MaximumPixels / height)
            throw VelinshotException.TooLarge();
    }
}

internal static class RectMath
{
    /// <summary>Core Graphics <c>CGRect.integral</c>: the smallest integer rectangle containing <paramref name="rect"/>.</summary>
    public static Rect Integral(Rect rect)
    {
        var x = Math.Floor(rect.X); var y = Math.Floor(rect.Y);
        return new Rect(x, y, Math.Ceiling(rect.Right) - x, Math.Ceiling(rect.Bottom) - y);
    }

    public static bool IsFinite(Rect rect) =>
        double.IsFinite(rect.X) && double.IsFinite(rect.Y) && double.IsFinite(rect.Width) && double.IsFinite(rect.Height);

    public static Rect FromPoints(Point a, Point b) =>
        new(Math.Min(a.X, b.X), Math.Min(a.Y, b.Y), Math.Abs(a.X - b.X), Math.Abs(a.Y - b.Y));
}
