using System.Windows;
using System.Windows.Media.Imaging;

namespace Velinshot.Core;

public static class AutoBeautify
{
    private static readonly Rgba White = new(1, 1, 1);
    private static readonly (Rgba, Rgba) DefaultPair = (Rgba.FromHex("B7AEF8"), Rgba.FromHex("E6E3FF"));

    /// <summary>Selects a dominant visible edge palette color without mixing unrelated bins.
    /// <paramref name="crop"/> is in the original source's top-left pixel space.</summary>
    public static Rgba SuggestInsetColor(BitmapSource source, Rect? crop = null)
    {
        var visible = source;
        if (crop is { } requested)
        {
            if (!RectMath.IsFinite(requested) || requested.Width <= 0 || requested.Height <= 0) return White;
            var bounds = new Rect(0, 0, source.PixelWidth, source.PixelHeight);
            var clipped = Rect.Intersect(requested, bounds);
            if (clipped.IsEmpty) return White;
            clipped = Rect.Intersect(RectMath.Integral(clipped), bounds);
            if (clipped.IsEmpty || clipped.Width < 1 || clipped.Height < 1) return White;
            visible = new CroppedBitmap(source, new Int32Rect((int)clipped.X, (int)clipped.Y, (int)clipped.Width, (int)clipped.Height));
        }
        var sample = Sample(visible, 64);
        var bins = new Dictionary<int, (long weight, double red, double green, double blue)>();
        var band = Math.Max(1, Math.Min(sample.Width, sample.Height) / 8);
        void Collect(bool edgesOnly)
        {
            for (var y = 0; y < sample.Height; y++)
            for (var x = 0; x < sample.Width; x++)
            {
                if (edgesOnly && !(x < band || x >= sample.Width - band || y < band || y >= sample.Height - band)) continue;
                var (b, g, r, a) = sample[x, y];
                if (a < 26) continue;
                var red = Math.Min(1, (double)r / a);
                var green = Math.Min(1, (double)g / a);
                var blue = Math.Min(1, (double)b / a);
                static int Channel5(double value) => Math.Min(255, Math.Max(0, (int)Math.Round(value * 255))) >> 3;
                var key = (Channel5(red) << 10) | (Channel5(green) << 5) | Channel5(blue);
                bins.TryGetValue(key, out var bin);
                bins[key] = (bin.weight + a, bin.red + red * a, bin.green + green * a, bin.blue + blue * a);
            }
        }
        Collect(edgesOnly: true);
        if (bins.Count == 0) Collect(edgesOnly: false);
        var winnerKey = int.MaxValue;
        (long weight, double red, double green, double blue) winner = default;
        foreach (var (key, bin) in bins)
        {
            if (bin.weight > winner.weight || (bin.weight == winner.weight && key < winnerKey)) { winner = bin; winnerKey = key; }
        }
        if (winner.weight <= 0) return White;
        double weight = winner.weight;
        return new Rgba(winner.red / weight, winner.green / weight, winner.blue / weight);
    }

    public static (Rgba first, Rgba second) SuggestColors(BitmapSource source)
    {
        var sample = Sample(source, 64);
        double red = 0, green = 0, blue = 0, weight = 0;
        var band = Math.Max(1, Math.Min(sample.Width, sample.Height) / 8);
        for (var y = 0; y < sample.Height; y++)
        for (var x = 0; x < sample.Width; x++)
        {
            // A fixed outer-eighth band reflects the screenshot's surround instead of
            // allowing a bright center element to dominate it.
            if (!(x < band || x >= sample.Width - band || y < band || y >= sample.Height - band)) continue;
            var (b, g, r, a) = sample[x, y];
            var alpha = a / 255.0;
            if (alpha <= 0.1) continue;
            red += r / Math.Max(1.0, a) * alpha;
            green += g / Math.Max(1.0, a) * alpha;
            blue += b / Math.Max(1.0, a) * alpha;
            weight += alpha;
        }
        if (weight <= 0) return DefaultPair;
        var (hue, saturation, _) = ToHsb(red / weight, green / weight, blue / weight);
        if (saturation < 0.08) hue = 0.68;
        var first = FromHsb(hue, Math.Min(0.38, Math.Max(0.15, saturation * 0.65)), 0.90);
        var second = FromHsb((hue + 0.04) % 1, Math.Min(0.16, Math.Max(0.06, saturation * 0.3)), 1);
        return (first, second);
    }

    /// <summary>Finds exact content bounds at source resolution inside a uniform (or
    /// transparent) border. Returns null when there is no border to trim.</summary>
    public static Rect? ContentBounds(BitmapSource source)
    {
        var sample = PixelBuffer.From(source);
        var corners = new[] { sample[0, 0], sample[sample.Width - 1, 0], sample[0, sample.Height - 1], sample[sample.Width - 1, sample.Height - 1] };
        var reference = corners[0];
        var transparentBorder = corners.All(c => c.a < 8);
        if (!transparentBorder && !corners.All(c => Distance(c, reference) < 10)) return null;
        bool IsContent(int x, int y)
        {
            var pixel = sample[x, y];
            return transparentBorder ? pixel.a > 8 : Distance(pixel, reference) > 10;
        }
        bool RowHasContent(int y) { for (var x = 0; x < sample.Width; x++) if (IsContent(x, y)) return true; return false; }
        var minY = 0;
        while (minY < sample.Height && !RowHasContent(minY)) minY++;
        if (minY >= sample.Height) return null;
        var maxY = sample.Height - 1;
        while (maxY > minY && !RowHasContent(maxY)) maxY--;
        bool ColumnHasContent(int x) { for (var y = minY; y <= maxY; y++) if (IsContent(x, y)) return true; return false; }
        var minX = 0;
        while (minX < sample.Width && !ColumnHasContent(minX)) minX++;
        var maxX = sample.Width - 1;
        while (maxX > minX && !ColumnHasContent(maxX)) maxX--;
        // Preserve a small safety edge around anti-aliased content.
        const int margin = 2;
        int left = Math.Max(0, minX - margin), top = Math.Max(0, minY - margin);
        int right = Math.Min(sample.Width, maxX + 1 + margin), bottom = Math.Min(sample.Height, maxY + 1 + margin);
        var bounds = new Rect(left, top, right - left, bottom - top);
        return bounds == new Rect(0, 0, sample.Width, sample.Height) ? null : bounds;
    }

    private static PixelBuffer Sample(BitmapSource source, int maximumDimension)
    {
        var scale = Math.Min(1, (double)maximumDimension / Math.Max(source.PixelWidth, source.PixelHeight));
        if (scale >= 1) return PixelBuffer.From(source);
        var width = Math.Max(1, (int)Math.Round(source.PixelWidth * scale));
        var height = Math.Max(1, (int)Math.Round(source.PixelHeight * scale));
        return PixelBuffer.From(Pixels.Resize(source, width, height));
    }

    private static int Distance((byte b, byte g, byte r, byte a) x, (byte b, byte g, byte r, byte a) y) =>
        Math.Max(Math.Max(Math.Abs(x.b - y.b), Math.Abs(x.g - y.g)), Math.Max(Math.Abs(x.r - y.r), Math.Abs(x.a - y.a)));

    private static (double hue, double saturation, double brightness) ToHsb(double r, double g, double b)
    {
        var max = Math.Max(r, Math.Max(g, b));
        var min = Math.Min(r, Math.Min(g, b));
        var delta = max - min;
        double hue = 0;
        if (delta > 0)
        {
            if (max == r) hue = (g - b) / delta % 6;
            else if (max == g) hue = (b - r) / delta + 2;
            else hue = (r - g) / delta + 4;
            hue /= 6;
            if (hue < 0) hue += 1;
        }
        return (hue, max <= 0 ? 0 : delta / max, max);
    }

    private static Rgba FromHsb(double hue, double saturation, double brightness)
    {
        var h = hue * 6;
        var sector = (int)Math.Floor(h) % 6;
        var f = h - Math.Floor(h);
        var p = brightness * (1 - saturation);
        var q = brightness * (1 - saturation * f);
        var t = brightness * (1 - saturation * (1 - f));
        var (r, g, b) = sector switch
        {
            0 => (brightness, t, p), 1 => (q, brightness, p), 2 => (p, brightness, t),
            3 => (p, q, brightness), 4 => (t, p, brightness), _ => (brightness, p, q)
        };
        return new Rgba(r, g, b);
    }
}
