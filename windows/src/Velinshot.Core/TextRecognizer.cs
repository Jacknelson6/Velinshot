using System.Runtime.InteropServices.WindowsRuntime;
using System.Windows;
using System.Windows.Media.Imaging;
using Windows.Graphics.Imaging;
using Windows.Media.Ocr;

namespace Velinshot.Core;

public sealed record RecognizedText(string Text, Rect Rect);

/// <summary>Local OCR with the Windows OCR engine (Windows.Media.Ocr). Nothing leaves the PC.
/// Uses the user's profile languages; Windows needs at least one OCR-capable language installed.</summary>
public static class TextRecognizer
{
    public static async Task<IReadOnlyList<RecognizedText>> RecognizeAsync(BitmapSource image)
    {
        ImageLimits.Validate(image.PixelWidth, image.PixelHeight);
        var engine = OcrEngine.TryCreateFromUserProfileLanguages()
                     ?? throw new VelinshotException(VelinshotErrorKind.TextRecognitionUnavailable,
                         "Add a language with optical character recognition in Windows Settings › Time & language › Language & region.");
        // The engine accepts a bounded image size; analyze a reduced copy and map regions back.
        var maximum = (double)OcrEngine.MaxImageDimension;
        var scale = Math.Min(1, maximum / Math.Max(image.PixelWidth, image.PixelHeight));
        var input = scale < 1
            ? Pixels.Resize(image, Math.Max(1, (int)(image.PixelWidth * scale)), Math.Max(1, (int)(image.PixelHeight * scale)))
            : image;
        var buffer = PixelBuffer.From(input);
        Pixels.FlattenOnWhite(buffer);
        using var bitmap = SoftwareBitmap.CreateCopyFromBuffer(buffer.Data.AsBuffer(), BitmapPixelFormat.Bgra8,
                                                               buffer.Width, buffer.Height, BitmapAlphaMode.Premultiplied);
        var result = await engine.RecognizeAsync(bitmap);
        var lines = new List<RecognizedText>();
        foreach (var line in result.Lines)
        {
            var bounds = Rect.Empty;
            foreach (var word in line.Words)
            {
                var box = word.BoundingRect;
                bounds.Union(new Rect(box.X / scale, box.Y / scale, box.Width / scale, box.Height / scale));
            }
            lines.Add(new RecognizedText(line.Text, bounds.IsEmpty ? new Rect() : bounds));
        }
        // The engine reports lines in reading order.
        return lines;
    }
}
