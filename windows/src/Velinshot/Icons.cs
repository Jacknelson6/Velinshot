using System.Windows;
using System.Windows.Controls;
using System.Windows.Data;
using System.Windows.Documents;
using System.Windows.Media;
using System.Windows.Shapes;

namespace Velinshot;

/// <summary>Line icons drawn on a 24-unit grid, stroked in the control's foreground color,
/// so they stay crisp at any DPI and identical on Windows 10 and 11.</summary>
internal static class Icons
{
    private static readonly Dictionary<string, (string Stroke, string? Fill)> Paths = new()
    {
        ["select"] = ("M6.5,3.5 L6.5,19 L10.4,15.3 L13,21 L15.6,19.8 L13,14.2 L18.4,14.2 Z", null),
        ["pen"] = ("M4.5,19.5 L5.3,15.8 L15.6,5.5 A2,2 0 0 1 18.5,8.4 L8.2,18.7 Z M13.8,7.3 L16.7,10.2", null),
        ["arrow"] = ("M6,18 L18,6 M9.5,6 L18,6 L18,14.5", null),
        ["rectangle"] = ("M5.5,5.5 H18.5 A1.5,1.5 0 0 1 20,7 V17 A1.5,1.5 0 0 1 18.5,18.5 H5.5 A1.5,1.5 0 0 1 4,17 V7 A1.5,1.5 0 0 1 5.5,5.5 Z", null),
        ["ellipse"] = ("M20,12 A8,8 0 1 1 4,12 A8,8 0 1 1 20,12 Z", null),
        ["text"] = ("M5,7 V4.5 H19 V7 M12,4.5 V19.5 M9,19.5 H15", null),
        ["highlighter"] = ("M15,4 L20,9 L10.5,18.5 L5.5,13.5 Z M5.5,13.5 L3.8,19.8 L10.5,18.5 M13.5,21 H20.5", null),
        ["blur"] = ("M12,3.2 C12,3.2 5.5,10.2 5.5,14.5 A6.5,6.5 0 0 0 18.5,14.5 C18.5,10.2 12,3.2 12,3.2 Z",
                    "M12,3.2 C12,3.2 18.5,10.2 18.5,14.5 A6.5,6.5 0 0 1 12,21 Z"),
        ["redact"] = ("M5.5,6 H18.5 A1.5,1.5 0 0 1 20,7.5 V16.5 A1.5,1.5 0 0 1 18.5,18 H5.5 A1.5,1.5 0 0 1 4,16.5 V7.5 A1.5,1.5 0 0 1 5.5,6 Z",
                      "M5.5,6 H18.5 A1.5,1.5 0 0 1 20,7.5 V16.5 A1.5,1.5 0 0 1 18.5,18 H5.5 A1.5,1.5 0 0 1 4,16.5 V7.5 A1.5,1.5 0 0 1 5.5,6 Z"),
        ["number"] = ("M20,12 A8,8 0 1 1 4,12 A8,8 0 1 1 20,12 Z M10.3,9.6 L12.6,8 V16 M10.3,16 H14.8", null),
        ["crop"] = ("M7,3 V17 H21 M3,7 H17 V21", null),
        ["line"] = ("M5,19 L19,5", null),
        ["more"] = ("", "M7,12 A1.6,1.6 0 1 1 3.8,12 A1.6,1.6 0 1 1 7,12 Z M13.6,12 A1.6,1.6 0 1 1 10.4,12 A1.6,1.6 0 1 1 13.6,12 Z M20.2,12 A1.6,1.6 0 1 1 17,12 A1.6,1.6 0 1 1 20.2,12 Z"),
        ["capture"] = ("M4,8.5 V5.5 A1.5,1.5 0 0 1 5.5,4 H8.5 M15.5,4 H18.5 A1.5,1.5 0 0 1 20,5.5 V8.5 M20,15.5 V18.5 A1.5,1.5 0 0 1 18.5,20 H15.5 M8.5,20 H5.5 A1.5,1.5 0 0 1 4,18.5 V15.5 M14.6,12 A2.6,2.6 0 1 1 9.4,12 A2.6,2.6 0 1 1 14.6,12 Z", null),
        ["undo"] = ("M8.5,5 L4,9.5 L8.5,14 M4,9.5 H14 A5,5 0 0 1 14,19.5 H10", null),
        ["redo"] = ("M15.5,5 L20,9.5 L15.5,14 M20,9.5 H10 A5,5 0 0 0 10,19.5 H14", null),
        ["copy"] = ("M9,8.5 H18 A2,2 0 0 1 20,10.5 V18 A2,2 0 0 1 18,20 H11 A2,2 0 0 1 9,18 Z M15.5,8.5 V6 A2,2 0 0 0 13.5,4 H6 A2,2 0 0 0 4,6 V13.5 A2,2 0 0 0 6,15.5 H9", null),
        ["save"] = ("M12,4 V14.5 M7.5,10 L12,14.5 L16.5,10 M4,14.5 V18.5 A1.5,1.5 0 0 0 5.5,20 H18.5 A1.5,1.5 0 0 0 20,18.5 V14.5", null),
        ["chevron-right"] = ("M9.5,6 L15.5,12 L9.5,18", null),
        ["chevron-down"] = ("M6,9.5 L12,15.5 L18,9.5", null),
        ["back"] = ("M19,12 H5 M11,6 L5,12 L11,18", null),
        ["photo"] = ("M5.5,5 H18.5 A1.5,1.5 0 0 1 20,6.5 V17.5 A1.5,1.5 0 0 1 18.5,19 H5.5 A1.5,1.5 0 0 1 4,17.5 V6.5 A1.5,1.5 0 0 1 5.5,5 Z M4,16 L9,11 L13,15 L15.5,12.5 L20,17 M17.2,8.8 A1.2,1.2 0 1 1 14.8,8.8 A1.2,1.2 0 1 1 17.2,8.8 Z", null),
        ["desktop"] = ("M5,4.5 H19 A1.5,1.5 0 0 1 20.5,6 V14.5 A1.5,1.5 0 0 1 19,16 H5 A1.5,1.5 0 0 1 3.5,14.5 V6 A1.5,1.5 0 0 1 5,4.5 Z M9,20 H15 M12,16 V20", null),
        ["wand"] = ("M4,20 L14.5,9.5 M12.5,7.5 L16.5,11.5 M18,3 V6.5 M16.25,4.75 H19.75 M19.5,10.5 V13 M18.25,11.75 H20.75 M8.5,3.5 V6 M7.25,4.75 H9.75", null),
        ["plus"] = ("M12,5 V19 M5,12 H19", null),
        ["minus"] = ("M5,12 H19", null),
        ["folder"] = ("M3.5,7 A1.5,1.5 0 0 1 5,5.5 H9.5 L11.5,7.5 H19 A1.5,1.5 0 0 1 20.5,9 V17.5 A1.5,1.5 0 0 1 19,19 H5 A1.5,1.5 0 0 1 3.5,17.5 Z", null),
        ["clock"] = ("M20,12 A8,8 0 1 1 4,12 A8,8 0 1 1 20,12 Z M12,7.5 V12 L15,14", null),
        ["settings"] = ("M4,7 H13 M17,7 H20 M4,17 H7 M11,17 H20 M15,4.8 V9.2 M9,14.8 V19.2", null),
        ["share"] = ("M12,14.5 V3.5 M8,7.5 L12,3.5 L16,7.5 M8,10.5 H6.5 A1.5,1.5 0 0 0 5,12 V19 A1.5,1.5 0 0 0 6.5,20.5 H17.5 A1.5,1.5 0 0 0 19,19 V12 A1.5,1.5 0 0 0 17.5,10.5 H16", null),
        ["drag"] = ("M8,4.5 H5.5 A1.5,1.5 0 0 0 4,6 V18.5 A1.5,1.5 0 0 0 5.5,20 H18 A1.5,1.5 0 0 0 19.5,18.5 V16 M13,4 H20 V11 M20,4 L11,13", null),
        ["text-scan"] = ("M4,8.5 V5.5 A1.5,1.5 0 0 1 5.5,4 H8.5 M15.5,4 H18.5 A1.5,1.5 0 0 1 20,5.5 V8.5 M20,15.5 V18.5 A1.5,1.5 0 0 1 18.5,20 H15.5 M8.5,20 H5.5 A1.5,1.5 0 0 1 4,18.5 V15.5 M8,10 H16 M8,14 H13", null),
        ["fit"] = ("M4,9 V4 H9 M15,4 H20 V9 M20,15 V20 H15 M9,20 H4 V15", null),
        ["open"] = ("M3.5,7 A1.5,1.5 0 0 1 5,5.5 H9.5 L11.5,7.5 H19 A1.5,1.5 0 0 1 20.5,9 V17.5 A1.5,1.5 0 0 1 19,19 H5 A1.5,1.5 0 0 1 3.5,17.5 Z M12,10.5 V16 M9.5,13 L12,10.5 L14.5,13", null),
        ["clipboard"] = ("M9,4.5 H7 A1.5,1.5 0 0 0 5.5,6 V19 A1.5,1.5 0 0 0 7,20.5 H17 A1.5,1.5 0 0 0 18.5,19 V6 A1.5,1.5 0 0 0 17,4.5 H15 M9,3.5 H15 V6.5 H9 Z", null),
    };

    public static FrameworkElement Make(string name, double size = 20)
    {
        var (stroke, fill) = Paths.TryGetValue(name, out var found) ? found : Paths["more"];
        var canvas = new Canvas { Width = 24, Height = 24 };
        var foreground = new Binding { Path = new PropertyPath(TextElement.ForegroundProperty), RelativeSource = RelativeSource.Self };
        if (fill is not null)
        {
            var filled = new Path { Data = Geometry.Parse(fill) };
            filled.SetBinding(Shape.FillProperty, foreground);
            canvas.Children.Add(filled);
        }
        if (stroke.Length > 0)
        {
            var outline = new Path
            {
                Data = Geometry.Parse(stroke), StrokeThickness = 1.7,
                StrokeStartLineCap = PenLineCap.Round, StrokeEndLineCap = PenLineCap.Round, StrokeLineJoin = PenLineJoin.Round
            };
            outline.SetBinding(Shape.StrokeProperty, foreground);
            canvas.Children.Add(outline);
        }
        return new Viewbox { Width = size, Height = size, Child = canvas, SnapsToDevicePixels = true, IsHitTestVisible = false };
    }
}
