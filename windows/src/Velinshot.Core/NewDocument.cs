using System.Windows;
using System.Windows.Media.Imaging;

namespace Velinshot.Core;

/// <summary>Content bounds that were computed, including "no border found" (null).</summary>
public sealed record KnownContentBounds(Rect? Bounds);

/// <summary>Cached analysis for one source, so toggles do not rescan the image.</summary>
public sealed record DocumentAnalysis
{
    public KnownContentBounds? Bounds { get; init; }
    public (Rgba First, Rgba Second)? Colors { get; init; }
    public Rgba? InsetColor { get; init; }
    public Rect? InsetCrop { get; init; }
}

public static class NewDocument
{
    public static (EditState State, DocumentAnalysis Analysis) Prepare(BitmapSource source, CanvasStyle style)
    {
        var state = new EditState(style);
        var analysis = new DocumentAnalysis();
        if (style.AutoBalance)
        {
            var bounds = AutoBeautify.ContentBounds(source);
            state.Crop = bounds;
            analysis = analysis with { Bounds = new KnownContentBounds(bounds) };
        }
        if (style.AutoColor)
        {
            var colors = AutoBeautify.SuggestColors(source);
            state.Style = state.Style with { Color1 = colors.first, Color2 = colors.second, Background = BackgroundKind.Gradient };
            analysis = analysis with { Colors = colors };
        }
        if (style.AutoInsetColor)
        {
            var color = AutoBeautify.SuggestInsetColor(source, state.Crop);
            state.Style = state.Style with { InsetColor = color };
            analysis = analysis with { InsetColor = color, InsetCrop = state.Crop };
        }
        return (state, analysis);
    }
}
