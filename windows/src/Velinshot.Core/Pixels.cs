using System.Windows;
using System.Windows.Media;
using System.Windows.Media.Imaging;

namespace Velinshot.Core;

/// <summary>Premultiplied BGRA (Pbgra32) pixel buffers and the few pixel operations WPF
/// media does not provide: Gaussian blur, multiply blending and alpha masks.</summary>
internal sealed class PixelBuffer
{
    public readonly int Width;
    public readonly int Height;
    public readonly byte[] Data;

    public PixelBuffer(int width, int height, byte[]? data = null)
    {
        Width = width; Height = height;
        Data = data ?? new byte[checked(width * height * 4)];
    }

    public int Stride => Width * 4;

    public PixelBuffer Clone() => new(Width, Height, (byte[])Data.Clone());

    public static PixelBuffer From(BitmapSource source)
    {
        BitmapSource converted = source.Format == PixelFormats.Pbgra32 ? source : new FormatConvertedBitmap(source, PixelFormats.Pbgra32, null, 0);
        var buffer = new PixelBuffer(converted.PixelWidth, converted.PixelHeight);
        converted.CopyPixels(buffer.Data, buffer.Stride, 0);
        return buffer;
    }

    public BitmapSource ToBitmap()
    {
        var bitmap = BitmapSource.Create(Width, Height, 96, 96, PixelFormats.Pbgra32, null, Data, Stride);
        bitmap.Freeze();
        return bitmap;
    }

    public (byte b, byte g, byte r, byte a) this[int x, int y]
    {
        get { var i = (y * Width + x) * 4; return (Data[i], Data[i + 1], Data[i + 2], Data[i + 3]); }
    }
}

internal static class Pixels
{
    /// <summary>Decoded, detached, frozen Pbgra32 copy at 96 DPI. Every engine input is normalized here.</summary>
    public static BitmapSource Normalize(BitmapSource source) => PixelBuffer.From(source).ToBitmap();

    public static RenderTargetBitmap Target(int width, int height) => new(width, height, 96, 96, PixelFormats.Pbgra32);

    public static DrawingVisual Visual()
    {
        var visual = new DrawingVisual();
        RenderOptions.SetBitmapScalingMode(visual, BitmapScalingMode.HighQuality);
        RenderOptions.SetEdgeMode(visual, EdgeMode.Unspecified);
        RenderOptions.SetClearTypeHint(visual, ClearTypeHint.Auto);
        TextOptions.SetTextRenderingMode(visual, TextRenderingMode.Grayscale);
        TextOptions.SetTextFormattingMode(visual, TextFormattingMode.Ideal);
        return visual;
    }

    public static PixelBuffer Render(int width, int height, Action<DrawingContext> draw)
    {
        var visual = Visual();
        using (var context = visual.RenderOpen()) draw(context);
        var target = Target(width, height);
        target.Render(visual);
        var buffer = new PixelBuffer(width, height);
        target.CopyPixels(buffer.Data, buffer.Stride, 0);
        return buffer;
    }

    /// <summary>High-quality resample of <paramref name="region"/> (image pixels) to an exact raster size.</summary>
    public static BitmapSource Resample(BitmapSource image, Rect region, int width, int height)
    {
        var integral = RectMath.Integral(region);
        if (width == (int)region.Width && height == (int)region.Height && integral == region &&
            region.X >= 0 && region.Y >= 0 && region.Right <= image.PixelWidth && region.Bottom <= image.PixelHeight)
        {
            var cropped = new CroppedBitmap(image, new Int32Rect((int)region.X, (int)region.Y, width, height));
            return PixelBuffer.From(cropped).ToBitmap();
        }
        return Render(width, height, context =>
        {
            context.PushTransform(new ScaleTransform(width / region.Width, height / region.Height));
            context.PushTransform(new TranslateTransform(-region.X, -region.Y));
            context.DrawImage(image, new Rect(0, 0, image.PixelWidth, image.PixelHeight));
            context.Pop(); context.Pop();
        }).ToBitmap();
    }

    public static BitmapSource Resize(BitmapSource image, int width, int height) =>
        Resample(image, new Rect(0, 0, image.PixelWidth, image.PixelHeight), width, height);

    /// <summary>Premultiplied source-over of <paramref name="source"/> placed at (left, top):
    /// dst = src + dst × (1 − αsrc).</summary>
    public static void CompositeOver(PixelBuffer destination, PixelBuffer source, int left, int top)
    {
        var dst = destination.Data; var src = source.Data;
        for (var y = 0; y < source.Height; y++)
        {
            var targetY = top + y;
            if (targetY < 0 || targetY >= destination.Height) continue;
            for (var x = 0; x < source.Width; x++)
            {
                var targetX = left + x;
                if (targetX < 0 || targetX >= destination.Width) continue;
                var s = (y * source.Width + x) * 4;
                int alpha = src[s + 3];
                if (alpha == 0) continue;
                var d = (targetY * destination.Width + targetX) * 4;
                if (alpha == 255) { dst[d] = src[s]; dst[d + 1] = src[s + 1]; dst[d + 2] = src[s + 2]; dst[d + 3] = 255; continue; }
                var inverse = 255 - alpha;
                dst[d] = (byte)(src[s] + (dst[d] * inverse + 127) / 255);
                dst[d + 1] = (byte)(src[s + 1] + (dst[d + 1] * inverse + 127) / 255);
                dst[d + 2] = (byte)(src[s + 2] + (dst[d + 2] * inverse + 127) / 255);
                dst[d + 3] = (byte)(alpha + (dst[d + 3] * inverse + 127) / 255);
            }
        }
    }

    /// <summary>Separable multiply blend (W3C compositing) of a premultiplied layer at an opacity.</summary>
    public static void CompositeMultiply(PixelBuffer destination, PixelBuffer source, int left, int top, double opacity)
    {
        var dst = destination.Data; var src = source.Data;
        for (var y = 0; y < source.Height; y++)
        {
            var targetY = top + y;
            if (targetY < 0 || targetY >= destination.Height) continue;
            for (var x = 0; x < source.Width; x++)
            {
                var targetX = left + x;
                if (targetX < 0 || targetX >= destination.Width) continue;
                var s = (y * source.Width + x) * 4;
                if (src[s + 3] == 0) continue;
                var d = (targetY * destination.Width + targetX) * 4;
                var sa = src[s + 3] / 255.0 * opacity;
                var da = dst[d + 3] / 255.0;
                for (var c = 0; c < 3; c++)
                {
                    var cs = src[s + c] / 255.0 * opacity;
                    var cd = dst[d + c] / 255.0;
                    dst[d + c] = (byte)Math.Round(Math.Clamp(cs * (1 - da) + cd * (1 - sa) + cs * cd, 0, 1) * 255);
                }
                dst[d + 3] = (byte)Math.Round(Math.Clamp(sa + da - sa * da, 0, 1) * 255);
            }
        }
    }

    /// <summary>Flattens premultiplied pixels onto opaque white in place.</summary>
    public static void FlattenOnWhite(PixelBuffer buffer)
    {
        var data = buffer.Data;
        for (var i = 0; i < data.Length; i += 4)
        {
            var add = 255 - data[i + 3];
            data[i] = (byte)Math.Min(255, data[i] + add);
            data[i + 1] = (byte)Math.Min(255, data[i + 1] + add);
            data[i + 2] = (byte)Math.Min(255, data[i + 2] + add);
            data[i + 3] = 255;
        }
    }

    /// <summary>Gaussian blur approximated by three box passes per axis (sigma in pixels).
    /// <paramref name="clampEdges"/> extends edge pixels (Core Image clampedToExtent); otherwise
    /// samples outside the buffer are transparent, as for a Quartz shadow.</summary>
    public static void GaussianBlur(float[] channel, int width, int height, double sigma, bool clampEdges)
    {
        if (sigma < 0.5 || width == 0 || height == 0) return;
        var scratch = new float[channel.Length];
        foreach (var size in BoxSizes(sigma))
        {
            var radius = (size - 1) / 2;
            BoxHorizontal(channel, scratch, width, height, radius, clampEdges);
            BoxVertical(scratch, channel, width, height, radius, clampEdges);
        }
    }

    public static void GaussianBlur(PixelBuffer buffer, double sigma, bool clampEdges)
    {
        if (sigma < 0.5) return;
        var count = buffer.Width * buffer.Height;
        var channel = new float[count];
        for (var c = 0; c < 4; c++)
        {
            for (int p = 0, i = c; p < count; p++, i += 4) channel[p] = buffer.Data[i];
            GaussianBlur(channel, buffer.Width, buffer.Height, sigma, clampEdges);
            for (int p = 0, i = c; p < count; p++, i += 4) buffer.Data[i] = (byte)Math.Clamp(Math.Round(channel[p]), 0, 255);
        }
        // Rounding can leave a color channel above its alpha; keep the buffer validly premultiplied.
        for (var i = 0; i < buffer.Data.Length; i += 4)
        {
            var a = buffer.Data[i + 3];
            if (buffer.Data[i] > a) buffer.Data[i] = a;
            if (buffer.Data[i + 1] > a) buffer.Data[i + 1] = a;
            if (buffer.Data[i + 2] > a) buffer.Data[i + 2] = a;
        }
    }

    private static int[] BoxSizes(double sigma, int passes = 3)
    {
        var ideal = Math.Sqrt(12 * sigma * sigma / passes + 1);
        var lower = (int)Math.Floor(ideal);
        if (lower % 2 == 0) lower--;
        var upper = lower + 2;
        var mIdeal = (12 * sigma * sigma - passes * lower * lower - 4 * passes * lower - 3 * passes) / (-4.0 * lower - 4);
        var m = (int)Math.Round(mIdeal);
        return Enumerable.Range(0, passes).Select(i => i < m ? lower : upper).ToArray();
    }

    private static void BoxHorizontal(float[] source, float[] target, int width, int height, int radius, bool clamp)
    {
        if (radius <= 0) { Array.Copy(source, target, source.Length); return; }
        var scale = 1f / (radius * 2 + 1);
        for (var y = 0; y < height; y++)
        {
            var row = y * width;
            var first = clamp ? source[row] : 0f;
            var last = clamp ? source[row + width - 1] : 0f;
            float sum = 0;
            for (var x = -radius; x <= radius; x++) sum += x < 0 ? first : x >= width ? last : source[row + x];
            for (var x = 0; x < width; x++)
            {
                target[row + x] = sum * scale;
                var add = x + radius + 1;
                var remove = x - radius;
                sum += (add < width ? source[row + add] : last) - (remove >= 0 ? source[row + remove] : first);
            }
        }
    }

    /// <summary>Row-ordered vertical pass: one running sum per column keeps memory access sequential.</summary>
    private static void BoxVertical(float[] source, float[] target, int width, int height, int radius, bool clamp)
    {
        if (radius <= 0) { Array.Copy(source, target, source.Length); return; }
        var scale = 1f / (radius * 2 + 1);
        var sums = new float[width];
        var lastRow = (height - 1) * width;
        for (var y = -radius; y <= radius; y++)
        {
            if (y >= 0 && y < height) { var row = y * width; for (var x = 0; x < width; x++) sums[x] += source[row + x]; }
            else if (clamp) { var row = y < 0 ? 0 : lastRow; for (var x = 0; x < width; x++) sums[x] += source[row + x]; }
        }
        for (var y = 0; y < height; y++)
        {
            var row = y * width;
            for (var x = 0; x < width; x++) target[row + x] = sums[x] * scale;
            var add = y + radius + 1;
            var remove = y - radius;
            var addRow = add < height ? add * width : clamp ? lastRow : -1;
            var removeRow = remove >= 0 ? remove * width : clamp ? 0 : -1;
            if (addRow >= 0) for (var x = 0; x < width; x++) sums[x] += source[addRow + x];
            if (removeRow >= 0) for (var x = 0; x < width; x++) sums[x] -= source[removeRow + x];
        }
    }
}

/// <summary>Holds the last framed base raster so markup edits do not re-render the frame.
/// Use one cache per document, from one thread at a time.</summary>
public sealed class RenderCache
{
    internal object? Key;
    internal PixelBuffer? Base;
    public void Clear() { Key = null; Base = null; }
}
