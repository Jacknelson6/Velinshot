using System.Diagnostics;
using System.IO;
using System.IO.Pipes;
using System.Reflection;
using System.Text;
using System.Windows;
using System.Windows.Media.Imaging;
using Velinshot.Core;

namespace Velinshot;

/// <summary>The application controller: notification-area icon, global shortcuts, capture,
/// opening images and editor windows. Velinshot keeps running in the notification area so
/// shortcuts stay available after the last window closes.</summary>
public partial class App : Application
{
    public const string ReleasesUrl = "https://github.com/Jacknelson6/Velinshot/releases";

    internal string[] StartupArguments { get; init; } = Array.Empty<string>();
    private readonly AppSettings settings = AppSettings.Shared;
    private GlobalHotkeys hotkeys = null!;
    private TrayIcon? tray;
    private WelcomeWindow? welcome;
    private SettingsWindow? settingsWindow;
    private HistoryWindow? historyWindow;
    private ClosedScreenshot? lastClosed;
    private bool capturing;
    private CancellationTokenSource? pipeCancellation;

    private sealed record ClosedScreenshot(BitmapSource Image, EditState State, string Title, HistoryEntry? Entry, string HistoryDirectory);
    internal sealed record PreparedDocument(BitmapSource Source, EditState State, string Title, ImagePreview Preview, DocumentAnalysis Analysis);

    internal static new App Current => (App)Application.Current;

    protected override void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);
        DispatcherUnhandledException += (_, args) =>
        {
            Dialogs.Error(null, args.Exception);
            args.Handled = true;
        };
        Theme.Initialize();
        ClipboardExport.CleanTemporaryFiles();
        hotkeys = new GlobalHotkeys(settings);
        hotkeys.Capture += () => Capture();
        hotkeys.QuickCopy += () => Capture(quickCopy: true);
        if (DevTools.TryRun(this, StartupArguments)) return;
        hotkeys.Refresh();
        tray = new TrayIcon(this);
        settings.Changed += SettingsChanged;
        ListenForInstances();
        var handled = HandleArguments(StartupArguments);
        if (!handled && !StartupArguments.Contains("--background") && settings.ShowWelcome) ShowWelcome();
        else if (!handled && hotkeys.CaptureError is { } error) tray?.Notify("Shortcut unavailable", error);
    }

    protected override void OnExit(ExitEventArgs e)
    {
        pipeCancellation?.Cancel();
        hotkeys.Dispose();
        tray?.Dispose();
        base.OnExit(e);
    }

    private void SettingsChanged()
    {
        hotkeys.Refresh();
        welcome?.Refresh(hotkeys);
        settingsWindow?.Refresh();
        tray?.Refresh();
    }

    internal GlobalHotkeys Hotkeys => hotkeys;
    internal AppSettings Settings => settings;

    // MARK: Instances and arguments

    private void ListenForInstances()
    {
        pipeCancellation = new CancellationTokenSource();
        var token = pipeCancellation.Token;
        Task.Run(async () =>
        {
            while (!token.IsCancellationRequested)
            {
                try
                {
                    await using var server = new NamedPipeServerStream(Program.Identity, PipeDirection.In, 1, PipeTransmissionMode.Byte, PipeOptions.Asynchronous);
                    await server.WaitForConnectionAsync(token);
                    using var reader = new StreamReader(server, Encoding.UTF8);
                    var text = await reader.ReadToEndAsync(token);
                    var args = text.Split('\n', StringSplitOptions.RemoveEmptyEntries);
                    _ = Dispatcher.BeginInvoke(() => { if (!HandleArguments(args)) ShowWelcome(); });
                }
                catch (OperationCanceledException) { return; }
                catch (Exception) { await Task.Delay(250, CancellationToken.None); }
            }
        }, token);
    }

    private bool HandleArguments(string[] args)
    {
        if (args.Contains("--capture")) { Capture(); return true; }
        if (args.Contains("--capture-display")) { Capture(display: true); return true; }
        if (args.Contains("--quick-copy")) { Capture(quickCopy: true); return true; }
        if (args.Contains("--demo")) { OpenDemo(); return true; }
        var files = args.Where(a => !a.StartsWith("--", StringComparison.Ordinal) && File.Exists(a)).ToArray();
        if (files.Length == 0) return false;
        OpenFiles(files);
        return true;
    }

    // MARK: Capture

    internal async void Capture(bool quickCopy = false, bool display = false)
    {
        if (capturing) return;
        capturing = true;
        var hidden = new List<Window>();
        try
        {
            if (settings.HideDuringCapture)
            {
                foreach (Window window in Windows)
                    if (window.IsVisible && window is not OverlayWindow) { hidden.Add(window); window.Hide(); }
                if (hidden.Count > 0) await Task.Delay(220); // Let the compositor remove them before copying the screen.
            }
            var snapshot = ScreenCapture.Take();
            var area = await new CaptureSession(snapshot, display ? CaptureMode.Display : CaptureMode.Area).RunAsync();
            foreach (var window in hidden) window.Show();
            hidden.Clear();
            if (area is not { } selection) return;
            var image = snapshot.Crop(selection);
            PrepareImages(new[] { new ImageRequest(image, null, "Screenshot") }, quickCopy: quickCopy);
        }
        catch (Exception error)
        {
            Dialogs.Error(null, $"Capture needs your attention. {error.Message}");
        }
        finally
        {
            foreach (var window in hidden) window.Show();
            capturing = false;
        }
    }

    // MARK: Documents

    internal sealed record ImageRequest(object Input, EditState? State, string Title);

    /// <summary>Decodes, prepares the preview and analysis off the UI thread, then opens editors
    /// (or copies directly for Capture and Copy).</summary>
    internal async void PrepareImages(IReadOnlyList<ImageRequest> requests, HistoryEntry? historyEntry = null, bool quickCopy = false)
    {
        var style = settings.Style;
        foreach (var request in requests)
        {
            try
            {
                var prepared = await StaWorker.Work.Run(() =>
                {
                    var source = request.Input switch
                    {
                        string path => ImageLoader.Load(path),
                        byte[] data => ImageLoader.Load(data),
                        BitmapSource bitmap => ImageLoader.Adopt(bitmap),
                        _ => throw VelinshotException.InvalidImage("Unsupported input.")
                    };
                    var preview = ImageLoader.Preview(source);
                    if (request.State is { } state) return new PreparedDocument(source, state, request.Title, preview, new DocumentAnalysis());
                    var (initial, analysis) = NewDocument.Prepare(source, style);
                    return new PreparedDocument(source, initial, request.Title, preview, analysis);
                });
                if (quickCopy) await CopyPrepared(prepared);
                else Present(prepared.Source, prepared.State, prepared.Title, historyEntry, prepared.Preview, prepared.Analysis);
            }
            catch (Exception error)
            {
                Dialogs.Error(null, $"{request.Title}: {error.Message}");
            }
        }
    }

    private async Task CopyPrepared(PreparedDocument prepared)
    {
        var output = await StaWorker.Work.Run(() => CanvasRenderer.Render(prepared.Source, prepared.State, LoadBackground(prepared.State.Style.BackgroundAssetId)));
        if (!ClipboardExport.Copy(output)) throw VelinshotException.InvalidImage("The clipboard is busy. Try again.");
        HistoryEntry? entry = null;
        string? historyError = null;
        if (settings.HistoryEnabled)
        {
            try { entry = new HistoryStore(settings.HistoryDirectory).Save(prepared.Source, prepared.State); }
            catch (Exception error) { historyError = error.Message; }
        }
        lastClosed = new ClosedScreenshot(prepared.Source, prepared.State, prepared.Title, entry, settings.HistoryDirectory);
        Sound.Play(settings);
        if (historyError is not null) tray?.Notify("Copied, but history was not saved", historyError + " Choose another history folder in Settings.");
        else tray?.Notify("Copied", $"{output.PixelWidth} × {output.PixelHeight} screenshot is on the clipboard.");
    }

    private static BitmapSource? LoadBackground(string? id)
    {
        if (id is null || !Guid.TryParse(id, out _)) return null;
        try { return ImageLoader.Load(Path.Combine(AppSettings.SupportDirectory, "Backgrounds", id + ".png")); }
        catch (Exception) { return null; }
    }

    internal EditorWindow Present(BitmapSource image, EditState? state, string title, HistoryEntry? historyEntry = null,
                                  ImagePreview? preview = null, DocumentAnalysis? analysis = null)
    {
        var editor = new EditorWindow(image, state, title, preview, analysis, settings) { HistoryEntry = historyEntry };
        editor.Closed += (_, _) =>
        {
            lastClosed = new ClosedScreenshot(editor.Source, editor.State.Clone(), editor.DocumentTitle, editor.HistoryEntry, settings.HistoryDirectory);
            QuitIfIdle();
        };
        editor.CaptureRequested += () => Capture();
        editor.OpenRequested += OpenImage;
        editor.PasteRequested += OpenClipboard;
        editor.SettingsRequested += ShowSettings;
        editor.HistoryRequested += ShowHistory;
        editor.ReopenRequested += ReopenClosed;
        editor.DemoRequested += OpenDemo;
        editor.ShortcutsRequested += ShowShortcuts;
        editor.UpdatesRequested += CheckForUpdates;
        editor.AboutRequested += ShowAbout;
        editor.ImportFileRequested += path => PrepareImages(new[] { new ImageRequest(path, null, Path.GetFileName(path)) });
        editor.ImportBitmapRequested += bitmap => PrepareImages(new[] { new ImageRequest(bitmap, null, "Screenshot") });
        welcome?.Close();
        editor.Show();
        editor.Activate();
        return editor;
    }

    internal void OpenFiles(IEnumerable<string> paths) =>
        PrepareImages(paths.Select(path => new ImageRequest(path, null, Path.GetFileName(path))).ToList());

    internal void OpenImage()
    {
        var dialog = new Microsoft.Win32.OpenFileDialog { Title = "Open image", Filter = EditorWindow.ImageFilter, Multiselect = true };
        if (dialog.ShowDialog() == true) OpenFiles(dialog.FileNames);
    }

    internal void OpenClipboard()
    {
        try
        {
            if (Clipboard.GetData("PNG") is MemoryStream png) { PrepareImages(new[] { new ImageRequest(png.ToArray(), null, "Screenshot") }); return; }
            if (Clipboard.ContainsFileDropList())
            {
                var files = Clipboard.GetFileDropList().Cast<string>().Where(File.Exists).ToArray();
                if (files.Length > 0) { OpenFiles(files); return; }
            }
            if (Clipboard.ContainsImage() && Clipboard.GetImage() is { } image) { PrepareImages(new[] { new ImageRequest(image, null, "Screenshot") }); return; }
        }
        catch (Exception) { /* Fall through to the explanation below. */ }
        MessageBox.Show("Copy an image first, or choose Open Image to edit a file.", "No image on the clipboard", MessageBoxButton.OK, MessageBoxImage.Information);
    }

    internal void OpenDemo() => Present(DemoFixture.Make(), DemoFixture.State(), "Studio notes · Demo");

    internal void ReopenClosed()
    {
        if (lastClosed is not { } closed) return;
        var entry = closed.HistoryDirectory == settings.HistoryDirectory ? closed.Entry : null;
        lastClosed = null;
        Present(closed.Image, closed.State, closed.Title, entry);
    }

    internal bool CanReopen => lastClosed is not null;

    internal void OpenHistoryEntry(HistoryEntry entry)
    {
        try
        {
            var (image, state) = new HistoryStore(settings.HistoryDirectory).Load(entry);
            Present(image, state, entry.CreatedAt.ToLocalTime().ToString("g"), entry);
        }
        catch (Exception error) { Dialogs.Error(historyWindow, error); }
    }

    // MARK: Windows

    internal void ShowWelcome()
    {
        if (welcome is null)
        {
            welcome = new WelcomeWindow(this);
            welcome.Closed += (_, _) => { welcome = null; QuitIfIdle(); };
        }
        welcome.Refresh(hotkeys);
        welcome.Show();
        welcome.Activate();
    }

    internal void ShowSettings()
    {
        if (settingsWindow is null)
        {
            settingsWindow = new SettingsWindow(this);
            settingsWindow.Closed += (_, _) => { settingsWindow = null; QuitIfIdle(); };
        }
        settingsWindow.Show();
        settingsWindow.Activate();
    }

    internal void ShowHistory()
    {
        if (historyWindow is null)
        {
            historyWindow = new HistoryWindow(this);
            historyWindow.Closed += (_, _) => { historyWindow = null; QuitIfIdle(); };
        }
        historyWindow.Reload();
        historyWindow.Show();
        historyWindow.Activate();
    }

    internal void ShowShortcuts()
    {
        var text = $"""
            Capture and edit: {settings.CaptureShortcut.Display}
            Capture and copy: {settings.QuickCopyShortcut.Display}
            Capture: drag an area, Space for a window, Esc cancels

            Copy: C or Ctrl+C          Save: S or Ctrl+S
            Undo: Ctrl+Z               Redo: Ctrl+Y or Ctrl+Shift+Z
            Draw D · Arrow A · Rectangle R · Ellipse E
            Text T · Highlight H · Blur B · Redact K
            Number N · Crop X · Line L · Select V
            Delete removes the selected mark; Tab cycles marks
            Fit Ctrl+0 · Zoom Ctrl+= / Ctrl+- · Frame/Backdrop/Output Ctrl+1/2/3
            Reopen the last closed screenshot: Ctrl+Shift+T
            """;
        MessageBox.Show(text, "Keyboard shortcuts", MessageBoxButton.OK, MessageBoxImage.None);
    }

    internal void ShowAbout()
    {
        var version = Assembly.GetExecutingAssembly().GetCustomAttribute<AssemblyInformationalVersionAttribute>()?.InformationalVersion ?? "Development";
        MessageBox.Show($"Velinshot for Windows {version.Split('+')[0]}\n\nFree screenshot editing. Frame, annotate and copy.\nNo account, uploads, analytics or watermark.\n\nMIT License.",
                        "About Velinshot", MessageBoxButton.OK, MessageBoxImage.None);
    }

    internal void CheckForUpdates()
    {
        try { Process.Start(new ProcessStartInfo(ReleasesUrl) { UseShellExecute = true }); }
        catch (Exception error) { Dialogs.Error(null, error); }
    }

    /// <summary>With "keep running" off, Velinshot quits when its last window closes.</summary>
    private void QuitIfIdle()
    {
        Dispatcher.BeginInvoke(() =>
        {
            if (settings.KeepRunningInTray || capturing) return;
            if (Windows.Cast<Window>().Any(w => w.IsVisible)) return;
            Shutdown();
        });
    }

    internal void Quit() => Shutdown();
}
