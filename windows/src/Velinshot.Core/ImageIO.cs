using System.IO;
using System.Windows;
using System.Windows.Media;
using System.Windows.Media.Imaging;

namespace Velinshot.Core;

public enum ImageFormat { Png, Jpeg }

public static class ImageFormats
{
    public static string Extension(this ImageFormat format) => format == ImageFormat.Png ? "png" : "jpg";

    /// <summary>The destination's extension wins over the selected format.</summary>
    public static ImageFormat ForPath(string path, ImageFormat selected) =>
        Path.GetExtension(path).ToLowerInvariant() switch
        {
            ".png" => ImageFormat.Png,
            ".jpg" or ".jpeg" => ImageFormat.Jpeg,
            _ => selected
        };
}

public static class ImageExporter
{
    public static byte[] Data(BitmapSource image, ImageFormat format, double quality = 0.9)
    {
        ImageLimits.Validate(image.PixelWidth, image.PixelHeight);
        if (!double.IsFinite(quality)) throw VelinshotException.EncodingFailed();
        try
        {
            BitmapEncoder encoder;
            BitmapSource output;
            if (format == ImageFormat.Jpeg)
            {
                // JPEG has no alpha: flatten onto white first, as the macOS app does.
                var flattened = PixelBuffer.From(image);
                Pixels.FlattenOnWhite(flattened);
                output = new FormatConvertedBitmap(flattened.ToBitmap(), PixelFormats.Bgr24, null, 0);
                encoder = new JpegBitmapEncoder { QualityLevel = (int)Math.Clamp(Math.Round(quality * 100), 1, 100) };
            }
            else
            {
                output = new FormatConvertedBitmap(image, PixelFormats.Bgra32, null, 0);
                encoder = new PngBitmapEncoder { Interlace = PngInterlaceOption.Off };
            }
            encoder.Frames.Add(BitmapFrame.Create(output));
            using var stream = new MemoryStream();
            encoder.Save(stream);
            return stream.ToArray();
        }
        catch (Exception error) when (error is not VelinshotException)
        {
            throw VelinshotException.EncodingFailed();
        }
    }
}

public sealed record ImageMetadata(Size PixelSize, string Format, int EncodedByteCount);

/// <summary>A display proxy with an original-pixel coordinate space. Its bitmap is internal
/// so app export paths cannot accidentally consume the reduced raster.</summary>
public sealed class ImagePreview
{
    public Size SourceSize { get; }
    internal BitmapSource Bitmap { get; }
    public Size PixelSize => new(Bitmap.PixelWidth, Bitmap.PixelHeight);

    internal ImagePreview(Size sourceSize, BitmapSource bitmap) { SourceSize = sourceSize; Bitmap = bitmap; }
}

/// <summary>A frozen input, independent of later changes to the original file.</summary>
public sealed class EncodedImageSource
{
    private readonly byte[] data;
    public ImageMetadata Metadata { get; }

    internal EncodedImageSource(byte[] data, ImageMetadata metadata) { this.data = data; Metadata = metadata; }

    public BitmapSource FullResolution() => ImageLoader.Load(data);
    public ImagePreview Preview(int maxDimension = 1400) => ImageLoader.Preview(FullResolution(), maxDimension);
}

public static class ImageLoader
{
    public const int MaximumEncodedBytes = 250_000_000;

    public static BitmapSource Load(string path) => Open(path).FullResolution();

    public static EncodedImageSource Open(string path)
    {
        var info = new FileInfo(path);
        if (!info.Exists || info.Attributes.HasFlag(FileAttributes.Directory))
            throw VelinshotException.InvalidImage("Choose a regular image file.");
        if (info.Length > MaximumEncodedBytes) throw VelinshotException.TooLarge();
        byte[] data;
        using (var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete))
        {
            // Read at most one byte past the limit so a file that grows mid-read is rejected.
            data = new byte[Math.Min(MaximumEncodedBytes + 1L, Math.Max(0, info.Length) + 1)];
            var total = 0;
            int read;
            while ((read = stream.Read(data, total, data.Length - total)) > 0)
            {
                total += read;
                if (total == data.Length)
                {
                    if (total > MaximumEncodedBytes) throw VelinshotException.TooLarge();
                    Array.Resize(ref data, (int)Math.Min(MaximumEncodedBytes + 1L, data.Length * 2L));
                }
            }
            Array.Resize(ref data, total);
        }
        return Open(data);
    }

    public static EncodedImageSource Open(byte[] data)
    {
        if (data.Length > MaximumEncodedBytes) throw VelinshotException.TooLarge();
        var (frame, decoder) = Decode(data);
        var orientation = Orientation(frame);
        var size = orientation >= 5 ? new Size(frame.PixelHeight, frame.PixelWidth) : new Size(frame.PixelWidth, frame.PixelHeight);
        return new EncodedImageSource(data, new ImageMetadata(size, decoder.CodecInfo?.FriendlyName ?? "Image", data.Length));
    }

    public static BitmapSource Load(byte[] data)
    {
        if (data.Length > MaximumEncodedBytes) throw VelinshotException.TooLarge();
        var (frame, _) = Decode(data);
        try
        {
            var oriented = ApplyOrientation(frame, Orientation(frame));
            var image = Pixels.Normalize(oriented);
            ImageLimits.Validate(image.PixelWidth, image.PixelHeight);
            return image;
        }
        catch (Exception error) when (error is not VelinshotException)
        {
            throw VelinshotException.InvalidImage("The image could not be decoded.");
        }
    }

    /// <summary>Accepts an in-memory bitmap (capture, clipboard) and normalizes it to the engine format.</summary>
    public static BitmapSource Adopt(BitmapSource image)
    {
        ImageLimits.Validate(image.PixelWidth, image.PixelHeight);
        return Pixels.Normalize(image);
    }

    public static ImagePreview Preview(BitmapSource image, int maxDimension = 1400)
    {
        if (maxDimension < 1 || maxDimension > 4096) throw VelinshotException.InvalidImage("Preview size must be between 1 and 4096 pixels.");
        ImageLimits.Validate(image.PixelWidth, image.PixelHeight);
        var sourceSize = new Size(image.PixelWidth, image.PixelHeight);
        var scale = Math.Min(1, maxDimension / Math.Max(sourceSize.Width, sourceSize.Height));
        if (scale >= 1) return new ImagePreview(sourceSize, image);
        var width = Math.Max(1, (int)Math.Round(sourceSize.Width * scale));
        var height = Math.Max(1, (int)Math.Round(sourceSize.Height * scale));
        return new ImagePreview(sourceSize, Pixels.Resize(image, width, height));
    }

    private static (BitmapFrame, BitmapDecoder) Decode(byte[] data)
    {
        BitmapDecoder decoder;
        try
        {
            decoder = BitmapDecoder.Create(new MemoryStream(data, writable: false),
                BitmapCreateOptions.PreservePixelFormat | BitmapCreateOptions.IgnoreColorProfile, BitmapCacheOption.None);
        }
        catch (Exception)
        {
            throw VelinshotException.InvalidImage("The file format is unsupported or the file is damaged.");
        }
        if (decoder.Frames.Count == 0) throw VelinshotException.InvalidImage("The image has no readable dimensions.");
        var frame = decoder.Frames[0];
        // Reject oversized headers before any pixels are decoded.
        ImageLimits.Validate(frame.PixelWidth, frame.PixelHeight);
        return (frame, decoder);
    }

    private static int Orientation(BitmapFrame frame)
    {
        try
        {
            if (frame.Metadata is BitmapMetadata metadata && metadata.ContainsQuery("System.Photo.Orientation") &&
                metadata.GetQuery("System.Photo.Orientation") is ushort value && value is >= 1 and <= 8)
                return value;
        }
        catch (Exception) { /* Formats without a metadata reader have no orientation. */ }
        return 1;
    }

    private static BitmapSource ApplyOrientation(BitmapSource image, int orientation)
    {
        if (orientation <= 1) return image;
        var transform = new TransformGroup();
        switch (orientation)
        {
            case 2: transform.Children.Add(new ScaleTransform(-1, 1)); break;
            case 3: transform.Children.Add(new RotateTransform(180)); break;
            case 4: transform.Children.Add(new ScaleTransform(1, -1)); break;
            case 5: transform.Children.Add(new ScaleTransform(-1, 1)); transform.Children.Add(new RotateTransform(270)); break;
            case 6: transform.Children.Add(new RotateTransform(90)); break;
            case 7: transform.Children.Add(new ScaleTransform(-1, 1)); transform.Children.Add(new RotateTransform(90)); break;
            case 8: transform.Children.Add(new RotateTransform(270)); break;
        }
        return new TransformedBitmap(image, transform);
    }
}
