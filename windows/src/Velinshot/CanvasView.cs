using System.IO;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Threading;
using Velinshot.Core;

namespace Velinshot;

internal enum EditorTool { Select, Pen, Arrow, Rectangle, Ellipse, Text, Highlighter, Blur, Redact, Number, Crop, Line }

internal static class EditorTools
{
    public static string Icon(this EditorTool tool) => tool switch
    {
        EditorTool.Select => "select", EditorTool.Pen => "pen", EditorTool.Arrow => "arrow", EditorTool.Rectangle => "rectangle",
        EditorTool.Ellipse => "ellipse", EditorTool.Text => "text", EditorTool.Highlighter => "highlighter", EditorTool.Blur => "blur",
        EditorTool.Redact => "redact", EditorTool.Number => "number", EditorTool.Crop => "crop", _ => "line"
    };

    public static string Title(this EditorTool tool) => tool switch
    {
        EditorTool.Select => "Select and move (V)", EditorTool.Pen => "Draw (D)", EditorTool.Arrow => "Arrow (A)",
        EditorTool.Rectangle => "Rectangle (R)", EditorTool.Ellipse => "Ellipse (E)", EditorTool.Text => "Text (T)",
        EditorTool.Highlighter => "Highlight (H)", EditorTool.Blur => "Blur (B)", EditorTool.Redact => "Redact (K)",
        EditorTool.Number => "Number (N)", EditorTool.Crop => "Crop (X)", _ => "Line (L)"
    };

    public static AnnotationKind? Kind(this EditorTool tool) => tool switch
    {
        EditorTool.Select or EditorTool.Crop => null,
        EditorTool.Pen => AnnotationKind.Pen, EditorTool.Arrow => AnnotationKind.Arrow, EditorTool.Rectangle => AnnotationKind.Rectangle,
        EditorTool.Ellipse => AnnotationKind.Ellipse, EditorTool.Text => AnnotationKind.Text, EditorTool.Highlighter => AnnotationKind.Highlighter,
        EditorTool.Blur => AnnotationKind.Blur, EditorTool.Redact => AnnotationKind.Redact, EditorTool.Number => AnnotationKind.Number,
        _ => AnnotationKind.Line
    };
}

/// <summary>The editable preview. Geometry is in original source pixels; the preview raster is
/// rendered off the UI thread by the same engine as export, one frame in flight at a time.</summary>
internal sealed class CanvasView : Canvas
{
    private readonly PreviewSourceCache previewSource;
    private EditState state;
    private BitmapSource? backgroundImage;
    private EditorTool tool = EditorTool.Select;
    private BitmapSource? preview;
    private bool renderScheduled, renderInFlight, disposed;
    private int generation;
    private int? selectedIndex, draftIndex, resizeCorner, textAnnotationIndex;
    private EditState? gestureBefore;
    private Point? gestureStart;
    private Rect? cropDraft;
    private TextBox? textField;
    private Point? textOrigin;
    private double zoom = 1;
    private Vector pan;

    public BitmapSource Source { get; }
    public Rgba AnnotationColor { get; set; } = Rgba.FromHex("F05A6E");
    public double LineWidth { get; set; } = 6;
    public double TextSize { get; set; } = 36;

    public event Action<EditState, EditState>? Commit;
    public event Action? GestureEnded;
    public event Action<Exception>? RenderFailed;
    public event Action<string>? ImportFile;
    public event Action<BitmapSource>? ImportBitmap;
    public event Action? BackgroundDoubleClick;
    public event Action<Annotation?>? SelectionChanged;
    public event Action<bool>? TextEditingChanged;

    public CanvasView(BitmapSource source, EditState state, ImagePreview? preparedPreview = null)
    {
        Source = source;
        this.state = state;
        previewSource = new PreviewSourceCache(source, preparedPreview);
        Focusable = true;
        FocusVisualStyle = null;
        AllowDrop = true;
        ClipToBounds = true;
        RenderOptions.SetBitmapScalingMode(this, BitmapScalingMode.HighQuality);
        AutomationProperties.SetName(this, "Screenshot canvas");
        AutomationProperties.SetHelpText(this, "Draw anywhere in the framed canvas. C copies. S saves. In Select, Tab and Shift+Tab cycle marks. Delete removes the selected mark. Escape leaves the canvas.");
        UpdateAccessibility();
        Theme.Changed += InvalidateVisual;
        Unloaded += (_, _) => { disposed = true; Theme.Changed -= InvalidateVisual; };
        RequestRender();
    }

    public EditState State
    {
        get => state;
        set { state = value; StateChanged(); }
    }

    public BitmapSource? BackgroundImage
    {
        get => backgroundImage;
        set { backgroundImage = value; RequestRender(); }
    }

    public EditorTool Tool
    {
        get => tool;
        set
        {
            if (tool != value) FinishPointerGesture();
            tool = value;
            ClearSelection();
            Cursor = tool == EditorTool.Select ? Cursors.Arrow : Cursors.Cross;
        }
    }

    public bool HasActiveGesture => gestureBefore is not null || textField is not null;

    private void StateChanged()
    {
        UpdateAccessibility();
        RequestRender();
    }

    private void UpdateAccessibility()
    {
        var text = $"{state.Annotations.Count} annotations";
        if (selectedIndex is { } index && index < state.Annotations.Count) text += $"; selected {index + 1}, {state.Annotations[index].Kind}";
        AutomationProperties.SetItemStatus(this, text);
    }

    // MARK: Geometry

    private RenderLayout? Layout
    {
        get
        {
            try { return CanvasRenderer.Layout(new Size(Source.PixelWidth, Source.PixelHeight), state); }
            catch (Exception) { return null; }
        }
    }

    private Rect DisplayRect(RenderLayout? layout)
    {
        var available = new Rect(32, 32, Math.Max(1, ActualWidth - 64), Math.Max(1, ActualHeight - 64));
        if (layout is null) return available;
        var scale = Math.Min(available.Width / layout.CanvasSize.Width, available.Height / layout.CanvasSize.Height) * zoom;
        var size = new Size(layout.CanvasSize.Width * scale, layout.CanvasSize.Height * scale);
        return new Rect(ActualWidth / 2 - size.Width / 2 + pan.X, ActualHeight / 2 - size.Height / 2 + pan.Y, size.Width, size.Height);
    }

    private Point? SourcePoint(Point point, bool clamp = true)
    {
        if (Layout is not { } layout) return null;
        var display = DisplayRect(layout);
        if (display.Width <= 0 || display.Height <= 0) return null;
        var canvas = new Point((point.X - display.X) / display.Width * layout.CanvasSize.Width,
                               (point.Y - display.Y) / display.Height * layout.CanvasSize.Height);
        var source = layout.SourcePoint(canvas);
        var limits = tool is EditorTool.Crop or EditorTool.Blur ? layout.CropRect : layout.CanvasBoundsInSource;
        if (!clamp && !limits.Contains(source)) return null;
        return new Point(Math.Clamp(source.X, limits.Left, limits.Right), Math.Clamp(source.Y, limits.Top, limits.Bottom));
    }

    private Point ViewPoint(Point point, RenderLayout layout)
    {
        var display = DisplayRect(layout);
        var canvas = layout.CompositionPoint(point);
        return new Point(display.X + canvas.X / layout.CanvasSize.Width * display.Width,
                         display.Y + canvas.Y / layout.CanvasSize.Height * display.Height);
    }

    private Rect ViewRect(Rect rect, RenderLayout layout) => new(ViewPoint(rect.TopLeft, layout), ViewPoint(rect.BottomRight, layout));

    private static Rect AnnotationBounds(Annotation annotation)
    {
        if (annotation.Points.Count == 0) return Rect.Empty;
        var first = annotation.Points[0];
        if (annotation.Kind == AnnotationKind.Text)
            return new Rect(first, TextMetrics.Measure(annotation.Text, Math.Max(6, annotation.FontSize), FontWeights.SemiBold));
        if (annotation.Kind == AnnotationKind.Number)
            return new Rect(first.X - annotation.FontSize / 2, first.Y - annotation.FontSize / 2, annotation.FontSize, annotation.FontSize);
        double minX = annotation.Points.Min(p => p.X), minY = annotation.Points.Min(p => p.Y);
        double maxX = annotation.Points.Max(p => p.X), maxY = annotation.Points.Max(p => p.Y);
        var rect = new Rect(minX, minY, Math.Max(1, maxX - minX), Math.Max(1, maxY - minY));
        rect.Inflate(annotation.LineWidth / 2, annotation.LineWidth / 2);
        return rect;
    }

    private static Point[] Corners(Rect rect) => new[] { rect.TopLeft, rect.TopRight, rect.BottomLeft, rect.BottomRight };

    // MARK: Rendering

    private void RequestRender()
    {
        generation++;
        ScheduleRender();
    }

    private void ScheduleRender()
    {
        if (renderScheduled || renderInFlight || disposed) return;
        renderScheduled = true;
        // One pending frame and one in flight, never a queue of stale renders, so pointer
        // movement cannot starve live drawing.
        Dispatcher.BeginInvoke(DispatcherPriority.Input, StartRender);
    }

    private async void StartRender()
    {
        renderScheduled = false;
        if (disposed) return;
        renderInFlight = true;
        var number = generation;
        var snapshot = state.Clone();
        var background = backgroundImage;
        var cache = previewSource;
        try
        {
            var image = await StaWorker.Preview.Run(() => cache.Render(snapshot, background));
            if (disposed) return;
            preview = image;
            InvalidateVisual();
        }
        catch (Exception error)
        {
            if (generation == number && !disposed) RenderFailed?.Invoke(error);
        }
        finally
        {
            renderInFlight = false;
            if (generation != number && !disposed) ScheduleRender();
        }
    }

    /// <summary>Renders synchronously for documentation snapshots.</summary>
    public async Task PrepareSnapshotAsync()
    {
        var snapshot = state.Clone();
        var background = backgroundImage;
        preview = await StaWorker.Preview.Run(() => previewSource.Render(snapshot, background));
        InvalidateVisual();
    }

    protected override void OnRender(DrawingContext context)
    {
        var bounds = new Rect(0, 0, ActualWidth, ActualHeight);
        context.DrawRectangle(Theme.Brush("StudioSurface"), null, bounds);
        var well = bounds;
        well.Inflate(-10, -10);
        if (well.Width > 0 && well.Height > 0) context.DrawRoundedRectangle(Theme.Brush("StudioCanvas"), null, well, 14, 14);
        var layout = Layout;
        if (preview is not null)
        {
            context.DrawImage(preview, DisplayRect(layout));
        }
        else
        {
            var text = new FormattedText("Preparing preview…", System.Globalization.CultureInfo.CurrentUICulture, FlowDirection.LeftToRight,
                new Typeface("Segoe UI"), 12, Theme.Brush("StudioSecondaryText"), VisualTreeHelper.GetDpi(this).PixelsPerDip);
            context.DrawText(text, new Point(ActualWidth / 2 - text.Width / 2, ActualHeight / 2 - text.Height / 2));
        }
        if (layout is null) return;
        if (selectedIndex is { } index && index < state.Annotations.Count)
        {
            var rect = ViewRect(AnnotationBounds(state.Annotations[index]), layout);
            rect.Inflate(5, 5);
            DrawSelection(context, rect);
        }
        if (cropDraft is { } crop) DrawSelection(context, ViewRect(crop, layout));
    }

    private static void DrawSelection(DrawingContext context, Rect rect)
    {
        var iris = new SolidColorBrush(Theme.Iris);
        var dashed = new Pen(iris, 1.5) { DashStyle = new DashStyle(new double[] { 3.3, 2 }, 0) };
        context.DrawRectangle(null, dashed, rect);
        var handle = new Pen(iris, 1.2);
        foreach (var corner in Corners(rect)) context.DrawEllipse(Brushes.White, handle, corner, 3.5, 3.5);
    }

    protected override Size ArrangeOverride(Size arrangeSize)
    {
        var size = base.ArrangeOverride(arrangeSize);
        InvalidateVisual();
        return size;
    }

    // MARK: Pointer

    protected override void OnMouseLeftButtonDown(MouseButtonEventArgs e)
    {
        base.OnMouseLeftButtonDown(e);
        if (e.OriginalSource is DependencyObject origin && textField is not null && IsWithin(origin, textField)) return;
        if (PointerDown(e.GetPosition(this), e.ClickCount)) e.Handled = true;
    }

    /// <summary>Pointer entry points in view coordinates; the mouse overrides call these, and the
    /// in-process interaction check drives them directly.</summary>
    internal bool PointerDown(Point view, int clickCount)
    {
        FinishText();
        Focus();
        if (Layout is not { } layout) return false;
        if (tool == EditorTool.Select && selectedIndex is { } selected && selected < state.Annotations.Count)
        {
            var rect = ViewRect(AnnotationBounds(state.Annotations[selected]), layout);
            rect.Inflate(5, 5);
            var corners = Corners(rect);
            for (var i = 0; i < corners.Length; i++)
            {
                if ((corners[i] - view).Length > 9) continue;
                gestureBefore = state.Clone();
                gestureStart = SourcePoint(view);
                resizeCorner = i;
                BeginPointer();
                return true;
            }
        }
        if (SourcePoint(view, clamp: false) is not { } point)
        {
            if (tool == EditorTool.Select && clickCount == 2) BackgroundDoubleClick?.Invoke();
            ClearSelection();
            return false;
        }
        int? hit = null;
        if (tool == EditorTool.Select)
        {
            for (var i = state.Annotations.Count - 1; i >= 0; i--)
            {
                var bounds = AnnotationBounds(state.Annotations[i]);
                bounds.Inflate(10, 10);
                if (bounds.Contains(point)) { hit = i; break; }
            }
            if (clickCount == 2 && hit is null && !layout.CropRect.Contains(point))
            {
                BackgroundDoubleClick?.Invoke();
                return true;
            }
        }
        gestureBefore = state.Clone();
        gestureStart = point;
        draftIndex = null;
        resizeCorner = null;
        if (tool == EditorTool.Select)
        {
            selectedIndex = hit;
            SelectionChanged?.Invoke(hit is { } h ? state.Annotations[h] : null);
            UpdateAccessibility();
            if (clickCount == 2 && hit is { } index && state.Annotations[index].Kind == AnnotationKind.Text)
                StartText(state.Annotations[index].Points[0], index);
            else BeginPointer();
            InvalidateVisual();
            return true;
        }
        if (tool == EditorTool.Text) { StartText(point); return true; }
        BeginPointer();
        if (tool == EditorTool.Crop) { cropDraft = new Rect(point, new Size(0, 0)); InvalidateVisual(); return true; }
        if (tool.Kind() is not { } kind) return true;
        var annotation = new Annotation(kind, new[] { point, point }, AnnotationColor, LineWidth, "", TextSize);
        if (kind == AnnotationKind.Number) annotation.Text = (state.Annotations.Count(a => a.Kind == AnnotationKind.Number) + 1).ToString();
        state.Annotations.Add(annotation);
        draftIndex = state.Annotations.Count - 1;
        StateChanged();
        return true;
    }

    private bool pointerActive;

    private void BeginPointer()
    {
        pointerActive = true;
        CaptureMouse();
    }

    /// <summary>Maps a source-pixel point to view coordinates (used by the interaction check).</summary>
    internal Point? ViewPointFor(Point source) => Layout is { } layout ? ViewPoint(source, layout) : null;

    internal Annotation? SelectedAnnotation => selectedIndex is { } index && index < state.Annotations.Count ? state.Annotations[index] : null;
    internal TextBox? ActiveTextField => textField;

    /// <summary>Resize handles of the selected mark in view coordinates.</summary>
    internal Point[] SelectionCorners()
    {
        if (SelectedAnnotation is not { } annotation || Layout is not { } layout) return Array.Empty<Point>();
        var rect = ViewRect(AnnotationBounds(annotation), layout);
        rect.Inflate(5, 5);
        return Corners(rect);
    }

    private static bool IsWithin(DependencyObject element, DependencyObject ancestor)
    {
        for (var current = element; current is not null; current = VisualTreeHelper.GetParent(current))
            if (current == ancestor) return true;
        return false;
    }

    protected override void OnMouseMove(MouseEventArgs e)
    {
        base.OnMouseMove(e);
        if (e.LeftButton == MouseButtonState.Pressed) PointerMove(e.GetPosition(this), Keyboard.Modifiers.HasFlag(ModifierKeys.Shift));
    }

    internal void PointerMove(Point view, bool shift)
    {
        if (textField is not null || !pointerActive) return;
        if (gestureStart is not { } start || SourcePoint(view) is not { } point) return;
        if (tool == EditorTool.Select && selectedIndex is { } index && gestureBefore is { } before &&
            index < before.Annotations.Count && index < state.Annotations.Count && state.Annotations[index].Id == before.Annotations[index].Id)
        {
            var original = before.Annotations[index];
            if (resizeCorner is { } corner)
            {
                var bounds = AnnotationBounds(original);
                var anchor = Corners(bounds)[3 - corner];
                var resized = new Rect(Math.Min(anchor.X, point.X), Math.Min(anchor.Y, point.Y),
                                       Math.Max(1, Math.Abs(point.X - anchor.X)), Math.Max(1, Math.Abs(point.Y - anchor.Y)));
                state.Annotations[index] = AnnotationGeometry.Resize(original, bounds, resized);
            }
            else
            {
                var moved = original.Clone();
                moved.Points = original.Points.Select(p => new Point(p.X + point.X - start.X, p.Y + point.Y - start.Y)).ToList();
                state.Annotations[index] = moved;
            }
            StateChanged();
            InvalidateVisual();
        }
        else if (tool == EditorTool.Crop)
        {
            cropDraft = RectFrom(start, point);
            InvalidateVisual();
        }
        else if (draftIndex is { } draft && draft < state.Annotations.Count && state.Annotations[draft].Points.Count > 0)
        {
            if (shift) point = Constrain(start, point);
            var annotation = state.Annotations[draft];
            if (tool is EditorTool.Pen or EditorTool.Highlighter)
            {
                if (annotation.Points.Count < 20_000) annotation.Points.Add(point);
            }
            else annotation.Points[^1] = point;
            StateChanged();
        }
    }

    /// <summary>Shift: squares and circles; arrows and lines snap to 45°. Stays inside the canvas.</summary>
    private Point Constrain(Point start, Point point)
    {
        var dx = point.X - start.X;
        var dy = point.Y - start.Y;
        if (tool is EditorTool.Rectangle or EditorTool.Ellipse)
        {
            var side = Math.Max(Math.Abs(dx), Math.Abs(dy));
            point = new Point(start.X + (dx < 0 ? -side : side), start.Y + (dy < 0 ? -side : side));
        }
        else if (tool is EditorTool.Arrow or EditorTool.Line)
        {
            var angle = Math.Round(Math.Atan2(dy, dx) / (Math.PI / 4)) * (Math.PI / 4);
            var length = Math.Sqrt(dx * dx + dy * dy);
            point = new Point(start.X + Math.Cos(angle) * length, start.Y + Math.Sin(angle) * length);
        }
        if (Layout is { } layout)
        {
            var limits = layout.CanvasBoundsInSource;
            dx = point.X - start.X; dy = point.Y - start.Y;
            double fraction = 1;
            if (dx > 0) fraction = Math.Min(fraction, (limits.Right - start.X) / dx);
            if (dx < 0) fraction = Math.Min(fraction, (limits.Left - start.X) / dx);
            if (dy > 0) fraction = Math.Min(fraction, (limits.Bottom - start.Y) / dy);
            if (dy < 0) fraction = Math.Min(fraction, (limits.Top - start.Y) / dy);
            fraction = Math.Max(0, fraction);
            point = new Point(start.X + dx * fraction, start.Y + dy * fraction);
        }
        return point;
    }

    private static Rect RectFrom(Point a, Point b) => new(Math.Min(a.X, b.X), Math.Min(a.Y, b.Y), Math.Abs(a.X - b.X), Math.Abs(a.Y - b.Y));

    protected override void OnMouseLeftButtonUp(MouseButtonEventArgs e)
    {
        base.OnMouseLeftButtonUp(e);
        PointerUp();
    }

    internal void PointerUp()
    {
        pointerActive = false;
        if (IsMouseCaptured) ReleaseMouseCapture();
        FinishPointerGesture();
    }

    protected override void OnLostMouseCapture(MouseEventArgs e)
    {
        base.OnLostMouseCapture(e);
        if (!pointerActive) return;
        pointerActive = false;
        FinishPointerGesture();
    }

    public void FinishPointerGesture()
    {
        if (textField is not null || gestureBefore is null) return;
        if (cropDraft is { Width: >= 4, Height: >= 4 } crop)
        {
            state.Crop = crop;
            state.Style = state.Style with { AutoBalance = false };
            Fit();
        }
        if (draftIndex is { } index && index < state.Annotations.Count && state.Annotations[index].Kind != AnnotationKind.Number)
        {
            var points = state.Annotations[index].Points;
            if (points.Count > 0 && (points[^1] - points[0]).Length < 1 && state.Annotations[index].Kind != AnnotationKind.Pen)
                state.Annotations.RemoveAt(index);
        }
        CompleteGesture();
    }

    public bool CancelPointerGesture()
    {
        if (textField is not null || gestureBefore is not { } before) return false;
        state = before;
        StateChanged();
        CompleteGesture();
        return true;
    }

    private void CompleteGesture()
    {
        var before = gestureBefore;
        gestureBefore = null; gestureStart = null; draftIndex = null; cropDraft = null; resizeCorner = null;
        pointerActive = false;
        if (IsMouseCaptured) ReleaseMouseCapture();
        if (before is not null && !before.ContentEquals(state)) { StateChanged(); Commit?.Invoke(before, state.Clone()); }
        InvalidateVisual();
        GestureEnded?.Invoke();
    }

    // MARK: Text

    private void StartText(Point point, int? annotationIndex = null)
    {
        if (Layout is not { } layout) return;
        TextEditingChanged?.Invoke(true);
        textOrigin = point;
        textAnnotationIndex = annotationIndex;
        var position = ViewPoint(point, layout);
        var field = new TextBox
        {
            FontSize = 16, FontWeight = FontWeights.SemiBold, MinWidth = 80,
            Width = Math.Max(80, Math.Min(280, ActualWidth - position.X - 12)),
            Text = annotationIndex is { } index ? state.Annotations[index].Text : "",
            ToolTip = "Type, then press Enter"
        };
        AutomationProperties.SetName(field, "Annotation text");
        SetLeft(field, position.X);
        SetTop(field, position.Y);
        field.KeyDown += (_, e) =>
        {
            if (e.Key == Key.Enter) { e.Handled = true; FinishText(); Focus(); }
            else if (e.Key == Key.Escape) { e.Handled = true; FinishText(cancel: true); Focus(); }
        };
        field.LostKeyboardFocus += (_, _) => Dispatcher.BeginInvoke(() => { if (textField == field) FinishText(); });
        Children.Add(field);
        textField = field;
        field.Focus();
        field.CaretIndex = field.Text.Length;
    }

    public void FinishText(bool cancel = false)
    {
        if (textField is not { } field) return;
        var text = field.Text;
        var origin = textOrigin;
        var index = textAnnotationIndex;
        textField = null; textOrigin = null; textAnnotationIndex = null;
        Children.Remove(field);
        if (!cancel && origin is { } point)
        {
            if (index is { } existing && existing < state.Annotations.Count)
            {
                if (string.IsNullOrWhiteSpace(text)) state.Annotations.RemoveAt(existing);
                else state.Annotations[existing].Text = text;
            }
            else if (!string.IsNullOrWhiteSpace(text))
            {
                state.Annotations.Add(new Annotation(AnnotationKind.Text, new[] { point }, AnnotationColor, LineWidth, text, TextSize));
            }
            StateChanged();
        }
        CompleteGesture();
        TextEditingChanged?.Invoke(false);
    }

    // MARK: Selection and keyboard

    public void DeleteSelection()
    {
        CancelPointerGesture();
        if (selectedIndex is not { } index || index >= state.Annotations.Count) return;
        var before = state.Clone();
        state.Annotations.RemoveAt(index);
        ClearSelection();
        StateChanged();
        Commit?.Invoke(before, state.Clone());
    }

    public void ClearSelection()
    {
        selectedIndex = null;
        SelectionChanged?.Invoke(null);
        UpdateAccessibility();
        InvalidateVisual();
    }

    public void ChangeSelection(Rgba? color = null, double? lineWidth = null, double? fontSize = null)
    {
        if (selectedIndex is not { } index || index >= state.Annotations.Count) return;
        var before = state.Clone();
        var annotation = state.Annotations[index];
        if (color is { } c) annotation.Color = c;
        if (lineWidth is { } w) annotation.LineWidth = w;
        if (fontSize is { } f) annotation.FontSize = f;
        if (before.ContentEquals(state)) return;
        StateChanged();
        Commit?.Invoke(before, state.Clone());
    }

    /// <summary>Tab and Shift+Tab cycle marks in Select, including marks hidden after a resize;
    /// tabbing past the ends leaves the canvas. Escape releases the canvas.</summary>
    protected override void OnKeyDown(KeyEventArgs e)
    {
        if (tool == EditorTool.Select && e.Key == Key.Tab && textField is null)
        {
            FinishPointerGesture();
            var backwards = Keyboard.Modifiers.HasFlag(ModifierKeys.Shift);
            var next = selectedIndex is { } current ? current + (backwards ? -1 : 1) : backwards ? state.Annotations.Count - 1 : 0;
            if (next >= 0 && next < state.Annotations.Count)
            {
                selectedIndex = next;
                SelectionChanged?.Invoke(state.Annotations[next]);
                UpdateAccessibility();
                InvalidateVisual();
                e.Handled = true;
                return;
            }
            ClearSelection();
            MoveFocus(new TraversalRequest(backwards ? FocusNavigationDirection.Previous : FocusNavigationDirection.Next));
            e.Handled = true;
            return;
        }
        if (tool == EditorTool.Select && e.Key == Key.Escape && textField is null && (selectedIndex is not null || gestureBefore is not null))
        {
            CancelPointerGesture();
            ClearSelection();
            e.Handled = true;
            return;
        }
        base.OnKeyDown(e);
    }

    // MARK: Zoom

    public void Fit() { zoom = 1; pan = default; InvalidateVisual(); }

    public void ChangeZoom(double factor)
    {
        zoom = Math.Max(0.25, Math.Min(6, zoom * factor));
        if (zoom <= 1) pan = default;
        InvalidateVisual();
    }

    protected override void OnMouseWheel(MouseWheelEventArgs e)
    {
        base.OnMouseWheel(e);
        // Precision touchpads send pinch as Ctrl+wheel.
        if (Keyboard.Modifiers.HasFlag(ModifierKeys.Control)) { ChangeZoom(1 + e.Delta / 1200.0); e.Handled = true; return; }
        if (zoom <= 1) return;
        if (Keyboard.Modifiers.HasFlag(ModifierKeys.Shift)) pan.X += e.Delta / 3.0; else pan.Y += e.Delta / 3.0;
        InvalidateVisual();
        e.Handled = true;
    }

    // MARK: Drop

    protected override void OnDragOver(DragEventArgs e)
    {
        e.Effects = e.Data.GetDataPresent(DataFormats.FileDrop) || e.Data.GetDataPresent("PNG") || e.Data.GetDataPresent(DataFormats.Bitmap)
            ? DragDropEffects.Copy : DragDropEffects.None;
        e.Handled = true;
    }

    protected override void OnDrop(DragEventArgs e)
    {
        e.Handled = true;
        if (e.Data.GetData(DataFormats.FileDrop) is string[] { Length: > 0 } files) { ImportFile?.Invoke(files[0]); return; }
        if (e.Data.GetData("PNG") is MemoryStream png)
        {
            try { ImportBitmap?.Invoke(ImageLoader.Load(png.ToArray())); } catch (Exception error) { RenderFailed?.Invoke(error); }
            return;
        }
        if (e.Data.GetData(DataFormats.Bitmap) is BitmapSource bitmap) ImportBitmap?.Invoke(bitmap);
    }
}

internal static class AnnotationGeometry
{
    public static Annotation Resize(Annotation annotation, Rect old, Rect rect)
    {
        var changed = annotation.Clone();
        var sx = rect.Width / Math.Max(1, old.Width);
        var sy = rect.Height / Math.Max(1, old.Height);
        changed.Points = annotation.Points.Select(p => new Point(rect.X + (p.X - old.X) * sx, rect.Y + (p.Y - old.Y) * sy)).ToList();
        if (annotation.Kind == AnnotationKind.Text)
        {
            changed.FontSize = Math.Min(512, Math.Max(2, annotation.FontSize * Math.Min(sx, sy)));
            changed.Points = new List<Point> { rect.TopLeft };
        }
        if (annotation.Kind == AnnotationKind.Number)
        {
            changed.FontSize = Math.Min(512, Math.Max(2, Math.Min(rect.Width, rect.Height)));
            changed.Points = new List<Point> { new(rect.X + rect.Width / 2, rect.Y + rect.Height / 2) };
        }
        return changed;
    }
}

/// <summary>Used only on the preview thread. Reduced source rasters and the framed base are
/// reused for the whole editing session; the full source stays export-only, except for tight
/// crops that need more detail than the proxy holds.</summary>
internal sealed class PreviewSourceCache(BitmapSource original, ImagePreview? prepared)
{
    private const int Maximum = 1400;
    private ImagePreview? prepared = prepared;
    private readonly RenderCache cache = new();
    private BitmapSource? backgroundOriginal;
    private ImagePreview? backgroundPrepared;

    public BitmapSource Render(EditState state, BitmapSource? background)
    {
        var proxy = prepared ??= ImageLoader.Preview(original, Maximum);
        var layout = CanvasRenderer.Layout(proxy.SourceSize, state);
        var fullScale = state.Style.FixedWidth is { } width ? width / layout.CanvasSize.Width : state.Style.OutputScale;
        var rasterScale = Math.Min(fullScale, Maximum / Math.Max(layout.CanvasSize.Width, layout.CanvasSize.Height));
        var available = Math.Min(proxy.PixelSize.Width / proxy.SourceSize.Width, proxy.PixelSize.Height / proxy.SourceSize.Height);
        if (rasterScale > available + 0.000001)
            return CanvasRenderer.Render(original, state, background, Maximum, cache);
        return CanvasRenderer.RenderPreview(proxy, state, backgroundPreview: Background(background), maximumDimension: Maximum, cache: cache);
    }

    private ImagePreview? Background(BitmapSource? image)
    {
        if (image is null) { backgroundOriginal = null; backgroundPrepared = null; return null; }
        if (ReferenceEquals(backgroundOriginal, image)) return backgroundPrepared;
        backgroundOriginal = image;
        backgroundPrepared = ImageLoader.Preview(image, Maximum);
        return backgroundPrepared;
    }
}
