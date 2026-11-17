using System.Globalization;
using System.Windows;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using Microsoft.Win32;

namespace Velinshot;

internal enum CaptureMode { Area, Window, Display }

/// <summary>Selection over a frozen snapshot: one overlay per display, sharing one selection in
/// virtual-screen physical pixels, so a drag may cross displays of different scale.
/// Space switches area/window selection, Escape or right-click cancels, and changing the
/// connected displays cancels so the user can start again.</summary>
internal sealed class CaptureSession
{
    private readonly ScreenSnapshot snapshot;
    private readonly List<OverlayWindow> overlays = new();
    private readonly TaskCompletionSource<Int32Rect?> completion = new();
    private bool finished;

    public CaptureMode Mode { get; private set; }
    public Point? DragStart { get; private set; }
    public Point? DragCurrent { get; private set; }
    public Int32Rect? Hover { get; private set; }
    public string? HoverTitle { get; private set; }

    public CaptureSession(ScreenSnapshot snapshot, CaptureMode mode)
    {
        this.snapshot = snapshot;
        Mode = mode;
    }

    /// <summary>The selected area, or null when cancelled.</summary>
    public Task<Int32Rect?> Result => completion.Task;

    public Task<Int32Rect?> RunAsync(bool engage = true)
    {
        foreach (var monitor in snapshot.Monitors) overlays.Add(new OverlayWindow(this, snapshot, monitor));
        SystemEvents.DisplaySettingsChanged += DisplaysChanged;
        foreach (var overlay in overlays) overlay.Show();
        if (!engage) { Invalidate(); return completion.Task; }
        if (Native.GetCursorPos(out var cursor))
        {
            var point = new Point(cursor.X, cursor.Y);
            UpdateHover(point);
            (overlays.FirstOrDefault(o => o.Contains(point)) ?? overlays.FirstOrDefault())?.Engage();
        }
        else overlays.FirstOrDefault()?.Engage();
        Invalidate();
        return completion.Task;
    }

    private void DisplaysChanged(object? sender, EventArgs e) => Application.Current.Dispatcher.BeginInvoke(() => Finish(null));

    public void Finish(Int32Rect? result)
    {
        if (finished) return;
        finished = true;
        SystemEvents.DisplaySettingsChanged -= DisplaysChanged;
        foreach (var overlay in overlays) overlay.Close();
        completion.TrySetResult(result);
    }

    public void Invalidate() { foreach (var overlay in overlays) overlay.Redraw(); }

    public void ToggleWindowMode()
    {
        if (Mode == CaptureMode.Display) return;
        Mode = Mode == CaptureMode.Area ? CaptureMode.Window : CaptureMode.Area;
        DragStart = DragCurrent = null;
        if (Native.GetCursorPos(out var cursor)) UpdateHover(new Point(cursor.X, cursor.Y));
        Invalidate();
    }

    public void Pressed(Point point)
    {
        if (Mode != CaptureMode.Area) return;
        DragStart = DragCurrent = point;
        Invalidate();
    }

    public void Moved(Point point, bool dragging)
    {
        if (Mode == CaptureMode.Area)
        {
            if (!dragging || DragStart is null) return;
            DragCurrent = point;
        }
        else UpdateHover(point);
        Invalidate();
    }

    public void Released(Point point)
    {
        switch (Mode)
        {
            case CaptureMode.Area when DragStart is { } start:
            {
                DragCurrent = point;
                var area = Normalize(start, point);
                if (area.Width >= 3 && area.Height >= 3) { Finish(area); return; }
                DragStart = DragCurrent = null; // A plain click keeps the overlay open.
                Invalidate();
                return;
            }
            case CaptureMode.Window or CaptureMode.Display:
                UpdateHover(point);
                if (Hover is { } target) Finish(target);
                return;
        }
    }

    public Int32Rect? Selection => DragStart is { } start && DragCurrent is { } current ? Normalize(start, current) : null;

    private static Int32Rect Normalize(Point a, Point b)
    {
        var left = (int)Math.Floor(Math.Min(a.X, b.X));
        var top = (int)Math.Floor(Math.Min(a.Y, b.Y));
        var right = (int)Math.Ceiling(Math.Max(a.X, b.X));
        var bottom = (int)Math.Ceiling(Math.Max(a.Y, b.Y));
        return new Int32Rect(left, top, right - left, bottom - top);
    }

    private void UpdateHover(Point point)
    {
        Hover = null;
        HoverTitle = null;
        if (Mode == CaptureMode.Display)
        {
            foreach (var monitor in snapshot.Monitors)
                if (Contains(monitor, point)) { Hover = monitor; return; }
            return;
        }
        if (Mode != CaptureMode.Window) return;
        foreach (var window in snapshot.Windows)
        {
            if (!Contains(window.Bounds, point)) continue;
            var bounds = Intersect(window.Bounds, snapshot.Bounds);
            if (bounds.Width < 1 || bounds.Height < 1) continue;
            Hover = bounds;
            HoverTitle = window.Title;
            return;
        }
    }

    public static bool Contains(Int32Rect rect, Point point) =>
        point.X >= rect.X && point.X < rect.X + rect.Width && point.Y >= rect.Y && point.Y < rect.Y + rect.Height;

    private static Int32Rect Intersect(Int32Rect a, Int32Rect b)
    {
        var left = Math.Max(a.X, b.X); var top = Math.Max(a.Y, b.Y);
        var right = Math.Min(a.X + a.Width, b.X + b.Width); var bottom = Math.Min(a.Y + a.Height, b.Y + b.Height);
        return right <= left || bottom <= top ? default : new Int32Rect(left, top, right - left, bottom - top);
    }
}

/// <summary>A borderless topmost window covering exactly one display in physical pixels.</summary>
internal sealed class OverlayWindow : Window
{
    private readonly CaptureSession session;
    private readonly Int32Rect monitor;
    private readonly OverlaySurface surface;

    public OverlayWindow(CaptureSession session, ScreenSnapshot snapshot, Int32Rect monitor)
    {
        this.session = session;
        this.monitor = monitor;
        WindowStyle = WindowStyle.None;
        ResizeMode = ResizeMode.NoResize;
        ShowInTaskbar = false;
        Topmost = true;
        WindowStartupLocation = WindowStartupLocation.Manual;
        Background = Brushes.Black;
        Cursor = Cursors.Cross;
        Title = "Velinshot capture";
        var region = new CroppedBitmap(snapshot.Image, new Int32Rect(monitor.X - snapshot.Bounds.X, monitor.Y - snapshot.Bounds.Y, monitor.Width, monitor.Height));
        region.Freeze();
        surface = new OverlaySurface(this, session, region);
        Content = surface;
        SourceInitialized += (_, _) => Place();
        DpiChanged += (_, _) => Dispatcher.BeginInvoke(Place);
        Deactivated += (_, _) => { };
    }

    private void Place()
    {
        var handle = new WindowInteropHelper(this).Handle;
        Native.SetWindowPos(handle, Native.HWND_TOPMOST, monitor.X, monitor.Y, monitor.Width, monitor.Height, 0);
    }

    public bool Contains(Point physical) => CaptureSession.Contains(monitor, physical);

    public void Engage()
    {
        Activate();
        Focus();
        Native.SetForegroundWindow(new WindowInteropHelper(this).Handle);
        Keyboard.Focus(this);
    }

    public void Redraw() => surface.InvalidateVisual();

    private Point Physical(MouseEventArgs e) => PointToScreen(e.GetPosition(this));

    protected override void OnMouseLeftButtonDown(MouseButtonEventArgs e)
    {
        CaptureMouse();
        session.Pressed(Physical(e));
        e.Handled = true;
    }

    protected override void OnMouseMove(MouseEventArgs e) => session.Moved(Physical(e), e.LeftButton == MouseButtonState.Pressed && IsMouseCaptured);

    protected override void OnMouseLeftButtonUp(MouseButtonEventArgs e)
    {
        var point = Physical(e);
        if (IsMouseCaptured) ReleaseMouseCapture();
        session.Released(point);
        e.Handled = true;
    }

    protected override void OnMouseRightButtonUp(MouseButtonEventArgs e) { session.Finish(null); e.Handled = true; }

    protected override void OnKeyDown(KeyEventArgs e)
    {
        if (e.Key == Key.Escape) { session.Finish(null); e.Handled = true; }
        else if (e.Key == Key.Space) { session.ToggleWindowMode(); e.Handled = true; }
    }

    /// <summary>Converts a virtual-screen physical rectangle into this window's DIPs.</summary>
    public Rect Local(Int32Rect rect) =>
        new(PointFromScreen(new Point(rect.X, rect.Y)), PointFromScreen(new Point(rect.X + rect.Width, rect.Y + rect.Height)));

    public bool Intersects(Int32Rect rect) =>
        rect.X < monitor.X + monitor.Width && rect.X + rect.Width > monitor.X && rect.Y < monitor.Y + monitor.Height && rect.Y + rect.Height > monitor.Y;
}

internal sealed class OverlaySurface(OverlayWindow window, CaptureSession session, BitmapSource region) : FrameworkElement
{
    private static readonly Brush Dim = Frozen(new SolidColorBrush(Color.FromArgb(0x73, 0, 0, 0)));
    private static readonly Brush Pill = Frozen(new SolidColorBrush(Color.FromArgb(0xE6, 0x19, 0x1A, 0x25)));
    private static readonly Pen Outline = Frozen(new Pen(Brushes.White, 1.5));
    private static readonly Pen Shade = Frozen(new Pen(new SolidColorBrush(Color.FromArgb(0x80, 0, 0, 0)), 3));
    private static readonly Pen Accent = Frozen(new Pen(new SolidColorBrush(Theme.Iris), 3));

    private static T Frozen<T>(T value) where T : Freezable { value.Freeze(); return value; }

    protected override void OnRender(DrawingContext context)
    {
        RenderOptions.SetBitmapScalingMode(this, BitmapScalingMode.NearestNeighbor);
        var bounds = new Rect(0, 0, ActualWidth, ActualHeight);
        context.DrawImage(region, bounds);
        Int32Rect? focus = session.Mode == CaptureMode.Area ? session.Selection : session.Hover;
        if (focus is { } area && window.Intersects(area))
        {
            var local = window.Local(area);
            context.DrawGeometry(Dim, null, new CombinedGeometry(GeometryCombineMode.Exclude, new RectangleGeometry(bounds), new RectangleGeometry(local)));
            if (session.Mode == CaptureMode.Area)
            {
                context.DrawRectangle(null, Shade, local);
                context.DrawRectangle(null, Outline, local);
                Label(context, $"{area.Width} × {area.Height}", new Point(local.X, Math.Max(8, local.Y - 34)));
            }
            else
            {
                var inner = local;
                inner.Inflate(-1.5, -1.5);
                if (inner.Width > 0 && inner.Height > 0) context.DrawRectangle(null, Accent, inner);
                var caption = session.Mode == CaptureMode.Display ? "Click to capture this display" : string.IsNullOrWhiteSpace(session.HoverTitle) ? "Click to capture this window" : session.HoverTitle!;
                Label(context, caption, new Point(Math.Max(8, local.X + 10), Math.Max(8, local.Y + 10)));
            }
        }
        else context.DrawRectangle(Dim, null, bounds);
        var hint = session.Mode switch
        {
            CaptureMode.Area => "Drag to capture an area  ·  Space: window  ·  Esc: cancel",
            CaptureMode.Window => "Click a window  ·  Space: area  ·  Esc: cancel",
            _ => "Click the display to capture  ·  Esc: cancel"
        };
        var text = Format(hint, 13);
        Label(context, hint, new Point(ActualWidth / 2 - (text.WidthIncludingTrailingWhitespace + 24) / 2, 18));
    }

    private FormattedText Format(string text, double size) =>
        new(text, CultureInfo.CurrentUICulture, FlowDirection.LeftToRight, new Typeface(new FontFamily("Segoe UI Variable Text, Segoe UI"), FontStyles.Normal, FontWeights.SemiBold, FontStretches.Normal),
            size, Brushes.White, VisualTreeHelper.GetDpi(this).PixelsPerDip);

    private void Label(DrawingContext context, string value, Point origin)
    {
        var text = Format(value.Length > 80 ? value[..80] + "…" : value, 13);
        var box = new Rect(origin.X, origin.Y, text.WidthIncludingTrailingWhitespace + 24, text.Height + 12);
        if (box.Right > ActualWidth - 8) box.X = Math.Max(8, ActualWidth - 8 - box.Width);
        context.DrawRoundedRectangle(Pill, null, box, 8, 8);
        context.DrawText(text, new Point(box.X + 12, box.Y + 6));
    }
}
