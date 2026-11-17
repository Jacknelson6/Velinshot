using System.IO;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using Microsoft.Win32;
using Velinshot.Core;

namespace Velinshot;

internal abstract class StudioWindow : Window
{
    protected StudioWindow(string title, double width, double height)
    {
        Title = title;
        Width = width;
        Height = height;
        Icon = UI.AppIcon(64);
        WindowStartupLocation = WindowStartupLocation.CenterScreen;
        SetResourceReference(BackgroundProperty, "StudioSurface");
        FontFamily = (FontFamily)FindResource("StudioFont");
        UseLayoutRounding = true;
        SourceInitialized += (_, _) => Theme.ApplyTitleBar(this);
    }
}

/// <summary>Shown at launch (optional) and from the notification-area icon.</summary>
internal sealed class WelcomeWindow : StudioWindow
{
    private readonly Button capture;
    private readonly Button note;
    private readonly App app;

    public WelcomeWindow(App app) : base("Velinshot", 420, 470)
    {
        this.app = app;
        ResizeMode = ResizeMode.NoResize;
        var logo = new Image { Source = UI.AppIcon(144), Width = 72, Height = 72 };
        var title = UI.Label("Velinshot", 26, FontWeights.SemiBold);
        title.HorizontalAlignment = HorizontalAlignment.Center;
        var subline = UI.Label("Capture, frame, mark it up. Copy and carry on.", 13, secondary: true);
        subline.HorizontalAlignment = HorizontalAlignment.Center;
        capture = UI.Button("Capture", "capture", () => { Close(); app.Capture(); }, "Studio.PrimaryButton");
        capture.Width = 260;
        var open = UI.Button("Open Image…", "open", () => app.OpenImage(), "Studio.SecondaryButton");
        open.Width = 260;
        var paste = UI.Button("Open from Clipboard", "clipboard", () => app.OpenClipboard(), iconSize: 16);
        paste.Width = 260;
        var demo = UI.Button("Open Demo Image", null, () => app.OpenDemo());
        demo.Width = 260;
        note = UI.Button("Settings", "settings", () => app.ShowSettings(), iconSize: 16);
        note.Width = 340;
        var stack = new StackPanel { VerticalAlignment = VerticalAlignment.Center, HorizontalAlignment = HorizontalAlignment.Center };
        foreach (var (element, top) in new (FrameworkElement, double)[] { (logo, 0), (title, 14), (subline, 6), (capture, 26), (open, 10), (paste, 6), (demo, 2), (note, 14) })
        {
            element.Margin = new Thickness(0, top, 0, 0);
            element.HorizontalAlignment = HorizontalAlignment.Center;
            stack.Children.Add(element);
        }
        Content = stack;
        KeyDown += (_, e) => { if (e.Key == Key.Escape) Close(); };
    }

    public void Refresh(GlobalHotkeys hotkeys)
    {
        capture.Content = UI.Content("capture", $"Capture   {app.Settings.CaptureShortcut.Display}");
        if (hotkeys.CaptureError is null) note.Content = UI.Content("settings", "Settings", 16);
        else
        {
            var text = new TextBlock { Text = $"Could not register {app.Settings.CaptureShortcut.Display}. Open Settings.", TextWrapping = TextWrapping.Wrap };
            text.SetResourceReference(TextBlock.ForegroundProperty, "StudioError");
            note.Content = text;
        }
    }
}

/// <summary>Preferences: shortcuts, workflow, files and history.</summary>
internal sealed class SettingsWindow : StudioWindow
{
    private const string RunKey = @"Software\Microsoft\Windows\CurrentVersion\Run";
    private readonly App app;
    private readonly AppSettings settings;
    private readonly ShortcutRecorder captureRecorder, copyRecorder;
    private readonly TextBlock shortcutStatus = UI.Label("", 12, secondary: true);
    private readonly TextBlock saveFolder = UI.Label("", 12, secondary: true);
    private readonly TextBlock historyFolder = UI.Label("", 12, secondary: true);

    public SettingsWindow(App app) : base("Velinshot Settings", 560, 720)
    {
        this.app = app;
        settings = app.Settings;
        MinWidth = 480; MinHeight = 420;
        captureRecorder = new ShortcutRecorder(app.Hotkeys, () => settings.CaptureShortcut, value => settings.CaptureShortcut = value);
        copyRecorder = new ShortcutRecorder(app.Hotkeys, () => settings.QuickCopyShortcut, value => settings.QuickCopyShortcut = value);
        var stack = new StackPanel { Margin = new Thickness(28, 24, 28, 28) };
        void Add(UIElement element, double top = 10)
        {
            if (element is FrameworkElement framework) framework.Margin = new Thickness(0, top, 0, 0);
            stack.Children.Add(element);
        }
        Add(UI.Label("Make it feel like yours.", 22, FontWeights.SemiBold), 0);
        Add(UI.Label("Fast capture, quiet defaults, everything on your PC.", 12, secondary: true), 4);

        Add(Section("Keyboard shortcuts"), 26);
        Add(Row("Capture and edit", captureRecorder));
        Add(Row("Capture and copy", copyRecorder));
        shortcutStatus.TextWrapping = TextWrapping.Wrap;
        shortcutStatus.TextTrimming = TextTrimming.None;
        Add(shortcutStatus, 8);
        var shortcutButtons = new WrapPanel();
        foreach (var button in new[]
        {
            UI.Button("Retry shortcuts", null, () => { app.Hotkeys.Refresh(); Refresh(); }, "Studio.SecondaryButton"),
            UI.Button($"Use {Shortcut.Fallback.Display} for capture", null, () => settings.CaptureShortcut = Shortcut.Fallback, "Studio.SecondaryButton"),
            UI.Button($"Use {Shortcut.Capture.Display}", null, () => settings.CaptureShortcut = Shortcut.Capture, "Studio.SecondaryButton")
        })
        {
            button.Height = 32;
            button.Margin = new Thickness(0, 0, 8, 8);
            shortcutButtons.Children.Add(button);
        }
        Add(shortcutButtons, 8);

        Add(Section("Screen capture"), 18);
        var captureNote = UI.Label("Windows needs no extra permission to capture the screen. Content that an app protects from capture, such as some video players, appears black.", 12, secondary: true);
        captureNote.TextWrapping = TextWrapping.Wrap;
        captureNote.TextTrimming = TextTrimming.None;
        Add(captureNote, 8);

        Add(Section("Workflow"), 22);
        Add(UI.Check("Close screenshot after copying", settings.CloseAfterCopy, v => settings.CloseAfterCopy = v));
        Add(UI.Check("Hide Velinshot windows while capturing", settings.HideDuringCapture, v => settings.HideDuringCapture = v), 6);
        Add(UI.Check("Keep running in the notification area when windows close", settings.KeepRunningInTray, v => settings.KeepRunningInTray = v), 6);
        Add(UI.Check("Play a sound after copying or saving", settings.Sound, v => settings.Sound = v), 6);
        Add(UI.Check("Show welcome window when opening the app", settings.ShowWelcome, v => settings.ShowWelcome = v), 6);
        Add(UI.Check("Launch at sign-in", LaunchesAtSignIn(), SetLaunchAtSignIn), 6);

        Add(Section("Updates"), 22);
        var automaticUpdates = UI.Check("Check for updates automatically", settings.AutomaticUpdateChecks, value => settings.AutomaticUpdateChecks = value);
        automaticUpdates.IsEnabled = app.UpdatesAvailable;
        Add(automaticUpdates);
        var updateNote = UI.Label(app.UpdatesAvailable
            ? "Notify me when an update is available. Downloads, installation and restarting stay under my control."
            : app.UpdateUnavailableReason ?? "Updates are unavailable in this development build.", 12, secondary: true);
        updateNote.TextWrapping = TextWrapping.Wrap;
        updateNote.TextTrimming = TextTrimming.None;
        Add(updateNote, 6);
        Add(UI.Button("Check for updates…", null, app.CheckForUpdates, "Studio.SecondaryButton"), 8);

        Add(Section("Files & history"), 22);
        Add(UI.Check("Compress to JPEG by default", settings.JpegByDefault, v => settings.JpegByDefault = v));
        var quality = new Slider { Minimum = 10, Maximum = 100, Value = Math.Round(settings.Quality * 100), SmallChange = 1, LargeChange = 10, Width = 220, IsMoveToPointEnabled = true };
        var qualityValue = UI.Label($"{quality.Value:0}%", 12, secondary: true);
        AutomationProperties.SetName(quality, "JPEG quality");
        quality.ValueChanged += (_, _) => { qualityValue.Text = $"{quality.Value:0}%"; settings.Quality = Math.Round(quality.Value) / 100; };
        var qualityRow = new StackPanel { Orientation = Orientation.Horizontal, Children = { quality, qualityValue } };
        qualityValue.Margin = new Thickness(10, 0, 0, 0);
        Add(Row("JPEG quality", qualityRow), 8);
        Add(UI.Check("Keep editable screenshot history on this PC", settings.HistoryEnabled, v => settings.HistoryEnabled = v), 10);
        var historyNote = UI.Label("History is off by default. When enabled, it keeps at most 50 captures or 250 MB. Clear it from the History window.", 11, secondary: true);
        historyNote.TextWrapping = TextWrapping.Wrap;
        historyNote.TextTrimming = TextTrimming.None;
        Add(historyNote, 4);
        var filename = new TextBox { Text = settings.Filename, Width = 220, FontSize = 13 };
        AutomationProperties.SetName(filename, "File name prefix");
        filename.TextChanged += (_, _) => settings.Filename = filename.Text;
        Add(Row("File name prefix", filename), 12);
        Add(UI.Action("Choose default save folder…", "folder", ChooseSaveFolder), 14);
        Add(saveFolder, 4);
        Add(UI.Action("Choose history folder…", "clock", ChooseHistoryFolder), 10);
        Add(historyFolder, 4);
        var privacy = UI.Label("Free. No accounts, uploads, analytics or watermark. Screenshots stay on this PC unless you share them.", 11, secondary: true);
        privacy.TextWrapping = TextWrapping.Wrap;
        privacy.TextTrimming = TextTrimming.None;
        Add(privacy, 24);
        Content = new ScrollViewer { Content = stack, VerticalScrollBarVisibility = ScrollBarVisibility.Auto };
        Refresh();
    }

    public void Refresh()
    {
        captureRecorder.Refresh();
        copyRecorder.Refresh();
        var errors = new[] { app.Hotkeys.CaptureError, app.Hotkeys.QuickCopyError }.Where(e => e is not null).ToArray();
        shortcutStatus.Text = errors.Length == 0 ? "Both shortcuts are registered with Windows." : string.Join("\n", errors);
        shortcutStatus.SetResourceReference(TextBlock.ForegroundProperty, errors.Length == 0 ? "StudioSecondaryText" : "StudioError");
        saveFolder.Text = settings.SaveDirectory;
        historyFolder.Text = settings.HistoryDirectory;
    }

    private static FrameworkElement Section(string title) => UI.Label(title, 15, FontWeights.SemiBold);

    private static FrameworkElement Row(string title, FrameworkElement control)
    {
        var row = new DockPanel { LastChildFill = false };
        var label = UI.Label(title);
        DockPanel.SetDock(label, Dock.Left);
        DockPanel.SetDock(control, Dock.Right);
        row.Children.Add(label);
        row.Children.Add(control);
        return row;
    }

    private void ChooseSaveFolder()
    {
        var dialog = new OpenFolderDialog { Title = "Default save folder", InitialDirectory = settings.SaveDirectory };
        if (dialog.ShowDialog(this) == true) settings.SaveDirectory = dialog.FolderName;
    }

    private void ChooseHistoryFolder()
    {
        var dialog = new OpenFolderDialog { Title = "Velinshot creates its own Velinshot History folder inside your selection" };
        if (dialog.ShowDialog(this) != true) return;
        var folder = Path.Combine(dialog.FolderName, "Velinshot History");
        try
        {
            Directory.CreateDirectory(folder);
            settings.HistoryDirectory = folder;
        }
        catch (Exception error) { Dialogs.Error(this, error); }
    }

    private static string LaunchCommand => $"\"{Environment.ProcessPath}\" --background";

    private static bool LaunchesAtSignIn()
    {
        using var key = Registry.CurrentUser.OpenSubKey(RunKey);
        return key?.GetValue("Velinshot") is string value && value == LaunchCommand;
    }

    private void SetLaunchAtSignIn(bool enabled)
    {
        try
        {
            using var key = Registry.CurrentUser.CreateSubKey(RunKey);
            if (enabled) key.SetValue("Velinshot", LaunchCommand);
            else key.DeleteValue("Velinshot", throwOnMissingValue: false);
        }
        catch (Exception error) { Dialogs.Error(this, error); }
    }
}

/// <summary>Records a global shortcut. The current shortcuts are released while recording.</summary>
internal sealed class ShortcutRecorder : Button
{
    private readonly GlobalHotkeys hotkeys;
    private readonly Func<Shortcut> read;
    private readonly Action<Shortcut> write;
    private bool recording;

    public ShortcutRecorder(GlobalHotkeys hotkeys, Func<Shortcut> read, Action<Shortcut> write)
    {
        this.hotkeys = hotkeys;
        this.read = read;
        this.write = write;
        SetResourceReference(StyleProperty, "Studio.SecondaryButton");
        Height = 32;
        MinWidth = 200;
        AutomationProperties.SetName(this, "Record keyboard shortcut");
        Click += (_, _) => Start();
        LostKeyboardFocus += (_, _) => Stop();
    }

    public void Refresh() { if (!recording) Content = read().Display; }

    private void Start()
    {
        recording = true;
        hotkeys.Suspend();
        Content = "Press shortcut… Esc to cancel";
        Focus();
    }

    private void Stop()
    {
        if (!recording) return;
        recording = false;
        hotkeys.Resume();
        Refresh();
    }

    protected override void OnPreviewKeyDown(KeyEventArgs e)
    {
        if (!recording) { base.OnPreviewKeyDown(e); return; }
        e.Handled = true;
        var key = e.Key == Key.System ? e.SystemKey : e.Key;
        if (key == Key.Escape) { Stop(); return; }
        if (Shortcut.FromKey(key, Keyboard.Modifiers) is not { } shortcut)
        {
            if (key is not (Key.LeftCtrl or Key.RightCtrl or Key.LeftAlt or Key.RightAlt or Key.LeftShift or Key.RightShift or Key.LWin or Key.RWin))
                Content = "Include Ctrl, Alt or Win";
            return;
        }
        recording = false;
        write(shortcut);
        hotkeys.Resume();
        Refresh();
    }
}

/// <summary>Optional editable history.</summary>
internal sealed class HistoryWindow : StudioWindow
{
    private readonly App app;
    private readonly ListView list = new() { BorderThickness = new Thickness(0) };
    private readonly TextBlock status = UI.Label("", 12, secondary: true);
    private readonly CheckBox enabled;

    public HistoryWindow(App app) : base("Screenshot History", 560, 440)
    {
        this.app = app;
        MinWidth = 420; MinHeight = 300;
        var view = new GridView();
        view.Columns.Add(new GridViewColumn { Header = "Capture", Width = 300, DisplayMemberBinding = new System.Windows.Data.Binding("Title") });
        view.Columns.Add(new GridViewColumn { Header = "Taken", Width = 200, DisplayMemberBinding = new System.Windows.Data.Binding("Taken") });
        list.View = view;
        AutomationProperties.SetName(list, "Saved screenshots");
        list.MouseDoubleClick += (_, _) => OpenSelected();
        list.KeyDown += (_, e) => { if (e.Key == Key.Enter) OpenSelected(); };
        var open = UI.Button("Open selected", "open", OpenSelected, "Studio.PrimaryButton", iconSize: 16);
        open.Height = 34;
        var clear = UI.Button("Clear history…", null, ClearHistory, "Studio.SecondaryButton");
        clear.Height = 34;
        clear.Margin = new Thickness(8, 0, 0, 0);
        enabled = UI.Check("Keep history", app.Settings.HistoryEnabled, value => { app.Settings.HistoryEnabled = value; Reload(); });
        var bar = new DockPanel { Margin = new Thickness(16, 10, 16, 14), LastChildFill = false };
        DockPanel.SetDock(enabled, Dock.Left);
        bar.Children.Add(enabled);
        var buttons = new StackPanel { Orientation = Orientation.Horizontal, Children = { open, clear } };
        DockPanel.SetDock(buttons, Dock.Right);
        bar.Children.Add(buttons);
        status.Margin = new Thickness(16, 8, 16, 0);
        status.TextWrapping = TextWrapping.Wrap;
        var root = new DockPanel();
        DockPanel.SetDock(bar, Dock.Bottom);
        DockPanel.SetDock(status, Dock.Bottom);
        root.Children.Add(bar);
        root.Children.Add(status);
        list.Margin = new Thickness(8, 8, 8, 0);
        root.Children.Add(list);
        Content = root;
    }

    private sealed record Row(HistoryEntry Entry, string Title, string Taken);

    public void Reload()
    {
        enabled.IsChecked = app.Settings.HistoryEnabled;
        list.Items.Clear();
        try
        {
            var entries = new HistoryStore(app.Settings.HistoryDirectory).Entries();
            foreach (var entry in entries)
                list.Items.Add(new Row(entry, $"{entry.Width} × {entry.Height} screenshot", entry.CreatedAt.ToLocalTime().ToString("f")));
            status.Text = app.Settings.HistoryEnabled
                ? $"{entries.Count} saved · {app.Settings.HistoryDirectory}"
                : entries.Count > 0 ? "History is off. Existing entries stay until you clear them." : "History is off. Turn it on to keep editable screenshots on this PC.";
        }
        catch (Exception error) { status.Text = error.Message; }
    }

    private void OpenSelected()
    {
        if (list.SelectedItem is Row row) app.OpenHistoryEntry(row.Entry);
    }

    private void ClearHistory()
    {
        if (MessageBox.Show(this, "Remove every saved screenshot and its edits from history? This cannot be undone.", "Clear history",
                            MessageBoxButton.OKCancel, MessageBoxImage.Warning) != MessageBoxResult.OK) return;
        try { new HistoryStore(app.Settings.HistoryDirectory).Clear(); }
        catch (Exception error) { Dialogs.Error(this, error); }
        Reload();
    }
}
