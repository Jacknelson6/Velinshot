using System.Diagnostics;
using System.IO;
using System.Text;
using System.Windows;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using Velinshot.Core;

namespace Velinshot.Checks;

/// <summary>Runs every check, prints a summary and exits non-zero on failure.
/// Usage: Velinshot.Checks [--out folder] [filter]</summary>
public static class Program
{
    private static int passed, failed;
    private static string outputFolder = Path.Combine(Path.GetTempPath(), "velinshot-checks");

    [STAThread]
    public static int Main(string[] args)
    {
        var filter = "";
        for (var i = 0; i < args.Length; i++)
        {
            if (args[i] == "--out" && i + 1 < args.Length) outputFolder = Path.GetFullPath(args[++i]);
            else filter = args[i];
        }
        Directory.CreateDirectory(outputFolder);
        var clock = Stopwatch.StartNew();
        foreach (var (name, check) in Checks.All())
        {
            if (filter.Length > 0 && !name.Contains(filter, StringComparison.OrdinalIgnoreCase)) continue;
            try
            {
                check();
                passed++;
                Console.WriteLine($"  pass  {name}");
            }
            catch (Exception error)
            {
                failed++;
                Console.WriteLine($"  FAIL  {name}: {error.GetType().Name}: {error.Message}");
            }
        }
        Console.WriteLine($"{passed} passed, {failed} failed in {clock.Elapsed.TotalSeconds:0.0}s. Artifacts: {outputFolder}");
        return failed == 0 ? 0 : 1;
    }

    public static string Output(string name) => Path.Combine(outputFolder, name);
}

internal sealed class CheckFailed(string message) : Exception(message);

internal static class Assert
{
    public static void True(bool condition, string message) { if (!condition) throw new CheckFailed(message); }
    public static void Equal<T>(T expected, T actual, string what)
    {
        if (!EqualityComparer<T>.Default.Equals(expected, actual)) throw new CheckFailed($"{what}: expected {expected}, got {actual}");
    }
    public static void Near(double expected, double actual, double tolerance, string what)
    {
        if (Math.Abs(expected - actual) > tolerance) throw new CheckFailed($"{what}: expected {expected}±{tolerance}, got {actual}");
    }
    public static void Throws<T>(Action action, string what) where T : Exception
    {
        try { action(); }
        catch (T) { return; }
        catch (Exception other) { throw new CheckFailed($"{what}: expected {typeof(T).Name}, got {other.GetType().Name} ({other.Message})"); }
        throw new CheckFailed($"{what}: expected {typeof(T).Name}, nothing thrown");
    }
    public static void ThrowsKind(VelinshotErrorKind kind, Action action, string what)
    {
        try { action(); }
        catch (VelinshotException error) when (error.Kind == kind) { return; }
        catch (Exception other) { throw new CheckFailed($"{what}: expected {kind}, got {other.GetType().Name} ({other.Message})"); }
        throw new CheckFailed($"{what}: expected {kind}, nothing thrown");
    }
}

internal readonly record struct Px(byte R, byte G, byte B, byte A)
{
    public override string ToString() => $"({R},{G},{B},{A})";
}

internal static class Images
{
    public static BitmapSource Make(int width, int height, Func<int, int, Px> pixel)
    {
        var data = new byte[width * height * 4];
        for (var y = 0; y < height; y++)
        for (var x = 0; x < width; x++)
        {
            var p = pixel(x, y);
            var i = (y * width + x) * 4;
            // Premultiply for Pbgra32.
            data[i] = (byte)(p.B * p.A / 255); data[i + 1] = (byte)(p.G * p.A / 255); data[i + 2] = (byte)(p.R * p.A / 255); data[i + 3] = p.A;
        }
        return ImageLoader.Adopt(BitmapSource.Create(width, height, 96, 96, PixelFormats.Pbgra32, null, data, width * 4));
    }

    public static BitmapSource Solid(int width, int height, Px color) => Make(width, height, (_, _) => color);

    /// <summary>Straight-alpha pixel at (x, y).</summary>
    public static Px At(BitmapSource image, int x, int y)
    {
        var data = new byte[4];
        var source = image.Format == PixelFormats.Pbgra32 ? image : new FormatConvertedBitmap(image, PixelFormats.Pbgra32, null, 0);
        source.CopyPixels(new Int32Rect(x, y, 1, 1), data, 4, 0);
        var a = data[3];
        if (a == 0) return new Px(0, 0, 0, 0);
        return new Px((byte)Math.Min(255, Math.Round(data[2] * 255.0 / a)), (byte)Math.Min(255, Math.Round(data[1] * 255.0 / a)),
                      (byte)Math.Min(255, Math.Round(data[0] * 255.0 / a)), a);
    }

    public static byte[] Bytes(BitmapSource image)
    {
        var source = image.Format == PixelFormats.Pbgra32 ? image : new FormatConvertedBitmap(image, PixelFormats.Pbgra32, null, 0);
        var data = new byte[source.PixelWidth * source.PixelHeight * 4];
        source.CopyPixels(data, source.PixelWidth * 4, 0);
        return data;
    }

    public static void Save(BitmapSource image, string name) => File.WriteAllBytes(Program.Output(name), ImageExporter.Data(image, ImageFormat.Png));

    public static Rect? InkBounds(BitmapSource image, Func<Px, bool> isInk)
    {
        int minX = int.MaxValue, minY = int.MaxValue, maxX = -1, maxY = -1;
        var bytes = Bytes(image);
        for (var y = 0; y < image.PixelHeight; y++)
        for (var x = 0; x < image.PixelWidth; x++)
        {
            var i = (y * image.PixelWidth + x) * 4;
            var a = bytes[i + 3];
            var px = a == 0 ? new Px(0, 0, 0, 0) : new Px((byte)(bytes[i + 2] * 255 / a), (byte)(bytes[i + 1] * 255 / a), (byte)(bytes[i] * 255 / a), a);
            if (!isInk(px)) continue;
            minX = Math.Min(minX, x); minY = Math.Min(minY, y); maxX = Math.Max(maxX, x); maxY = Math.Max(maxY, y);
        }
        return maxX < 0 ? null : new Rect(minX, minY, maxX - minX + 1, maxY - minY + 1);
    }
}

internal static class Checks
{
    private static readonly Px White = new(255, 255, 255, 255);
    private static EditState Plain() => new(new CanvasStyle { Padding = 0, CornerRadius = 0, Shadow = 0, Background = BackgroundKind.Transparent, AutoBalance = false });

    public static IEnumerable<(string, Action)> All()
    {
        yield return ("layout: padding and inset in source pixels", LayoutPadding);
        yield return ("layout: ratio and exact sizes", LayoutRatios);
        yield return ("layout: invalid crops and styles are rejected", LayoutRejects);
        yield return ("render: plain composition reproduces source pixels", PlainRenderIsExact);
        yield return ("render: solid background, inset ring and corners", SolidAndInset);
        yield return ("render: gradient covers the whole bitmap", GradientCovers);
        yield return ("render: shadow never fills transparent screenshot pixels", ShadowTransparentInterior);
        yield return ("render: zero padding clips the shadow at the canvas", ZeroPaddingShadow);
        yield return ("render: exact output scales the shadow with the composition", ShadowScales);
        yield return ("markup: redaction is opaque even with a transparent color", RedactionOpaque);
        yield return ("markup: highlighter multiplies instead of covering", HighlighterMultiplies);
        yield return ("markup: blur softens only inside its rectangle", BlurStaysInside);
        yield return ("markup: marks draw on the mat outside the screenshot", MarkupOnMat);
        yield return ("markup: arrows, text and numbers render", ShapesRender);
        yield return ("watermark: placed in export pixels and rejected when too small", Watermark);
        yield return ("preview: proxy preview matches the export geometry", PreviewParity);
        yield return ("io: PNG and JPEG round trips", EncodeRoundTrips);
        yield return ("io: oversized images are rejected", Limits);
        yield return ("json: macOS-style style JSON decodes with defaults", JsonCompatibility);
        yield return ("json: edit state round trip uses macOS shapes", JsonShapes);
        yield return ("analysis: content bounds trim a uniform border", ContentBounds);
        yield return ("analysis: inset color follows the dominant edge", InsetColor);
        yield return ("analysis: matched colors stay soft", SuggestedColors);
        yield return ("history: save, list, load, update and clear", History);
        yield return ("history: limits evict the oldest entries", HistoryLimits);
        yield return ("presets: validate names and round trip", Presets);
        yield return ("ocr: Windows OCR reads synthetic text", Ocr);
        yield return ("demo: full composition renders and saves", DemoRender);
        yield return ("bench: preview render timings", Bench);
    }

    private static void LayoutPadding()
    {
        var state = Plain();
        state.Style = state.Style with { Padding = 20, Inset = 5 };
        var layout = CanvasRenderer.Layout(new Size(100, 80), state);
        Assert.Equal(new Size(150, 130), layout.CanvasSize, "canvas");
        Assert.Equal(new Rect(25, 25, 100, 80), layout.ImageRect, "image rect");
        Assert.Equal(new Rect(20, 20, 110, 90), layout.PanelRect, "panel");
        Assert.Equal(new Size(150, 130), layout.ExportSize, "export");
        state.Style = state.Style with { OutputScale = 2 };
        Assert.Equal(new Size(300, 260), CanvasRenderer.Layout(new Size(100, 80), state).ExportSize, "2x export");
        state.Crop = new Rect(10.4, 10.6, 20.2, 20.1);
        Assert.Equal(new Rect(10, 10, 21, 21), CanvasRenderer.Layout(new Size(100, 80), state).CropRect, "integral crop");
    }

    private static void LayoutRatios()
    {
        var state = Plain();
        state.Style = state.Style with { RatioWidth = 1, RatioHeight = 1 };
        Assert.Equal(new Size(100, 100), CanvasRenderer.Layout(new Size(100, 60), state).CanvasSize, "square");
        state.Style = state.Style with { RatioWidth = 0, RatioHeight = 0, FixedWidth = 300, FixedHeight = 200 };
        var layout = CanvasRenderer.Layout(new Size(100, 60), state);
        Assert.Equal(new Size(300, 200), layout.ExportSize, "fixed export");
        Assert.Near(1.5, layout.CanvasSize.Width / layout.CanvasSize.Height, 1e-9, "fixed ratio");
    }

    private static void LayoutRejects()
    {
        var state = Plain();
        state.Crop = new Rect(200, 200, 10, 10);
        Assert.ThrowsKind(VelinshotErrorKind.InvalidCrop, () => CanvasRenderer.Layout(new Size(100, 80), state), "outside crop");
        state = Plain();
        state.Style = state.Style with { Padding = -1 };
        Assert.ThrowsKind(VelinshotErrorKind.InvalidStyle, () => CanvasRenderer.Layout(new Size(100, 80), state), "negative padding");
        state.Style = Plain().Style with { FixedWidth = 100 };
        Assert.ThrowsKind(VelinshotErrorKind.InvalidStyle, () => CanvasRenderer.Layout(new Size(100, 80), state), "half fixed size");
        state.Style = Plain().Style with { OutputScale = 5 };
        Assert.ThrowsKind(VelinshotErrorKind.InvalidStyle, () => CanvasRenderer.Layout(new Size(100, 80), state), "scale");
        Assert.ThrowsKind(VelinshotErrorKind.ImageTooLarge, () => CanvasRenderer.Layout(new Size(20000, 10), Plain()), "dimension");
    }

    private static void PlainRenderIsExact()
    {
        var source = Images.Make(64, 48, (x, y) => new Px((byte)(x * 4), (byte)(y * 5), (byte)((x * y) % 256), (byte)(x < 8 ? 128 : 255)));
        var output = CanvasRenderer.Render(source, Plain());
        Assert.Equal(64, output.PixelWidth, "width");
        Assert.True(Images.Bytes(source).SequenceEqual(Images.Bytes(output)), "Plain render must reproduce every source byte.");
    }

    private static void SolidAndInset()
    {
        var source = Images.Solid(50, 40, White);
        var state = Plain();
        state.Style = state.Style with
        {
            Padding = 20, Inset = 10, Background = BackgroundKind.Solid, Color1 = Rgba.FromHex("0000FF"), InsetColor = Rgba.FromHex("00FF00")
        };
        var output = CanvasRenderer.Render(source, state);
        Assert.Equal(new Px(0, 0, 255, 255), Images.At(output, 5, 5), "mat");
        Assert.Equal(new Px(0, 255, 0, 255), Images.At(output, 25, 25), "inset ring");
        Assert.Equal(White, Images.At(output, 50, 50), "screenshot");
        state.Style = state.Style with { CornerRadius = 30 };
        var rounded = CanvasRenderer.Render(source, state);
        Assert.Equal(new Px(0, 0, 255, 255), Images.At(rounded, 21, 21), "rounded corner shows the mat");
        Images.Save(rounded, "solid-inset.png");
    }

    private static void GradientCovers()
    {
        var state = Plain();
        state.Style = state.Style with { Padding = 13, Background = BackgroundKind.Gradient, RatioWidth = 16, RatioHeight = 9 };
        var output = CanvasRenderer.Render(Images.Solid(33, 21, White), state);
        foreach (var (x, y) in new[] { (0, 0), (output.PixelWidth - 1, 0), (0, output.PixelHeight - 1), (output.PixelWidth - 1, output.PixelHeight - 1) })
            Assert.Equal((byte)255, Images.At(output, x, y).A, $"corner {x},{y} alpha");
        var first = Images.At(output, 0, 0); var last = Images.At(output, output.PixelWidth - 1, output.PixelHeight - 1);
        Assert.True(first != last, "gradient varies across the canvas");
    }

    private static void ShadowTransparentInterior()
    {
        var source = Images.Make(100, 80, (x, y) => x > 40 && x < 60 && y > 30 && y < 50 ? new Px(0, 0, 0, 0) : White);
        var state = Plain();
        state.Style = state.Style with { Padding = 20, Shadow = 12 };
        var output = CanvasRenderer.Render(source, state);
        Assert.Equal((byte)0, Images.At(output, 70, 60).A, "transparent hole stays transparent");
        Assert.True(Images.At(output, 70, 104).A > 0, "shadow below the panel");
        Images.Save(output, "shadow-hole.png");
    }

    private static void ZeroPaddingShadow()
    {
        var source = Images.Solid(50, 40, White);
        var plain = CanvasRenderer.Render(source, Plain());
        var state = Plain();
        state.Style = state.Style with { Shadow = 32 };
        var output = CanvasRenderer.Render(source, state);
        Assert.Equal(50, output.PixelWidth, "width");
        Assert.True(Images.Bytes(plain).SequenceEqual(Images.Bytes(output)), "A clipped shadow must not change any pixel.");
    }

    private static void ShadowScales()
    {
        var source = Images.Solid(100, 60, White);
        var state = Plain();
        state.Style = state.Style with { Padding = 40, Shadow = 20, FixedWidth = 180, FixedHeight = 140 };
        var baseOutput = CanvasRenderer.Render(source, state);
        var probes = new[] { (90, 20), (90, 25), (90, 30), (90, 35), (25, 70), (30, 70), (35, 70), (145, 70), (150, 70), (155, 70), (90, 105), (90, 110), (90, 115) };
        var baseline = probes.Select(p => (int)Images.At(baseOutput, p.Item1, p.Item2).A).ToArray();
        Assert.True(baseline.Max() > 8, "the regression must inspect visible shadow pixels");
        foreach (var factor in new[] { 2, 4 })
        {
            state.Style = state.Style with { FixedWidth = 180 * factor, FixedHeight = 140 * factor };
            var output = CanvasRenderer.Render(source, state);
            for (var i = 0; i < probes.Length; i++)
            {
                var observed = Images.At(output, probes[i].Item1 * factor, probes[i].Item2 * factor).A;
                Assert.Near(baseline[i], observed, 6, $"shadow alpha at {factor}x probe {probes[i]}");
            }
        }
    }

    private static void RedactionOpaque()
    {
        var source = Images.Solid(40, 40, new Px(255, 0, 255, 255));
        var state = Plain();
        state.Annotations.Add(new Annotation(AnnotationKind.Redact, new[] { new Point(5, 5), new Point(30, 30) }, new Rgba(0, 0, 0, 0)));
        Assert.Equal(new Px(0, 0, 0, 255), Images.At(CanvasRenderer.Render(source, state), 10, 10), "redacted pixel");
    }

    private static void HighlighterMultiplies()
    {
        var source = Images.Make(80, 40, (x, _) => x < 40 ? White : new Px(0, 0, 0, 255));
        var state = Plain();
        state.Annotations.Add(new Annotation(AnnotationKind.Highlighter, new[] { new Point(0, 20), new Point(80, 20) }, Rgba.FromHex("FFD400"), 6));
        var output = CanvasRenderer.Render(source, state);
        var onWhite = Images.At(output, 20, 20);
        Assert.Near(255, onWhite.R, 2, "white red channel");
        Assert.Near(255 * 0.7 + 212 * 0.3, onWhite.G, 3, "white green channel");
        Assert.Near(255 * 0.7, onWhite.B, 3, "white blue channel");
        Assert.Equal(new Px(0, 0, 0, 255), Images.At(output, 60, 20), "black stays black under multiply");
        Assert.Equal(White, Images.At(output, 20, 2), "outside the stroke");
    }

    private static void BlurStaysInside()
    {
        var source = Images.Make(120, 80, (x, _) => x % 8 < 4 ? new Px(0, 0, 0, 255) : White);
        var state = Plain();
        state.Annotations.Add(new Annotation(AnnotationKind.Blur, new[] { new Point(20, 20), new Point(100, 60) }, null, 6));
        var output = CanvasRenderer.Render(source, state);
        var inside = Enumerable.Range(40, 8).Select(x => (int)Images.At(output, x, 40).R).ToArray();
        Assert.True(inside.Max() - inside.Min() < 40, $"stripes inside are softened: {string.Join(",", inside)}");
        Assert.Equal(new Px(0, 0, 0, 255), Images.At(output, 1, 10), "outside left untouched");
        Assert.Equal(White, Images.At(output, 5, 70), "outside below untouched");
        Images.Save(output, "blur.png");
    }

    private static void MarkupOnMat()
    {
        var source = Images.Solid(60, 40, White);
        var state = Plain();
        state.Style = state.Style with { Padding = 30, Background = BackgroundKind.Solid, Color1 = Rgba.FromHex("0000FF") };
        // Source coordinates may be negative: the mat lies outside the screenshot.
        state.Annotations.Add(new Annotation(AnnotationKind.Rectangle, new[] { new Point(-25, -25), new Point(-5, -5) }, Rgba.FromHex("FF0000"), 4));
        var output = CanvasRenderer.Render(source, state);
        Assert.Equal(new Px(255, 0, 0, 255), Images.At(output, 5, 15), "stroke on the mat");
    }

    private static void ShapesRender()
    {
        var source = Images.Solid(300, 200, White);
        var state = Plain();
        state.Annotations.AddRange(new[]
        {
            new Annotation(AnnotationKind.Arrow, new[] { new Point(20, 180), new Point(200, 40) }, Rgba.FromHex("EC687C"), 6),
            new Annotation(AnnotationKind.Text, new[] { new Point(150, 120) }, Rgba.FromHex("191A25"), 5, "Hello", 28),
            new Annotation(AnnotationKind.Number, new[] { new Point(60, 50) }, Rgba.FromHex("7160E8"), 5, "2", 28),
            new Annotation(AnnotationKind.Ellipse, new[] { new Point(220, 20), new Point(290, 80) }, Rgba.FromHex("2E9E5B"), 4),
            new Annotation(AnnotationKind.Pen, new[] { new Point(10, 10), new Point(30, 30), new Point(50, 12) }, Rgba.FromHex("000000"), 3)
        });
        var output = CanvasRenderer.Render(source, state);
        Images.Save(output, "shapes.png");
        var number = Images.At(output, 60, 37);
        Assert.Equal(Rgba.FromHex("7160E8").ToColor().R, number.R, "number badge fill");
        var ink = Images.InkBounds(output, p => p.R < 80 && p.G < 80 && p.B < 80);
        Assert.True(ink is { } bounds && bounds.Right > 150, "text and pen ink present");
    }

    private static void Watermark()
    {
        var source = Images.Solid(200, 100, White);
        var state = Plain();
        state.Style = state.Style with { WatermarkText = "velinshot", WatermarkColor = Rgba.FromHex("000000") };
        var output = CanvasRenderer.Render(source, state);
        var ink = Images.InkBounds(output, p => p.R < 128) ?? throw new CheckFailed("no watermark ink");
        Assert.True(ink.Right <= 188 && ink.Bottom <= 88 && ink.X > 100 && ink.Y > 50, $"bottom-right placement {ink}");
        state.Style = state.Style with { FixedWidth = 20, FixedHeight = 20 };
        Assert.ThrowsKind(VelinshotErrorKind.InvalidStyle, () => CanvasRenderer.Render(source, state), "tiny output");
    }

    private static void PreviewParity()
    {
        var source = Images.Make(2400, 1600, (x, y) => x > 600 && x < 1800 && y > 400 && y < 1200 ? new Px(30, 30, 30, 255) : White);
        var state = new EditState(new CanvasStyle { Padding = 100, AutoBalance = false, Shadow = 0, Background = BackgroundKind.Solid, Color1 = Rgba.FromHex("FFFFFF") });
        state.Annotations.Add(new Annotation(AnnotationKind.Rectangle, new[] { new Point(-50, -50), new Point(300, 300) }, Rgba.FromHex("FF0000"), 12));
        var full = CanvasRenderer.Render(source, state);
        var preview = CanvasRenderer.RenderPreview(ImageLoader.Preview(source, 1400), state, maximumDimension: 1300);
        var ratio = (double)preview.PixelWidth / full.PixelWidth;
        Assert.Near(1300, Math.Max(preview.PixelWidth, preview.PixelHeight), 1, "preview size");
        var fullInk = Images.InkBounds(full, p => p.R < 100)!.Value;
        var previewInk = Images.InkBounds(preview, p => p.R < 100)!.Value;
        Assert.Near(fullInk.X * ratio, previewInk.X, 2, "ink left");
        Assert.Near(fullInk.Bottom * ratio, previewInk.Bottom, 2, "ink bottom");
        var redFull = Images.InkBounds(full, p => p.R > 200 && p.G < 60)!.Value;
        var redPreview = Images.InkBounds(preview, p => p.R > 200 && p.G < 60)!.Value;
        Assert.Near(redFull.X * ratio, redPreview.X, 2, "markup left");
    }

    private static void EncodeRoundTrips()
    {
        var source = Images.Make(31, 17, (x, y) => new Px((byte)(x * 8), (byte)(y * 15), 90, (byte)(x < 10 ? 100 : 255)));
        var png = ImageLoader.Load(ImageExporter.Data(source, ImageFormat.Png));
        Assert.True(Images.Bytes(source).SequenceEqual(Images.Bytes(png)), "PNG is lossless");
        var jpeg = ImageLoader.Load(ImageExporter.Data(source, ImageFormat.Jpeg, 0.85));
        Assert.Equal(31, jpeg.PixelWidth, "jpeg width");
        Assert.Equal((byte)255, Images.At(jpeg, 2, 2).A, "jpeg is opaque");
        Assert.Equal(ImageFormat.Jpeg, ImageFormats.ForPath(@"C:\a\b.JPEG", ImageFormat.Png), "extension wins");
    }

    private static void Limits()
    {
        Assert.ThrowsKind(VelinshotErrorKind.ImageTooLarge, () => ImageLimits.Validate(16_385, 10), "side");
        Assert.ThrowsKind(VelinshotErrorKind.ImageTooLarge, () => ImageLimits.Validate(8000, 6000), "megapixels");
        ImageLimits.Validate(16_384, 2000);
        Assert.ThrowsKind(VelinshotErrorKind.InvalidImage, () => ImageLoader.Load(Encoding.UTF8.GetBytes("not an image")), "garbage");
    }

    private static void JsonCompatibility()
    {
        const string json = """
        {"padding":12,"cornerRadius":8,"shadow":4,"background":"solid",
         "color1":{"red":1,"green":0,"blue":0,"alpha":1},
         "color2":{"red":0,"green":0,"blue":1,"alpha":1},
         "gradientAngle":15,"ratioWidth":0,"ratioHeight":0,"outputScale":1,"borderWidth":0}
        """;
        var style = VelinshotJson.Deserialize<CanvasStyle>(Encoding.UTF8.GetBytes(json));
        Assert.Equal(12.0, style.Padding, "padding");
        Assert.Equal(BackgroundKind.Solid, style.Background, "background");
        Assert.Equal(Rgba.FromHex("FFFFFF"), style.InsetColor, "inset color default");
        Assert.Equal(null, style.FixedWidth, "fixed width");
        Assert.True(style.AutoBalance && !style.AutoColor, "auto defaults");
        Assert.Equal(0.7, style.WatermarkColor.Alpha, "watermark alpha");
        Assert.Equal(WatermarkPosition.BottomRight, style.WatermarkPosition, "watermark position");
        Assert.Equal(new CanvasStyle(), VelinshotJson.Deserialize<CanvasStyle>("{}"u8.ToArray()), "empty object");
        var unknown = VelinshotJson.Deserialize<CanvasStyle>("""{"watermarkPosition":"middle"}"""u8.ToArray());
        Assert.Equal(WatermarkPosition.BottomRight, unknown.WatermarkPosition, "unknown position");
    }

    private static void JsonShapes()
    {
        var state = new EditState(new CanvasStyle { WatermarkPosition = WatermarkPosition.TopLeft }, new[]
        {
            new Annotation(AnnotationKind.Highlighter, new[] { new Point(1.5, 2), new Point(3, 4) })
        }, new Rect(1, 2, 3, 4));
        var text = Encoding.UTF8.GetString(VelinshotJson.Serialize(state));
        Assert.True(text.Contains("\"crop\":[[1,2],[3,4]]"), $"rect shape: {text}");
        Assert.True(text.Contains("\"points\":[[1.5,2],[3,4]]"), "point shape");
        Assert.True(text.Contains("\"kind\":\"highlighter\""), "kind name");
        Assert.True(text.Contains("\"watermarkPosition\":\"topLeft\""), "position name");
        Assert.True(!text.Contains("fixedWidth") && !text.Contains("backgroundAssetID"), "nil keys omitted");
        var id = state.Annotations[0].Id.ToString("D").ToUpperInvariant();
        Assert.True(text.Contains(id), "uppercase identifiers");
        var decoded = VelinshotJson.Deserialize<EditState>(Encoding.UTF8.GetBytes(text));
        Assert.True(decoded.ContentEquals(state), "round trip");
    }

    private static void ContentBounds()
    {
        var source = Images.Make(200, 100, (x, y) => x >= 50 && x < 120 && y >= 30 && y < 60 ? new Px(200, 0, 0, 255) : White);
        Assert.Equal(new Rect(48, 28, 74, 34), AutoBeautify.ContentBounds(source), "bounds with 2px margin");
        Assert.Equal(null, AutoBeautify.ContentBounds(Images.Solid(30, 30, White)), "uniform");
        var noisy = Images.Make(30, 30, (x, y) => (x + y) % 2 == 0 ? White : new Px(0, 0, 0, 255));
        Assert.Equal(null, AutoBeautify.ContentBounds(Images.Make(30, 30, (x, y) => x == 0 && y == 0 ? new Px(0, 0, 0, 255) : White)), "corners differ");
        _ = noisy;
    }

    private static void InsetColor()
    {
        var source = Images.Make(100, 100, (x, y) => x < 15 || y < 15 || x >= 85 || y >= 85 ? new Px(20, 40, 200, 255) : White);
        var color = AutoBeautify.SuggestInsetColor(source);
        Assert.Near(20 / 255.0, color.Red, 0.02, "red"); Assert.Near(200 / 255.0, color.Blue, 0.02, "blue");
        var cropped = AutoBeautify.SuggestInsetColor(source, new Rect(30, 30, 40, 40));
        Assert.Near(1, cropped.Green, 0.01, "crop sees white");
    }

    private static void SuggestedColors()
    {
        var (first, second) = AutoBeautify.SuggestColors(Images.Solid(50, 50, new Px(30, 120, 220, 255)));
        Assert.True(first.Blue > first.Red && second.Blue >= second.Red, "blue family");
        Assert.True(Math.Max(first.Red, Math.Max(first.Green, first.Blue)) > 0.85, "light first color");
    }

    private static string TempFolder(string name)
    {
        var folder = Program.Output(name);
        if (Directory.Exists(folder)) Directory.Delete(folder, true);
        Directory.CreateDirectory(folder);
        return folder;
    }

    private static void History()
    {
        var folder = TempFolder("history");
        File.WriteAllText(Path.Combine(folder, "keep-me.txt"), "user file");
        var store = new HistoryStore(folder);
        var source = Images.Solid(40, 30, new Px(10, 20, 30, 255));
        var state = new EditState(new CanvasStyle { Padding = 10 });
        var entry = store.Save(source, state);
        Assert.Equal(1, store.Entries().Count, "one entry");
        var (image, loaded) = store.Load(entry);
        Assert.Equal(40, image.PixelWidth, "image width");
        Assert.True(loaded.ContentEquals(state), "state");
        state.Style = state.Style with { Padding = 33 };
        store.Update(entry, state);
        Assert.Equal(33.0, store.Load(entry).state.Style.Padding, "updated");
        Assert.ThrowsKind(VelinshotErrorKind.InvalidHistoryPath, () => store.Load(entry with { ImageFile = "..\\evil.png" }), "path escape");
        store.Clear();
        Assert.Equal(0, store.Entries().Count, "cleared");
        Assert.True(File.Exists(Path.Combine(folder, "keep-me.txt")), "foreign file preserved");
    }

    private static void HistoryLimits()
    {
        var store = new HistoryStore(TempFolder("history-limits"), maxEntries: 3);
        var source = Images.Solid(8, 8, White);
        var first = store.Save(source, new EditState());
        for (var i = 0; i < 4; i++) { Thread.Sleep(5); store.Save(source, new EditState()); }
        var entries = store.Entries();
        Assert.Equal(3, entries.Count, "bounded count");
        Assert.True(entries.All(e => e.Id != first.Id), "oldest evicted");
    }

    private static void Presets()
    {
        var path = Path.Combine(TempFolder("presets"), "presets.json");
        var store = new PresetStore(path);
        Assert.Equal(0, store.Load().Count, "missing file");
        store.Save(new List<StylePreset> { new() { Name = "Ocean", Style = new CanvasStyle { Padding = 40 } } });
        var loaded = store.Load();
        Assert.Equal("Ocean", loaded[0].Name, "name");
        Assert.Equal(40.0, loaded[0].Style.Padding, "style");
        Assert.ThrowsKind(VelinshotErrorKind.InvalidPreset, () => store.Save(new List<StylePreset> { new() { Name = "  " } }), "blank name");
        File.WriteAllText(path, "{ nope");
        Assert.ThrowsKind(VelinshotErrorKind.InvalidPreset, () => store.Load(), "damaged file");
    }

    private static void Ocr()
    {
        var source = DemoFixture.Make();
        IReadOnlyList<RecognizedText> lines;
        try { lines = TextRecognizer.RecognizeAsync(source).GetAwaiter().GetResult(); }
        catch (VelinshotException error) when (error.Kind == VelinshotErrorKind.TextRecognitionUnavailable)
        {
            Console.WriteLine("        (skipped: no OCR language installed)");
            return;
        }
        var text = string.Join("\n", lines.Select(l => l.Text));
        File.WriteAllText(Program.Output("recognized-text.txt"), text);
        Assert.True(text.Contains("clarity", StringComparison.OrdinalIgnoreCase), $"OCR text: {text}");
    }

    private static void Bench()
    {
        var source = DemoFixture.Make();
        var proxy = ImageLoader.Preview(source);
        void Time(string label, EditState state)
        {
            CanvasRenderer.RenderPreview(proxy, state);
            var clock = Stopwatch.StartNew();
            const int runs = 5;
            for (var i = 0; i < runs; i++) CanvasRenderer.RenderPreview(proxy, state);
            Console.WriteLine($"        {label}: {clock.ElapsedMilliseconds / runs} ms per preview");
        }
        var plain = DemoFixture.State();
        plain.Style = plain.Style with { Shadow = 0 };
        Time("no shadow", plain);
        Time("shadow 30", DemoFixture.State());
        var marked = DemoFixture.State();
        marked.Annotations.Add(new Annotation(AnnotationKind.Highlighter, new[] { new Point(300, 300), new Point(900, 300) }, Rgba.FromHex("FFD400"), 6));
        marked.Annotations.Add(new Annotation(AnnotationKind.Blur, new[] { new Point(300, 500), new Point(900, 700) }, null, 6));
        Time("shadow + highlighter + blur", marked);
        // Markup-only edits reuse the cached frame, as the editor does while drawing.
        var cache = new RenderCache();
        CanvasRenderer.RenderPreview(proxy, marked, cache: cache);
        var drag = Stopwatch.StartNew();
        for (var i = 0; i < 10; i++)
        {
            marked.Annotations[0].Points[1] = new Point(1050 - i * 10, 610);
            CanvasRenderer.RenderPreview(proxy, marked, cache: cache);
        }
        Console.WriteLine($"        markup drag with cached frame: {drag.ElapsedMilliseconds / 10} ms per preview");
        var full = DemoFixture.State();
        full.Style = full.Style with { OutputScale = 2 };
        var export = Stopwatch.StartNew();
        var output = CanvasRenderer.Render(source, full);
        Console.WriteLine($"        2x export {output.PixelWidth}×{output.PixelHeight}: {export.ElapsedMilliseconds} ms");
    }

    private static void DemoRender()
    {
        var source = DemoFixture.Make();
        var clock = Stopwatch.StartNew();
        var output = CanvasRenderer.Render(source, DemoFixture.State());
        var milliseconds = clock.ElapsedMilliseconds;
        Images.Save(source, "synthetic-source.png");
        Images.Save(output, "framed-demo.png");
        File.WriteAllBytes(Program.Output("framed-demo.jpg"), ImageExporter.Data(output, ImageFormat.Jpeg, 0.85));
        clock.Restart();
        var preview = CanvasRenderer.RenderPreview(ImageLoader.Preview(source), DemoFixture.State());
        Console.WriteLine($"        export {output.PixelWidth}×{output.PixelHeight} in {milliseconds} ms; preview {preview.PixelWidth}×{preview.PixelHeight} in {clock.ElapsedMilliseconds} ms");
        Assert.Equal(1280 + 144, output.PixelWidth, "demo width");
    }
}
