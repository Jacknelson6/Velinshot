using System.Globalization;
using System.Windows;
using System.Windows.Media;
using System.Windows.Media.Imaging;

namespace Velinshot.Core;

/// <summary>The one renderer for preview and export. Geometry is in original source pixels;
/// the raster scale only decides how many device pixels represent them.</summary>
public static class CanvasRenderer
{
    public static RenderLayout Layout(Size sourceSize, EditState state)
    {
        if (!double.IsFinite(sourceSize.Width) || !double.IsFinite(sourceSize.Height) ||
            sourceSize.Width < 1 || sourceSize.Height < 1 ||
            sourceSize.Width > ImageLimits.MaximumDimension || sourceSize.Height > ImageLimits.MaximumDimension)
            throw VelinshotException.TooLarge();
        ImageLimits.Validate((int)Math.Ceiling(sourceSize.Width), (int)Math.Ceiling(sourceSize.Height));
        var style = state.Style;
        Validate(style);
        var sourceRect = new Rect(sourceSize);
        Rect crop;
        if (state.Crop is { } requested)
        {
            if (!RectMath.IsFinite(requested) || requested.Width <= 0 || requested.Height <= 0) throw VelinshotException.InvalidCrop();
            var clipped = Rect.Intersect(requested, sourceRect);
            if (clipped.IsEmpty) throw VelinshotException.InvalidCrop();
            clipped = Rect.Intersect(RectMath.Integral(clipped), sourceRect);
            if (clipped.IsEmpty || clipped.Width < 1 || clipped.Height < 1) throw VelinshotException.InvalidCrop();
            crop = clipped;
        }
        else crop = sourceRect;

        var padding = style.Padding;
        var inset = style.Inset;
        var panelSize = new Size(crop.Width + inset * 2, crop.Height + inset * 2);
        var width = Math.Ceiling(panelSize.Width + padding * 2);
        var height = Math.Ceiling(panelSize.Height + padding * 2);
        double? ratio = style is { FixedWidth: { } fw, FixedHeight: { } fh } ? (double)fw / fh
            : style.RatioWidth > 0 ? style.RatioWidth / style.RatioHeight : null;
        if (ratio is { } r)
        {
            if (width / height < r) width = height * r; else height = width / r;
        }
        // Fractional composition dimensions preserve an exact ratio. Their units remain
        // original source pixels, independent of the final raster size.
        var canvas = new Size(width, height);
        Size export = style is { FixedWidth: { } exactWidth, FixedHeight: { } exactHeight }
            ? new Size(exactWidth, exactHeight)
            : new Size(Math.Ceiling(canvas.Width * style.OutputScale), Math.Ceiling(canvas.Height * style.OutputScale));
        if (!double.IsFinite(export.Width) || !double.IsFinite(export.Height) ||
            export.Width > ImageLimits.MaximumDimension || export.Height > ImageLimits.MaximumDimension)
            throw VelinshotException.TooLarge();
        ImageLimits.Validate((int)export.Width, (int)export.Height);
        var panel = new Rect((canvas.Width - panelSize.Width) / 2, (canvas.Height - panelSize.Height) / 2, panelSize.Width, panelSize.Height);
        return new RenderLayout(canvas, new Rect(panel.X + inset, panel.Y + inset, crop.Width, crop.Height), crop, export, panel);
    }

    public static BitmapSource Render(BitmapSource source, EditState state, BitmapSource? backgroundImage = null,
                                      int? previewMaxDimension = null, RenderCache? cache = null) =>
        RenderRaster(source, new Size(source.PixelWidth, source.PixelHeight), false, state, backgroundImage, null, previewMaxDimension, cache);

    public static BitmapSource RenderPreview(ImagePreview source, EditState state, BitmapSource? backgroundImage = null,
                                             ImagePreview? backgroundPreview = null, int maximumDimension = 1400, RenderCache? cache = null) =>
        RenderRaster(source.Bitmap, source.SourceSize, true, state, backgroundPreview?.Bitmap ?? backgroundImage,
                     backgroundPreview?.SourceSize, maximumDimension, cache);

    private static BitmapSource RenderRaster(BitmapSource source, Size sourceSize, bool isProxy, EditState state,
                                             BitmapSource? backgroundImage, Size? backgroundSourceSize, int? previewMaxDimension,
                                             RenderCache? cache)
    {
        var layout = Layout(sourceSize, state);
        var style = state.Style;
        var fullScale = style.FixedWidth is { } fixedWidth ? fixedWidth / layout.CanvasSize.Width : style.OutputScale;
        var scale = fullScale;
        var pixelWidth = (int)layout.ExportSize.Width;
        var pixelHeight = (int)layout.ExportSize.Height;
        if (previewMaxDimension is { } maximum)
        {
            if (maximum <= 0) throw VelinshotException.InvalidStyle("Preview size must be positive.");
            if (maximum < Math.Max(layout.ExportSize.Width, layout.ExportSize.Height))
            {
                scale = Math.Min(scale, maximum / Math.Max(layout.CanvasSize.Width, layout.CanvasSize.Height));
                pixelWidth = Math.Max(1, Math.Min(maximum, (int)Math.Ceiling(layout.CanvasSize.Width * scale - 1e-8)));
                pixelHeight = Math.Max(1, Math.Min(maximum, (int)Math.Ceiling(layout.CanvasSize.Height * scale - 1e-8)));
            }
        }
        ImageLimits.Validate(pixelWidth, pixelHeight);
        ValidateAnnotations(state.Annotations);
        var watermark = WatermarkLayout(style, layout.ExportSize);

        var radius = Math.Min(style.CornerRadius, Math.Min(layout.PanelRect.Width, layout.PanelRect.Height) / 2);
        var innerRadius = Math.Max(0, radius - style.Inset);
        var composition = Frozen(new ScaleTransform(scale, scale));

        // The framed base (background, shadow, panel, screenshot) is reused while only markup changes.
        var key = new BaseKey(style with
        {
            WatermarkText = "", WatermarkFontSize = 20, WatermarkColor = default, WatermarkPosition = WatermarkPosition.BottomRight,
            AutoBalance = false, AutoColor = false, AutoInsetColor = false
        }, layout.CropRect, pixelWidth, pixelHeight, scale, source, backgroundImage, sourceSize, backgroundSourceSize);
        PixelBuffer canvas;
        if (cache?.Key is BaseKey cachedKey && cachedKey == key && cache.Base is { } stored) canvas = stored.Clone();
        else
        {
            canvas = RenderBase(source, sourceSize, layout, style, radius, innerRadius, scale, composition,
                                pixelWidth, pixelHeight, backgroundImage, backgroundSourceSize);
            if (cache is not null) { cache.Key = key; cache.Base = canvas.Clone(); }
        }

        var markup = new MarkupContext(source, sourceSize, isProxy, scale, Rounded(layout.CropRect, innerRadius),
                                       layout.SourceOriginInCanvas, new Rect(layout.CanvasSize), composition);
        var run = new List<Annotation>();
        void Layer(IReadOnlyList<Annotation> annotations, bool multiply)
        {
            var union = Rect.Empty;
            foreach (var annotation in annotations) union.Union(MarkupBounds(annotation));
            var region = DeviceRegion(union, markup, pixelWidth, pixelHeight);
            if (region.Width <= 0 || region.Height <= 0) return;
            var layer = Pixels.Render(region.Width, region.Height, context =>
            {
                context.PushTransform(new TranslateTransform(-region.X, -region.Y));
                markup.Begin(context);
                foreach (var annotation in annotations) DrawAnnotation(context, annotation, markup);
                markup.End(context);
                context.Pop();
            });
            // A highlighter multiplies its stroke into what is already there at 30% opacity.
            if (multiply) Pixels.CompositeMultiply(canvas, layer, region.X, region.Y, 0.3);
            else Pixels.CompositeOver(canvas, layer, region.X, region.Y);
        }
        foreach (var annotation in state.Annotations)
        {
            if (annotation.Points.Count == 0) continue;
            if (annotation.Kind != AnnotationKind.Highlighter) { run.Add(annotation); continue; }
            if (run.Count > 0) { Layer(run, false); run.Clear(); }
            Layer(new[] { annotation }, true);
        }
        if (run.Count > 0) Layer(run, false);

        if (watermark is { } mark)
        {
            // Watermark size and 12px margins use final export pixels. A preview applies the
            // same geometry at its reduced raster scale.
            var factor = scale / fullScale;
            var text = TextMetrics.Format(mark.Text, mark.FontSize, FontWeights.SemiBold, Brush(style.WatermarkColor));
            var bounds = new Rect(mark.Origin.X * factor, mark.Origin.Y * factor,
                                  text.WidthIncludingTrailingWhitespace * factor, text.Height * factor);
            var region = Clamp(bounds, pixelWidth, pixelHeight);
            if (region.Width > 0 && region.Height > 0)
            {
                var layer = Pixels.Render(region.Width, region.Height, context =>
                {
                    context.PushTransform(new TranslateTransform(-region.X, -region.Y));
                    context.PushTransform(new ScaleTransform(factor, factor));
                    context.DrawText(text, mark.Origin);
                    context.Pop(); context.Pop();
                });
                Pixels.CompositeOver(canvas, layer, region.X, region.Y);
            }
        }
        return canvas.ToBitmap();
    }

    private sealed record BaseKey(CanvasStyle Style, Rect Crop, int Width, int Height, double Scale, BitmapSource Source,
                                  BitmapSource? Background, Size SourceSize, Size? BackgroundSourceSize);

    private static PixelBuffer RenderBase(BitmapSource source, Size sourceSize, RenderLayout layout, CanvasStyle style,
                                          double radius, double innerRadius, double scale, Transform composition,
                                          int pixelWidth, int pixelHeight, BitmapSource? backgroundImage, Size? backgroundSourceSize)
    {
        var canvasRect = new Rect(layout.CanvasSize);
        var bitmapRect = new Rect(0, 0, pixelWidth / scale, pixelHeight / scale);
        var panelGeometry = Rounded(layout.PanelRect, radius);
        var imageGeometry = Rounded(layout.ImageRect, innerRadius);

        void DrawPanel(DrawingContext context)
        {
            context.PushTransform(composition);
            if (style.Inset > 0)
            {
                // Fill only the inset ring, never transparent source pixels.
                context.DrawGeometry(Brush(style.InsetColor), null,
                    new CombinedGeometry(GeometryCombineMode.Exclude, panelGeometry, imageGeometry));
            }
            context.PushClip(imageGeometry);
            // Map the whole (proxy or original) source into original coordinates and clip,
            // which avoids integer crop quantization of a reduced proxy.
            context.DrawImage(source, new Rect(layout.ImageRect.X - layout.CropRect.X, layout.ImageRect.Y - layout.CropRect.Y,
                                               sourceSize.Width, sourceSize.Height));
            context.Pop();
            if (style.BorderWidth > 0)
                context.DrawGeometry(null, Frozen(new Pen(Brush(Color.FromArgb(166, 255, 255, 255)), style.BorderWidth)), panelGeometry);
            context.Pop();
        }

        var buffer = Pixels.Render(pixelWidth, pixelHeight, context =>
        {
            if (style.Background == BackgroundKind.Solid || (style.Background == BackgroundKind.Image && backgroundImage is null))
            {
                // Cover the complete integer bitmap before the fractional composition transform,
                // preserving the selected color's alpha.
                context.DrawRectangle(Brush(style.Color1), null, new Rect(0, 0, pixelWidth, pixelHeight));
            }
            context.PushTransform(composition);
            DrawBackground(context, style, backgroundImage, backgroundSourceSize, canvasRect, bitmapRect);
            context.Pop();
            if (style.Shadow <= 0) DrawPanel(context);
        });
        if (style.Shadow > 0)
        {
            DrawShadow(buffer, layout, radius, scale, style.Shadow);
            Pixels.CompositeOver(buffer, Pixels.Render(pixelWidth, pixelHeight, DrawPanel), 0, 0);
        }
        return buffer;
    }

    /// <summary>A soft black (25%) shadow of the panel, offset downward by 28% of its blur.
    /// The panel mask is an analytic rounded-rectangle coverage, blurred at reduced resolution
    /// for large radii. It shows only outside the panel and inside the canvas, so transparent
    /// screenshot pixels are never darkened.</summary>
    private static void DrawShadow(PixelBuffer buffer, RenderLayout layout, double radius, double scale, double shadow)
    {
        var shadowPixels = shadow * scale;
        var sigma = shadowPixels / 2;
        var offset = shadowPixels * 0.28;
        var panel = layout.PanelRect;
        double centerX = (panel.X + panel.Width / 2) * scale, centerY = (panel.Y + panel.Height / 2) * scale;
        double halfWidth = panel.Width / 2 * scale, halfHeight = panel.Height / 2 * scale, corner = radius * scale;
        var step = Math.Max(1, (int)Math.Floor(sigma / 3));
        int lowWidth = (buffer.Width + step - 1) / step, lowHeight = (buffer.Height + step - 1) / step;
        var low = new float[lowWidth * lowHeight];
        for (var j = 0; j < lowHeight; j++)
        for (var i = 0; i < lowWidth; i++)
        {
            var distance = RoundedDistance((i + 0.5) * step - centerX, (j + 0.5) * step - offset - centerY, halfWidth, halfHeight, corner) / step;
            low[j * lowWidth + i] = (float)Math.Clamp(0.5 - distance, 0, 1);
        }
        Pixels.GaussianBlur(low, lowWidth, lowHeight, sigma / step, clampEdges: false);
        double canvasWidth = layout.CanvasSize.Width * scale, canvasHeight = layout.CanvasSize.Height * scale;
        var data = buffer.Data;
        for (var y = 0; y < buffer.Height; y++)
        {
            var canvasY = Math.Clamp(canvasHeight - y, 0, 1);
            var sampleY = Math.Clamp((y + 0.5) / step - 0.5, 0, lowHeight - 1);
            var y0 = (int)sampleY; var y1 = Math.Min(lowHeight - 1, y0 + 1); var fy = (float)(sampleY - y0);
            for (var x = 0; x < buffer.Width; x++)
            {
                var outside = Math.Clamp(0.5 + RoundedDistance(x + 0.5 - centerX, y + 0.5 - centerY, halfWidth, halfHeight, corner), 0, 1);
                if (outside <= 0) continue;
                var sampleX = Math.Clamp((x + 0.5) / step - 0.5, 0, lowWidth - 1);
                var x0 = (int)sampleX; var x1 = Math.Min(lowWidth - 1, x0 + 1); var fx = (float)(sampleX - x0);
                var top = low[y0 * lowWidth + x0] * (1 - fx) + low[y0 * lowWidth + x1] * fx;
                var bottom = low[y1 * lowWidth + x0] * (1 - fx) + low[y1 * lowWidth + x1] * fx;
                var alpha = (top * (1 - fy) + bottom * fy) * 0.25 * outside * Math.Clamp(canvasWidth - x, 0, 1) * canvasY;
                if (alpha <= 0) continue;
                var index = (y * buffer.Width + x) * 4;
                var keep = 1 - alpha;
                data[index] = (byte)Math.Round(data[index] * keep);
                data[index + 1] = (byte)Math.Round(data[index + 1] * keep);
                data[index + 2] = (byte)Math.Round(data[index + 2] * keep);
                data[index + 3] = (byte)Math.Round(255 * alpha + data[index + 3] * keep);
            }
        }
    }

    /// <summary>Signed distance from a point (relative to the center) to a rounded rectangle.</summary>
    private static double RoundedDistance(double x, double y, double halfWidth, double halfHeight, double radius)
    {
        radius = Math.Min(radius, Math.Min(halfWidth, halfHeight));
        var qx = Math.Abs(x) - halfWidth + radius;
        var qy = Math.Abs(y) - halfHeight + radius;
        var ox = Math.Max(qx, 0); var oy = Math.Max(qy, 0);
        return Math.Sqrt(ox * ox + oy * oy) + Math.Min(Math.Max(qx, qy), 0) - radius;
    }

    /// <summary>Conservative source-space bounds of everything an annotation can paint.</summary>
    private static Rect MarkupBounds(Annotation annotation)
    {
        var points = annotation.Points;
        double minX = points.Min(p => p.X), minY = points.Min(p => p.Y), maxX = points.Max(p => p.X), maxY = points.Max(p => p.Y);
        var box = new Rect(minX, minY, maxX - minX, maxY - minY);
        var width = Math.Min(512, Math.Max(0.5, annotation.LineWidth));
        double grow;
        switch (annotation.Kind)
        {
            case AnnotationKind.Text:
            {
                var size = TextMetrics.Measure(annotation.Text.Length > 20_000 ? annotation.Text[..20_000] : annotation.Text,
                                               Math.Min(512, Math.Max(6, annotation.FontSize)), FontWeights.SemiBold);
                return new Rect(points[0].X - 4, points[0].Y - 4, size.Width + 8 + size.Height, size.Height + 8);
            }
            case AnnotationKind.Number:
            {
                var diameter = Math.Max(24, Math.Min(512, annotation.FontSize * 1.55)) + 4 + annotation.Text.Length * 8;
                return new Rect(points[0].X - diameter, points[0].Y - diameter, diameter * 2, diameter * 2);
            }
            case AnnotationKind.Arrow: grow = Math.Max(15, width * 4) + width; break;
            case AnnotationKind.Highlighter: grow = Math.Max(12, width * 4) / 2 + width; break;
            case AnnotationKind.Blur:
            case AnnotationKind.Redact: grow = 1; break;
            default: grow = width; break;
        }
        box.Inflate(grow + 2, grow + 2);
        return box;
    }

    private static Int32Rect DeviceRegion(Rect sourceBounds, MarkupContext markup, int pixelWidth, int pixelHeight)
    {
        if (sourceBounds.IsEmpty) return default;
        var composition = new Rect(sourceBounds.X + markup.Origin.X, sourceBounds.Y + markup.Origin.Y, sourceBounds.Width, sourceBounds.Height);
        composition.Intersect(markup.CanvasRect);
        if (composition.IsEmpty) return default;
        return Clamp(new Rect(composition.X * markup.Scale, composition.Y * markup.Scale,
                              composition.Width * markup.Scale, composition.Height * markup.Scale), pixelWidth, pixelHeight);
    }

    private static Int32Rect Clamp(Rect device, int pixelWidth, int pixelHeight)
    {
        var left = Math.Max(0, (int)Math.Floor(device.X) - 1);
        var top = Math.Max(0, (int)Math.Floor(device.Y) - 1);
        var right = Math.Min(pixelWidth, (int)Math.Ceiling(device.Right) + 1);
        var bottom = Math.Min(pixelHeight, (int)Math.Ceiling(device.Bottom) + 1);
        return right <= left || bottom <= top ? default : new Int32Rect(left, top, right - left, bottom - top);
    }

    private static void Validate(CanvasStyle style)
    {
        (double value, double min, double max, string name)[] bounded =
        {
            (style.Padding, 0, 2048, "Padding"), (style.Inset, 0, 2048, "Inset"), (style.CornerRadius, 0, 8192, "Rounding"),
            (style.Shadow, 0, 512, "Shadow"), (style.BorderWidth, 0, 128, "Border"), (style.WatermarkFontSize, 1, 512, "Watermark size")
        };
        foreach (var (value, min, max, name) in bounded)
            if (!double.IsFinite(value) || value < min || value > max)
                throw VelinshotException.InvalidStyle($"{name} is outside the supported range.");
        if (!double.IsFinite(style.GradientAngle)) throw VelinshotException.InvalidStyle("Gradient angle must be finite.");
        if (style.FixedWidth.HasValue != style.FixedHeight.HasValue)
            throw VelinshotException.InvalidStyle("Exact output size needs both width and height.");
        if (style is { FixedWidth: { } width, FixedHeight: { } height })
        {
            ImageLimits.Validate(width, height);
            return;
        }
        if (!double.IsFinite(style.OutputScale) || style.OutputScale < 0.1 || style.OutputScale > 4)
            throw VelinshotException.InvalidStyle("Export scale is outside the supported range.");
        var natural = style.RatioWidth == 0 && style.RatioHeight == 0;
        var custom = double.IsFinite(style.RatioWidth) && double.IsFinite(style.RatioHeight) &&
                     style.RatioWidth > 0 && style.RatioHeight > 0 && style.RatioWidth <= 1000 && style.RatioHeight <= 1000;
        if (!natural && !custom) throw VelinshotException.InvalidStyle("Choose a valid aspect ratio.");
    }

    private static void ValidateAnnotations(List<Annotation> annotations)
    {
        if (annotations.Count > 10_000 || annotations.Sum(a => (long)a.Points.Count) > 1_000_000)
            throw VelinshotException.InvalidStyle("There are too many annotations.");
        foreach (var annotation in annotations)
        {
            if (annotation.Points.Count > 250_000 || !double.IsFinite(annotation.LineWidth) || !double.IsFinite(annotation.FontSize) ||
                annotation.Points.Any(p => !double.IsFinite(p.X) || !double.IsFinite(p.Y) || Math.Abs(p.X) >= 10_000_000 || Math.Abs(p.Y) >= 10_000_000))
                throw VelinshotException.InvalidStyle("An annotation contains invalid coordinates.");
        }
    }

    private sealed record WatermarkPlacement(string Text, double FontSize, Point Origin);

    private static WatermarkPlacement? WatermarkLayout(CanvasStyle style, Size exportSize)
    {
        var text = string.Join(" ", style.WatermarkText.Split(new[] { "\r\n", "\n", "\r" }, StringSplitOptions.RemoveEmptyEntries)).Trim();
        if (text.Length == 0) return null;
        const double margin = 12;
        var available = new Size(Math.Max(0, exportSize.Width - margin * 2), Math.Max(0, exportSize.Height - margin * 2));
        if (available.Width <= 0 || available.Height <= 0)
            throw VelinshotException.InvalidStyle("A watermark needs an output larger than 24 by 24 pixels.");
        var elements = TextElements(text).Take(2000).ToArray();
        var visible = string.Concat(elements);
        var fontSize = style.WatermarkFontSize;
        Size Measure(string value, double size) => TextMetrics.Measure(value, size, FontWeights.SemiBold);
        var size = Measure(visible, fontSize);
        fontSize *= Math.Min(1, available.Height / Math.Max(1, size.Height));
        size = Measure(visible, fontSize);
        if (size.Width > available.Width)
        {
            // Keep long watermarks legible: shrink to eight pixels, then truncate with an
            // ellipsis rather than draw microscopic text.
            fontSize = Math.Max(Math.Min(8, fontSize), fontSize * available.Width / Math.Max(1, size.Width));
            const string ellipsis = "…";
            int low = 0, high = elements.Length;
            while (low < high)
            {
                var middle = (low + high + 1) / 2;
                if (Measure(string.Concat(elements.Take(middle)) + ellipsis, fontSize).Width <= available.Width) low = middle; else high = middle - 1;
            }
            visible = string.Concat(elements.Take(low)) + ellipsis;
            var ellipsisWidth = Measure(visible, fontSize).Width;
            if (ellipsisWidth > available.Width) fontSize *= available.Width / ellipsisWidth;
        }
        size = Measure(visible, fontSize);
        if (size.Height > available.Height)
        {
            fontSize *= available.Height / size.Height;
            size = Measure(visible, fontSize);
        }
        var left = style.WatermarkPosition is WatermarkPosition.TopLeft or WatermarkPosition.BottomLeft;
        var top = style.WatermarkPosition is WatermarkPosition.TopLeft or WatermarkPosition.TopRight;
        return new WatermarkPlacement(visible, fontSize,
            new Point(left ? margin : exportSize.Width - margin - size.Width, top ? margin : exportSize.Height - margin - size.Height));
    }

    private static IEnumerable<string> TextElements(string text)
    {
        var enumerator = StringInfo.GetTextElementEnumerator(text);
        while (enumerator.MoveNext()) yield return enumerator.GetTextElement();
    }

    private static void DrawBackground(DrawingContext context, CanvasStyle style, BitmapSource? image, Size? imageSourceSize,
                                       Rect rect, Rect bitmapRect)
    {
        switch (style.Background)
        {
            case BackgroundKind.Transparent:
            case BackgroundKind.Solid: // Filled once in device space before the composition transform.
                break;
            case BackgroundKind.Gradient:
            {
                var angle = style.GradientAngle * Math.PI / 180;
                var dx = Math.Cos(angle); var dy = Math.Sin(angle);
                var distance = Math.Abs(dx) * rect.Width / 2 + Math.Abs(dy) * rect.Height / 2;
                var center = new Point(rect.X + rect.Width / 2, rect.Y + rect.Height / 2);
                var brush = new LinearGradientBrush(new GradientStopCollection
                {
                    new GradientStop(style.Color1.ToColor(), 0), new GradientStop(style.Color2.ToColor(), 1)
                }, new Point(center.X - dx * distance, center.Y - dy * distance), new Point(center.X + dx * distance, center.Y + dy * distance))
                {
                    MappingMode = BrushMappingMode.Absolute,
                    SpreadMethod = GradientSpreadMethod.Pad,
                    ColorInterpolationMode = ColorInterpolationMode.SRgbLinearInterpolation
                };
                brush.Freeze();
                context.DrawRectangle(brush, null, Rect.Union(rect, bitmapRect));
                break;
            }
            case BackgroundKind.Image:
            {
                if (image is null) return; // Its fallback color was filled in device space.
                var sourceSize = imageSourceSize ?? new Size(image.PixelWidth, image.PixelHeight);
                var cover = Math.Max(bitmapRect.Width / sourceSize.Width, bitmapRect.Height / sourceSize.Height);
                var size = new Size(sourceSize.Width * cover, sourceSize.Height * cover);
                context.DrawImage(image, new Rect(bitmapRect.X + bitmapRect.Width / 2 - size.Width / 2,
                                                  bitmapRect.Y + bitmapRect.Height / 2 - size.Height / 2, size.Width, size.Height));
                break;
            }
        }
    }

    private sealed record MarkupContext(BitmapSource Source, Size SourceSize, bool IsProxy, double Scale, Geometry BlurClip,
                                        Point Origin, Rect CanvasRect, Transform Composition)
    {
        public void Begin(DrawingContext context)
        {
            context.PushTransform(Composition);
            context.PushClip(new RectangleGeometry(CanvasRect));
            context.PushTransform(new TranslateTransform(Origin.X, Origin.Y));
        }

        public void End(DrawingContext context) { context.Pop(); context.Pop(); context.Pop(); }
    }

    private static void DrawAnnotation(DrawingContext context, Annotation annotation, MarkupContext markup)
    {
        var points = annotation.Points;
        var first = points[0];
        var last = points[^1];
        var width = Math.Min(512, Math.Max(0.5, annotation.LineWidth));
        var rect = RectMath.FromPoints(first, last);
        var brush = Brush(annotation.Color);
        switch (annotation.Kind)
        {
            case AnnotationKind.Pen:
            case AnnotationKind.Highlighter:
            {
                var strokeWidth = annotation.Kind == AnnotationKind.Highlighter ? Math.Max(12, width * 4) : width;
                if (points.Count == 1)
                {
                    context.DrawEllipse(brush, null, first, width / 2, width / 2);
                    break;
                }
                var geometry = new StreamGeometry();
                using (var path = geometry.Open())
                {
                    path.BeginFigure(first, false, false);
                    path.PolyLineTo(points.Skip(1).ToList(), true, true);
                }
                geometry.Freeze();
                context.DrawGeometry(null, StrokePen(brush, strokeWidth), geometry);
                break;
            }
            case AnnotationKind.Line:
            case AnnotationKind.Arrow:
            {
                var pen = StrokePen(brush, width);
                context.DrawLine(pen, first, last);
                if (annotation.Kind == AnnotationKind.Arrow)
                {
                    var angle = Math.Atan2(last.Y - first.Y, last.X - first.X);
                    var length = Math.Max(15, width * 4);
                    var head = new StreamGeometry();
                    using (var path = head.Open())
                    {
                        path.BeginFigure(new Point(last.X - Math.Cos(angle - Math.PI / 6) * length, last.Y - Math.Sin(angle - Math.PI / 6) * length), false, false);
                        path.LineTo(last, true, true);
                        path.LineTo(new Point(last.X - Math.Cos(angle + Math.PI / 6) * length, last.Y - Math.Sin(angle + Math.PI / 6) * length), true, true);
                    }
                    head.Freeze();
                    context.DrawGeometry(null, pen, head);
                }
                break;
            }
            case AnnotationKind.Rectangle:
                context.DrawRectangle(null, StrokePen(brush, width), rect);
                break;
            case AnnotationKind.Ellipse:
                context.DrawEllipse(null, StrokePen(brush, width), new Point(rect.X + rect.Width / 2, rect.Y + rect.Height / 2), rect.Width / 2, rect.Height / 2);
                break;
            case AnnotationKind.Text:
                if (annotation.Text.Length == 0) break;
                context.DrawText(TextMetrics.Format(Truncate(annotation.Text, 20_000), Math.Min(512, Math.Max(6, annotation.FontSize)),
                                                    FontWeights.SemiBold, brush), first);
                break;
            case AnnotationKind.Number:
            {
                var diameter = Math.Max(24, Math.Min(512, annotation.FontSize * 1.55));
                context.DrawEllipse(brush, null, first, diameter / 2, diameter / 2);
                var label = TextMetrics.Format(annotation.Text.Length == 0 ? "1" : Truncate(annotation.Text, 32), diameter * 0.52, FontWeights.Bold, Brushes.White);
                context.DrawText(label, new Point(first.X - label.WidthIncludingTrailingWhitespace / 2, first.Y - label.Height / 2));
                break;
            }
            case AnnotationKind.Redact:
                context.DrawRectangle(Brush(annotation.Color.WithAlpha(1)), null, RectMath.Integral(rect));
                break;
            case AnnotationKind.Blur:
                context.PushClip(markup.BlurClip);
                DrawBlur(context, markup, RectMath.Integral(rect), Math.Max(8, width * 2));
                context.Pop();
                break;
        }
    }

    private static void DrawBlur(DrawingContext context, MarkupContext markup, Rect rect, double strength)
    {
        var bounded = Rect.Intersect(rect, new Rect(markup.SourceSize));
        if (bounded.IsEmpty || bounded.Width <= 0 || bounded.Height <= 0 || (!markup.IsProxy && (bounded.Width < 1 || bounded.Height < 1))) return;
        // Work near the raster's resolution rather than allocating a full-resolution
        // intermediate whenever a preview redraws a blur region.
        var targetScale = Math.Min(1, Math.Max(markup.IsProxy ? 0.000001 : 0.05, markup.Scale));
        var width = Math.Max(1, (int)Math.Round(bounded.Width * targetScale));
        var height = Math.Max(1, (int)Math.Round(bounded.Height * targetScale));
        var image = markup.Source;
        var sx = image.PixelWidth / markup.SourceSize.Width;
        var sy = image.PixelHeight / markup.SourceSize.Height;
        var region = Pixels.Resample(image, new Rect(bounded.X * sx, bounded.Y * sy, bounded.Width * sx, bounded.Height * sy), width, height);
        var buffer = PixelBuffer.From(region);
        Pixels.GaussianBlur(buffer, strength * targetScale, clampEdges: true);
        Pixels.FlattenOnWhite(buffer);
        context.DrawImage(buffer.ToBitmap(), bounded);
    }

    private static string Truncate(string text, int maximum) => text.Length <= maximum ? text : string.Concat(TextElements(text).Take(maximum));

    private static Pen StrokePen(Brush brush, double width) => Frozen(new Pen(brush, width)
    {
        StartLineCap = PenLineCap.Round, EndLineCap = PenLineCap.Round, DashCap = PenLineCap.Round, LineJoin = PenLineJoin.Round
    });

    private static RectangleGeometry Rounded(Rect rect, double radius) => Frozen(new RectangleGeometry(rect, radius, radius));
    private static SolidColorBrush Brush(Rgba color) => Brush(color.ToColor());
    private static SolidColorBrush Brush(Color color) => Frozen(new SolidColorBrush(color));
    private static T Frozen<T>(T value) where T : Freezable { value.Freeze(); return value; }

}

/// <summary>Text uses Segoe UI, present on every supported Windows release, so a
/// composition renders the same on Windows 10 and 11.</summary>
public static class TextMetrics
{
    public static readonly FontFamily Family = new("Segoe UI");

    public static FormattedText Format(string text, double size, FontWeight weight, Brush brush) =>
        new(text, CultureInfo.CurrentUICulture, FlowDirection.LeftToRight,
            new Typeface(Family, FontStyles.Normal, weight, FontStretches.Normal), size, brush, 1.0);

    public static Size Measure(string text, double size, FontWeight weight)
    {
        var formatted = Format(text, size, weight, Brushes.Black);
        return new Size(formatted.WidthIncludingTrailingWhitespace, formatted.Height);
    }
}
