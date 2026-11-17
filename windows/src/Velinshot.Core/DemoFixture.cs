using System.Windows;
using System.Windows.Media;
using System.Windows.Media.Imaging;

namespace Velinshot.Core;

/// <summary>A synthetic screenshot for documentation, the Help menu demo and smoke checks.
/// It contains no real application or personal content.</summary>
public static class DemoFixture
{
    public static BitmapSource Make()
    {
        const int width = 1280, height = 800;
        var buffer = Pixels.Render(width, height, context =>
        {
            void Fill(Rect rect, string hex, double radius = 0) =>
                context.DrawRoundedRectangle(new SolidColorBrush(Rgba.FromHex(hex).ToColor()), null, rect, radius, radius);
            void Text(string value, double x, double y, double size, string hex = "232436", FontWeight? weight = null) =>
                context.DrawText(TextMetrics.Format(value, size, weight ?? FontWeights.Normal, new SolidColorBrush(Rgba.FromHex(hex).ToColor())), new Point(x, y));

            Fill(new Rect(0, 0, 1280, 800), "FBFAFD");
            Fill(new Rect(0, 0, 1280, 64), "F0EEF5");
            var dots = new[] { "F47073", "F7C45C", "70CA8E" };
            for (var i = 0; i < dots.Length; i++) Fill(new Rect(24 + i * 24, 25, 12, 12), dots[i], 6);
            Text("Studio / Launch notes", 138, 21, 18, "666174", FontWeights.Medium);
            Fill(new Rect(0, 64, 226, 736), "F5F3F8");
            Text("STUDIO", 28, 103, 14, "7160E8", FontWeights.Bold);
            Text("Workspace", 28, 146, 26, "232436", FontWeights.SemiBold);
            Fill(new Rect(16, 210, 194, 44), "E8E3FA", 10);
            Text("Overview", 34, 221, 16, "6352CD", FontWeights.SemiBold);
            var labels = new[] { "Notes", "Files", "Archive" };
            for (var i = 0; i < labels.Length; i++) Text(labels[i], 34, 283 + i * 54, 16, "80798C");
            Text("A little more clarity.", 280, 120, 48, "262336", FontWeights.Bold);
            Text("Good things happen when the details have room to breathe.", 283, 191, 19, "787184");
            Fill(new Rect(282, 259, 938, 175), "EAE5FC", 18);
            Text("Make room for what matters.", 315, 290, 30, "5B49B5", FontWeights.SemiBold);
            Text("A note, a mark, a little context. Then share it.", 315, 343, 19, "71658C");
            Fill(new Rect(315, 385, 145, 20), "D5CDF3", 6);
            Text("Ready to share", 485, 382, 15, "71658C", FontWeights.Medium);
            Text("The small details", 282, 478, 24, "262336", FontWeights.SemiBold);
            var tasks = new[] { ("Capture the idea", "Start with one clear moment."), ("Add what matters", "An arrow can say a lot."), ("Share the moment", "Good work travels light.") };
            for (var i = 0; i < tasks.Length; i++)
            {
                double y = 533 + i * 76;
                Fill(new Rect(282, y, 36, 36), "EFECF8", 10);
                Text((i + 1).ToString(), 294, y + 7, 17, "7160E8", FontWeights.SemiBold);
                Text(tasks[i].Item1, 337, y - 1, 18, "3B364C", FontWeights.SemiBold);
                Text(tasks[i].Item2, 337, y + 27, 15, "8B8397");
            }
        });
        return buffer.ToBitmap();
    }

    public static EditState State() => new(new CanvasStyle { Padding = 72, CornerRadius = 24, Shadow = 30, AutoBalance = false }, new[]
    {
        new Annotation(AnnotationKind.Arrow, new[] { new Point(1050, 610), new Point(825, 491) }, Rgba.FromHex("EC687C"), 7),
        new Annotation(AnnotationKind.Rectangle, new[] { new Point(327, 603), new Point(715, 662) }, Rgba.FromHex("7160E8"), 4)
    });
}
