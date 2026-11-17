using System.Diagnostics;
using System.IO;
using System.Text.Json;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Threading;
using Velinshot.Core;

namespace Velinshot;

/// <summary>Developer commands for verification without driving the desktop:
///   --render-docs folder   renders real windows (light and dark, default and minimum size) to PNG
///   --self-check folder    exercises capture, hotkeys, OCR, export, history and share interop.
/// Both use synthetic content and exit when done.</summary>
internal static class DevTools
{
    public static bool TryRun(App app, string[] args)
    {
        var render = Array.IndexOf(args, "--render-docs");
        var check = Array.IndexOf(args, "--self-check");
        var interaction = Array.IndexOf(args, "--interaction-check");
        if (render < 0 && check < 0 && interaction < 0) return false;
        var index = Math.Max(render, Math.Max(check, interaction));
        var folder = Path.GetFullPath(index + 1 < args.Length ? args[index + 1] : "velinshot-dev");
        Directory.CreateDirectory(folder);
        app.Dispatcher.BeginInvoke(async () =>
        {
            var code = 0;
            try
            {
                if (render >= 0) await RenderDocs(app, folder);
                else if (interaction >= 0) code = await InteractionCheck(app, folder);
                else code = await SelfCheck(folder);
            }
            catch (Exception error)
            {
                File.WriteAllText(Path.Combine(folder, "error.txt"), error.ToString());
                code = 2;
            }
            app.Shutdown(code);
        }, DispatcherPriority.ApplicationIdle);
        return true;
    }

    // MARK: Rendered documentation

    private static async Task RenderDocs(App app, string folder)
    {
        foreach (var dark in new[] { false, true })
        {
            app.ThemeMode = dark ? ThemeMode.Dark : ThemeMode.Light;
            Theme.Apply(forceDark: dark);
            var suffix = dark ? "-dark" : "";
            var editor = Editor(app);
            await Snapshot(editor, 950, 650, Path.Combine(folder, $"editor{suffix}.png"));
            editor.ShowInspectorSection(1);
            await Snapshot(editor, 950, 650, Path.Combine(folder, $"editor-backdrop{suffix}.png"));
            editor.ShowInspectorSection(2);
            await Snapshot(editor, 950, 650, Path.Combine(folder, $"editor-output{suffix}.png"));
            editor.ShowInspectorSection(0);
            editor.SetTool(EditorTool.Arrow);
            await Snapshot(editor, 820, 560, Path.Combine(folder, $"editor-minimum-markup{suffix}.png"));
            editor.SetTool(EditorTool.Blur);
            await Snapshot(editor, 950, 650, Path.Combine(folder, $"editor-blur{suffix}.png"));
            editor.Close();
            var welcome = new WelcomeWindow(app);
            welcome.Refresh(app.Hotkeys);
            await Snapshot(welcome, 420, 470, Path.Combine(folder, $"welcome{suffix}.png"));
            welcome.Close();
            var settings = new SettingsWindow(app);
            await Snapshot(settings, 560, 720, Path.Combine(folder, $"settings{suffix}.png"));
            settings.Close();
        }
        app.ThemeMode = ThemeMode.System;
        Theme.Apply();
    }

    private static EditorWindow Editor(App app)
    {
        var source = DemoFixture.Make();
        var editor = new EditorWindow(source, DemoFixture.State(), "Studio notes · Demo", ImageLoader.Preview(source), null, app.Settings);
        return editor;
    }

    /// <summary>Shows the window off-screen at an exact size and renders its client area at 2x.</summary>
    private static async Task Snapshot(Window window, double width, double height, string path)
    {
        window.ShowActivated = false;
        window.WindowStartupLocation = WindowStartupLocation.Manual;
        window.Left = -20000;
        window.Top = -20000;
        window.MinWidth = 0; window.MinHeight = 0;
        window.Width = width;
        window.Height = height;
        if (!window.IsVisible) window.Show();
        if (window is EditorWindow editor) await editor.Canvas.PrepareSnapshotAsync();
        await Settle(window);
        // The window template's root spans the whole client area, whatever the content's alignment.
        var content = (FrameworkElement)VisualTreeHelper.GetChild(window, 0);
        var size = new Size(content.ActualWidth, content.ActualHeight);
        var target = new RenderTargetBitmap((int)Math.Ceiling(size.Width * 2), (int)Math.Ceiling(size.Height * 2), 192, 192, PixelFormats.Pbgra32);
        var background = new DrawingVisual();
        using (var context = background.RenderOpen()) context.DrawRectangle((Brush)window.Background, null, new Rect(size));
        target.Render(background);
        target.Render(content);
        File.WriteAllBytes(path, ImageExporter.Data(target, ImageFormat.Png));
    }

    private static async Task Settle(Window window)
    {
        for (var i = 0; i < 4; i++)
        {
            window.UpdateLayout();
            await window.Dispatcher.InvokeAsync(() => { }, DispatcherPriority.ApplicationIdle);
            await Task.Delay(120);
        }
    }

    // MARK: Platform self-check

    private static async Task<int> SelfCheck(string folder)
    {
        var results = new List<(string Name, bool Passed, string Detail)>();
        async Task Run(string name, Func<Task<string>> check)
        {
            try { results.Add((name, true, await check())); }
            catch (Exception error) { results.Add((name, false, error.Message)); }
        }

        await Run("screen snapshot covers the virtual screen", () =>
        {
            var clock = Stopwatch.StartNew();
            var snapshot = ScreenCapture.Take();
            var milliseconds = clock.ElapsedMilliseconds;
            if (snapshot.Image.PixelWidth != snapshot.Bounds.Width || snapshot.Image.PixelHeight != snapshot.Bounds.Height) throw new Exception("size mismatch");
            if (snapshot.Monitors.Count == 0) throw new Exception("no monitors");
            var region = snapshot.Monitors[0];
            var crop = snapshot.Crop(new Int32Rect(region.X + 10, region.Y + 10, 320, 200));
            if (crop.PixelWidth != 320 || crop.PixelHeight != 200) throw new Exception("crop size");
            var thumbnail = ImageLoader.Preview(snapshot.Image, 480);
            File.WriteAllBytes(Path.Combine(folder, "desktop-thumbnail.png"), ImageExporter.Data(CanvasRenderer.Render(Pixels(thumbnail), new EditState(new CanvasStyle { Padding = 0, Shadow = 0, CornerRadius = 0, AutoBalance = false })), ImageFormat.Png));
            return Task.FromResult($"{snapshot.Bounds.Width}×{snapshot.Bounds.Height} px at ({snapshot.Bounds.X},{snapshot.Bounds.Y}), {snapshot.Monitors.Count} display(s): " +
                                   string.Join("; ", snapshot.Monitors.Select(m => $"{m.Width}×{m.Height}@({m.X},{m.Y})")) +
                                   $"; {snapshot.Windows.Count} capturable windows; snapshot {milliseconds} ms");
        });

        await Run("global shortcut registration", () =>
        {
            using var hotkeys = new GlobalHotkeys(App.Current.Settings);
            hotkeys.Refresh();
            var result = $"capture {App.Current.Settings.CaptureShortcut.Display}: {hotkeys.CaptureError ?? "registered"}; copy {App.Current.Settings.QuickCopyShortcut.Display}: {hotkeys.QuickCopyError ?? "registered"}";
            return Task.FromResult(result);
        });

        await Run("export renders, encodes and decodes", async () =>
        {
            var source = DemoFixture.Make();
            var clock = Stopwatch.StartNew();
            var output = await StaWorker.Work.Run(() => CanvasRenderer.Render(source, DemoFixture.State()));
            var png = ImageExporter.Data(output, ImageFormat.Png);
            var jpeg = ImageExporter.Data(output, ImageFormat.Jpeg, 0.92);
            File.WriteAllBytes(Path.Combine(folder, "framed-demo.png"), png);
            var decoded = ImageLoader.Load(jpeg);
            if (decoded.PixelWidth != output.PixelWidth) throw new Exception("JPEG size mismatch");
            return $"{output.PixelWidth}×{output.PixelHeight} in {clock.ElapsedMilliseconds} ms; PNG {png.Length / 1024} KB, JPEG {jpeg.Length / 1024} KB";
        });

        await Run("Windows OCR reads the synthetic screenshot", async () =>
        {
            var lines = await StaWorker.Work.RunAsync(() => TextRecognizer.RecognizeAsync(DemoFixture.Make()));
            var text = string.Join("\n", lines.Select(l => l.Text));
            File.WriteAllText(Path.Combine(folder, "recognized-text.txt"), text);
            if (!text.Contains("clarity", StringComparison.OrdinalIgnoreCase)) throw new Exception("expected text not found");
            return $"{lines.Count} lines";
        });

        await Run("share interop is available for a desktop window", () =>
        {
            var window = new Window { Width = 1, Height = 1, ShowInTaskbar = false, WindowStyle = WindowStyle.None, ShowActivated = false, Left = -20000, Top = -20000 };
            window.Show();
            try
            {
                var manager = Windows.ApplicationModel.DataTransfer.DataTransferManagerInterop.GetForWindow(new WindowInteropHelper(window).Handle);
                return Task.FromResult(manager is null ? throw new Exception("no manager") : "DataTransferManager obtained (sheet not shown)");
            }
            finally { window.Close(); }
        });

        await Run("history store round trip in a temporary folder", () =>
        {
            var directory = Path.Combine(folder, "history");
            if (Directory.Exists(directory)) Directory.Delete(directory, true);
            var store = new HistoryStore(directory);
            var entry = store.Save(DemoFixture.Make(), DemoFixture.State());
            var (image, state) = store.Load(entry);
            store.Clear();
            return Task.FromResult($"{image.PixelWidth}×{image.PixelHeight}, {state.Annotations.Count} marks");
        });

        await Run("clipboard copy keeps PNG data", () =>
        {
            // Only runs when the clipboard is empty or holds plain text, which is restored afterwards.
            var previousText = System.Windows.Clipboard.ContainsText() ? System.Windows.Clipboard.GetText() : null;
            var formats = System.Windows.Clipboard.GetDataObject()?.GetFormats() ?? Array.Empty<string>();
            var onlyText = formats.All(f => f.Contains("Text", StringComparison.OrdinalIgnoreCase) || f == "Locale" || f == "OEMText");
            if (formats.Length > 0 && !onlyText) return Task.FromResult("skipped: the clipboard holds non-text data that would be lost");
            var image = ImageLoader.Preview(DemoFixture.Make(), 320);
            var bitmap = Pixels(image);
            if (!ClipboardExport.Copy(bitmap)) throw new Exception("clipboard busy");
            var png = System.Windows.Clipboard.GetData("PNG") as MemoryStream ?? throw new Exception("no PNG format");
            var decoded = ImageLoader.Load(png.ToArray());
            var hasBitmap = System.Windows.Clipboard.ContainsImage();
            if (previousText is not null) System.Windows.Clipboard.SetText(previousText); else System.Windows.Clipboard.Clear();
            return Task.FromResult($"PNG {decoded.PixelWidth}×{decoded.PixelHeight}, bitmap format {(hasBitmap ? "present" : "missing")}; previous text restored");
        });

        var lines = results.Select(r => $"{(r.Passed ? "pass" : "FAIL")}  {r.Name}: {r.Detail}").ToList();
        File.WriteAllLines(Path.Combine(folder, "self-check.txt"), lines);
        File.WriteAllText(Path.Combine(folder, "self-check.json"), JsonSerializer.Serialize(results.Select(r => new { r.Name, r.Passed, r.Detail }), new JsonSerializerOptions { WriteIndented = true }));
        return results.All(r => r.Passed) ? 0 : 1;
    }

    private static BitmapSource Pixels(ImagePreview preview) => preview.Bitmap;

    // MARK: Interaction check

    /// <summary>Drives the real editor and capture selection in-process, off-screen, with a
    /// temporary settings file, so the user's preferences, clipboard and desktop are untouched.</summary>
    private static async Task<int> InteractionCheck(App app, string folder)
    {
        var results = new List<(string Name, bool Passed, string Detail)>();
        void Check(string name, bool passed, string detail = "") => results.Add((name, passed, detail));
        var settings = new AppSettings(Path.Combine(folder, "settings.json"));
        var source = DemoFixture.Make();
        var editor = new EditorWindow(source, DemoFixture.State(), "Interaction check", ImageLoader.Preview(source), null, settings)
        {
            ShowActivated = false, WindowStartupLocation = WindowStartupLocation.Manual, Left = -20000, Top = -20000, Width = 950, Height = 650
        };
        editor.Show();
        await Settle(editor);
        var canvas = editor.Canvas;
        Point View(double x, double y) => canvas.ViewPointFor(new Point(x, y)) ?? throw new Exception("no layout");
        void Key(System.Windows.Input.Key key)
        {
            var args = new System.Windows.Input.KeyEventArgs(System.Windows.Input.Keyboard.PrimaryDevice, PresentationSource.FromVisual(editor)!, 0, key)
            { RoutedEvent = System.Windows.Input.Keyboard.PreviewKeyDownEvent };
            editor.RaiseEvent(args);
        }
        static bool Near(Point a, Point b, double tolerance = 1.5) => Math.Abs(a.X - b.X) <= tolerance && Math.Abs(a.Y - b.Y) <= tolerance;

        // Draw an arrow.
        editor.SetTool(EditorTool.Arrow);
        canvas.PointerDown(View(400, 300), 1);
        canvas.PointerMove(View(500, 350), false);
        canvas.PointerMove(View(600, 400), false);
        canvas.PointerUp();
        var arrow = editor.State.Annotations.LastOrDefault();
        Check("draw an arrow", editor.State.Annotations.Count == 3 && arrow?.Kind == AnnotationKind.Arrow && Near(arrow.Points[1], new Point(600, 400)),
              $"{editor.State.Annotations.Count} marks, end {arrow?.Points.LastOrDefault()}");
        Check("drawing records one undo step", editor.CanUndo);
        editor.UndoEdit();
        var undone = editor.State.Annotations.Count;
        editor.RedoEdit();
        Check("undo and redo", undone == 2 && editor.State.Annotations.Count == 3, $"after undo {undone}, after redo {editor.State.Annotations.Count}");

        // Shift constrains an arrow to 45 degrees.
        canvas.PointerDown(View(200, 600), 1);
        canvas.PointerMove(View(300, 590), true);
        canvas.PointerUp();
        var constrained = editor.State.Annotations[^1];
        Check("shift snaps arrows to 45°", Math.Abs(constrained.Points[1].Y - 600) < 0.5, $"end {constrained.Points[1]}");
        editor.UndoEdit();

        // Select, move and resize.
        editor.SetTool(EditorTool.Select);
        canvas.PointerDown(View(500, 350), 1);
        Check("click selects the arrow", canvas.SelectedAnnotation?.Kind == AnnotationKind.Arrow);
        canvas.PointerMove(View(520, 370), false);
        canvas.PointerUp();
        var moved = editor.State.Annotations[2];
        Check("drag moves the selection", Near(moved.Points[0], new Point(420, 320)) && Near(moved.Points[1], new Point(620, 420)), $"{moved.Points[0]} → {moved.Points[1]}");
        var corners = canvas.SelectionCorners();
        if (corners.Length == 4)
        {
            var before = editor.State.Annotations[2].Points[1];
            canvas.PointerDown(corners[3], 1);
            canvas.PointerMove(corners[3] + new Vector(30, 30), false);
            canvas.PointerUp();
            var after = editor.State.Annotations[2].Points[1];
            Check("corner handle resizes", after.X > before.X + 10 && after.Y > before.Y + 10, $"{before} → {after}");
        }
        else Check("corner handle resizes", false, "no handles");
        Key(System.Windows.Input.Key.Delete);
        Check("Delete removes the selected mark", editor.State.Annotations.Count == 2, $"{editor.State.Annotations.Count} marks");

        // Crop and reset by undo.
        editor.SetTool(EditorTool.Crop);
        canvas.PointerDown(View(100, 100), 1);
        canvas.PointerMove(View(700, 500), false);
        canvas.PointerUp();
        var crop = editor.State.Crop;
        Check("crop sets the visible area", crop is { } c && Math.Abs(c.X - 100) <= 2 && Math.Abs(c.Width - 600) <= 3 && !editor.State.Style.AutoBalance, $"{crop}");
        editor.UndoEdit();
        Check("undo restores the full image", editor.State.Crop is null);

        // Text entry.
        editor.SetTool(EditorTool.Text);
        canvas.PointerDown(View(300, 200), 1);
        var field = canvas.ActiveTextField;
        if (field is not null) { field.Text = "Hello"; canvas.FinishText(); }
        var text = editor.State.Annotations.LastOrDefault();
        Check("text tool adds a text mark", field is not null && text?.Kind == AnnotationKind.Text && text.Text == "Hello", text?.Text ?? "none");

        // Number marks count up.
        editor.SetTool(EditorTool.Number);
        canvas.PointerDown(View(150, 150), 1); canvas.PointerUp();
        canvas.PointerDown(View(150, 250), 1); canvas.PointerUp();
        var numbers = editor.State.Annotations.Where(a => a.Kind == AnnotationKind.Number).Select(a => a.Text).ToArray();
        Check("numbers count up", numbers.SequenceEqual(new[] { "1", "2" }), string.Join(",", numbers));

        // Inspector slider changes the frame and is undoable.
        var padding = editor.State.Style.Padding;
        editor.InspectorSlider("padding").Value = 120;
        Check("padding slider updates the frame", editor.State.Style.Padding == 120, $"{editor.State.Style.Padding}");
        editor.UndoEdit();
        Check("undo restores padding", editor.State.Style.Padding == padding, $"{editor.State.Style.Padding}");

        // Letter shortcuts.
        Key(System.Windows.Input.Key.R);
        var rectangle = canvas.Tool == EditorTool.Rectangle;
        Key(System.Windows.Input.Key.Escape);
        Check("letter shortcuts choose tools; Escape returns to Select", rectangle && canvas.Tool == EditorTool.Select);

        // Export matches the layout.
        var image = await editor.RenderedImageAsync();
        var layout = CanvasRenderer.Layout(new Size(source.PixelWidth, source.PixelHeight), editor.State);
        Check("export size matches the layout", image.PixelWidth == (int)layout.ExportSize.Width && image.PixelHeight == (int)layout.ExportSize.Height,
              $"{image.PixelWidth}×{image.PixelHeight}");
        await Snapshot(editor, 950, 650, Path.Combine(folder, "editor-after-interaction.png"));
        editor.Close();

        // Capture selection logic on a synthetic, off-screen "display".
        var monitor = new Int32Rect(-20000, -20000, 1280, 800);
        var windowRect = new Int32Rect(-20000 + 282, -20000 + 259, 938, 175);
        var snapshot = new ScreenSnapshot
        {
            Image = source, Bounds = monitor, Monitors = new[] { monitor },
            Windows = new[] { new CaptureWindow(IntPtr.Zero, "Make room for what matters", windowRect) }
        };
        Point Physical(double x, double y) => new(monitor.X + x, monitor.Y + y);
        var area = new CaptureSession(snapshot, CaptureMode.Area);
        area.Pressed(Physical(10, 10)); area.Moved(Physical(210, 160), true); area.Released(Physical(210, 160));
        Check("area drag selects physical pixels", await area.Result is { } a && a.Width == 200 && a.Height == 150 && a.X == monitor.X + 10, $"{await area.Result}");
        var click = new CaptureSession(snapshot, CaptureMode.Area);
        click.Pressed(Physical(50, 50)); click.Released(Physical(51, 50));
        Check("a plain click keeps the overlay open", !click.Result.IsCompleted);
        click.Finish(null);
        var windowPick = new CaptureSession(snapshot, CaptureMode.Area);
        windowPick.ToggleWindowMode();
        windowPick.Moved(Physical(400, 300), false);
        windowPick.Released(Physical(400, 300));
        Check("Space then click selects a window", await windowPick.Result is { } w && w.Equals(windowRect), $"{await windowPick.Result}");
        var displayPick = new CaptureSession(snapshot, CaptureMode.Display);
        displayPick.Released(Physical(600, 600));
        Check("display mode selects the clicked display", await displayPick.Result is { } d && d.Equals(monitor));
        Check("snapshot crop returns the selected pixels", snapshot.Crop(new Int32Rect(monitor.X + 282, monitor.Y + 259, 938, 175)).PixelWidth == 938);

        // Render the overlay itself, off-screen.
        var shown = new CaptureSession(snapshot, CaptureMode.Area);
        _ = shown.RunAsync(engage: false);
        shown.Pressed(Physical(270, 240)); shown.Moved(Physical(1235, 450), true);
        await Task.Delay(300);
        foreach (Window window in app.Windows) if (window is OverlayWindow overlay) { RenderWindow(overlay, Path.Combine(folder, "overlay-area.png")); break; }
        shown.ToggleWindowMode();
        shown.Moved(Physical(500, 300), false);
        await Task.Delay(200);
        foreach (Window window in app.Windows) if (window is OverlayWindow overlay) { RenderWindow(overlay, Path.Combine(folder, "overlay-window.png")); break; }
        shown.Finish(null);

        var lines = results.Select(r => $"{(r.Passed ? "pass" : "FAIL")}  {r.Name}{(r.Detail.Length > 0 ? ": " + r.Detail : "")}").ToList();
        File.WriteAllLines(Path.Combine(folder, "interaction-check.txt"), lines);
        return results.All(r => r.Passed) ? 0 : 1;
    }

    private static void RenderWindow(Window window, string path)
    {
        window.UpdateLayout();
        var root = (FrameworkElement)VisualTreeHelper.GetChild(window, 0);
        var target = new RenderTargetBitmap((int)Math.Ceiling(root.ActualWidth), (int)Math.Ceiling(root.ActualHeight), 96, 96, PixelFormats.Pbgra32);
        target.Render(root);
        File.WriteAllBytes(path, ImageExporter.Data(target, ImageFormat.Png));
    }
}
