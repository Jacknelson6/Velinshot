using System.IO;
using System.Text.Json;
using System.Text.Json.Serialization;
using System.Windows.Input;
using Velinshot.Core;

namespace Velinshot;

/// <summary>A global shortcut: Win32 MOD_* flags and a virtual-key code.</summary>
internal readonly record struct Shortcut(uint Modifiers, uint VirtualKey)
{
    public static readonly Shortcut Capture = new(Native.MOD_CONTROL | Native.MOD_SHIFT, 0x34);   // Ctrl+Shift+4
    public static readonly Shortcut QuickCopy = new(Native.MOD_CONTROL | Native.MOD_SHIFT, 0x35); // Ctrl+Shift+5
    public static readonly Shortcut Fallback = new(Native.MOD_CONTROL | Native.MOD_SHIFT, 0x32);  // Ctrl+Shift+2

    [JsonIgnore]
    public string Display
    {
        get
        {
            var parts = new List<string>();
            if ((Modifiers & Native.MOD_CONTROL) != 0) parts.Add("Ctrl");
            if ((Modifiers & Native.MOD_ALT) != 0) parts.Add("Alt");
            if ((Modifiers & Native.MOD_SHIFT) != 0) parts.Add("Shift");
            if ((Modifiers & Native.MOD_WIN) != 0) parts.Add("Win");
            parts.Add(KeyName(KeyInterop.KeyFromVirtualKey((int)VirtualKey)));
            return string.Join("+", parts);
        }
    }

    /// <summary>Builds a shortcut from a key press. Requires Ctrl, Alt or Win unless the key is
    /// Print Screen or a function key, so ordinary typing can never be captured globally.</summary>
    public static Shortcut? FromKey(Key key, ModifierKeys modifiers)
    {
        if (key is Key.LeftCtrl or Key.RightCtrl or Key.LeftAlt or Key.RightAlt or Key.LeftShift or Key.RightShift or
            Key.LWin or Key.RWin or Key.System or Key.None) return null;
        uint flags = 0;
        if (modifiers.HasFlag(ModifierKeys.Control)) flags |= Native.MOD_CONTROL;
        if (modifiers.HasFlag(ModifierKeys.Alt)) flags |= Native.MOD_ALT;
        if (modifiers.HasFlag(ModifierKeys.Shift)) flags |= Native.MOD_SHIFT;
        if (modifiers.HasFlag(ModifierKeys.Windows)) flags |= Native.MOD_WIN;
        var standalone = key is Key.Snapshot || (key >= Key.F1 && key <= Key.F24);
        if (!standalone && (flags & (Native.MOD_CONTROL | Native.MOD_ALT | Native.MOD_WIN)) == 0) return null;
        return new Shortcut(flags, (uint)KeyInterop.VirtualKeyFromKey(key));
    }

    private static string KeyName(Key key) => key switch
    {
        >= Key.D0 and <= Key.D9 => ((int)(key - Key.D0)).ToString(),
        >= Key.NumPad0 and <= Key.NumPad9 => "Num " + (int)(key - Key.NumPad0),
        Key.Snapshot => "PrtScn",
        Key.OemPlus => "=", Key.OemMinus => "-", Key.OemComma => ",", Key.OemPeriod => ".",
        Key.Oem1 => ";", Key.Oem2 => "/", Key.Oem3 => "`", Key.Oem4 => "[", Key.Oem5 => "\\", Key.Oem6 => "]", Key.Oem7 => "'",
        _ => key.ToString()
    };
}

/// <summary>Preferences stored as JSON in %APPDATA%\Velinshot\settings.json.</summary>
internal sealed class AppSettings
{
#if VELINSHOT_UPDATE_TESTS
    public static string SupportDirectory { get; } = FixtureSupportDirectory();
    private static string FixtureSupportDirectory()
    {
        var path = Path.GetFullPath(Environment.GetEnvironmentVariable("VELINSHOT_UPDATE_FIXTURE_DATA")
            ?? throw new InvalidOperationException("Updater fixtures require an isolated data directory."));
        var production = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "Velinshot");
        if (path.Equals(production, StringComparison.OrdinalIgnoreCase) || path.StartsWith(production + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase))
            throw new InvalidOperationException("Updater fixtures must never use production data.");
        return path;
    }
#else
    public static string SupportDirectory { get; } =
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "Velinshot");
#endif

    public static AppSettings Shared { get; } = new(Path.Combine(SupportDirectory, "settings.json"));

    public event Action? Changed;

    private readonly string path;
    private readonly object saveLock = new();
    private Data data;

    private sealed class Data
    {
        public bool CloseAfterCopy { get; set; } = true;
        public bool HideDuringCapture { get; set; } = true;
        public bool KeepRunningInTray { get; set; } = true;
        public bool Sound { get; set; }
        public bool HistoryEnabled { get; set; }
        public bool JpegByDefault { get; set; } = true;
        public double Quality { get; set; } = 0.92;
        public bool ShowWelcome { get; set; } = true;
        public bool AutomaticUpdateChecks { get; set; }
        public DateTime LastUpdateCheckUtc { get; set; } = DateTime.MinValue;
        public string? SkippedUpdateVersion { get; set; }
        public string Filename { get; set; } = "Screenshot";
        public string? SaveDirectory { get; set; }
        public string? HistoryDirectory { get; set; }
        public bool AutoInsetFill { get; set; } = true;
        public Shortcut CaptureShortcut { get; set; } = Shortcut.Capture;
        public Shortcut QuickCopyShortcut { get; set; } = Shortcut.QuickCopy;
        public CanvasStyle? CanvasStyle { get; set; }
    }

    public AppSettings(string path)
    {
        this.path = path;
        data = Read(path);
    }

    private static Data Read(string path)
    {
        try
        {
            if (File.Exists(path) && new FileInfo(path).Length < 1_000_000)
                return JsonSerializer.Deserialize<Data>(File.ReadAllBytes(path), VelinshotJson.Options) ?? new Data();
        }
        catch (Exception) { /* A damaged settings file falls back to defaults. */ }
        return new Data();
    }

    private void Save(bool notify = true)
    {
        lock (saveLock)
        {
            try
            {
                Directory.CreateDirectory(Path.GetDirectoryName(path)!);
                var bytes = JsonSerializer.SerializeToUtf8Bytes(data, VelinshotJson.Options);
                var temporary = path + ".tmp";
                File.WriteAllBytes(temporary, bytes);
                File.Move(temporary, path, overwrite: true);
            }
            catch (Exception) { /* Preferences are best effort; the app keeps working in memory. */ }
        }
        if (notify) Changed?.Invoke();
    }

    public bool CloseAfterCopy { get => data.CloseAfterCopy; set { data.CloseAfterCopy = value; Save(); } }
    public bool HideDuringCapture { get => data.HideDuringCapture; set { data.HideDuringCapture = value; Save(); } }
    public bool KeepRunningInTray { get => data.KeepRunningInTray; set { data.KeepRunningInTray = value; Save(); } }
    public bool Sound { get => data.Sound; set { data.Sound = value; Save(); } }
    public bool HistoryEnabled { get => data.HistoryEnabled; set { data.HistoryEnabled = value; Save(); } }
    public bool JpegByDefault { get => data.JpegByDefault; set { data.JpegByDefault = value; Save(); } }
    public double Quality { get => Math.Clamp(data.Quality, 0.1, 1); set { data.Quality = Math.Clamp(value, 0.1, 1); Save(); } }
    public bool ShowWelcome { get => data.ShowWelcome; set { data.ShowWelcome = value; Save(); } }
    public bool AutomaticUpdateChecks { get => data.AutomaticUpdateChecks; set { data.AutomaticUpdateChecks = value; Save(); } }
    internal DateTime LastUpdateCheckUtc { get => data.LastUpdateCheckUtc; set { data.LastUpdateCheckUtc = value; Save(notify: false); } }
    internal string? SkippedUpdateVersion { get => data.SkippedUpdateVersion; set { data.SkippedUpdateVersion = value; Save(notify: false); } }
    public string Filename { get => data.Filename; set { data.Filename = value; Save(); } }
    public Shortcut CaptureShortcut { get => data.CaptureShortcut; set { data.CaptureShortcut = value; Save(); } }
    public Shortcut QuickCopyShortcut { get => data.QuickCopyShortcut; set { data.QuickCopyShortcut = value; Save(); } }

    public string SaveDirectory
    {
        get => data.SaveDirectory is { Length: > 0 } stored && Directory.Exists(stored)
            ? stored : Environment.GetFolderPath(Environment.SpecialFolder.MyPictures);
        set { data.SaveDirectory = value; Save(); }
    }

    public string HistoryDirectory
    {
        get => data.HistoryDirectory is { Length: > 0 } stored ? stored : Path.Combine(SupportDirectory, "History");
        set { data.HistoryDirectory = value; Save(); }
    }

    /// <summary>Whether new documents follow the screenshot's edge color for the inset fill.</summary>
    public bool AutoInsetFill { get => data.AutoInsetFill; set { data.AutoInsetFill = value; Save(notify: false); } }

    /// <summary>The last frame style, applied to the next capture.</summary>
    public CanvasStyle Style
    {
        get => (data.CanvasStyle ?? new CanvasStyle()) with { AutoInsetColor = data.AutoInsetFill };
        set { data.CanvasStyle = value; data.AutoInsetFill = value.AutoInsetColor; Save(notify: false); }
    }
}
