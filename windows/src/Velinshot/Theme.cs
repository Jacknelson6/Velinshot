using System.Windows;
using System.Windows.Interop;
using System.Windows.Media;
using Microsoft.Win32;

namespace Velinshot;

/// <summary>Quiet neutral chrome that follows the Windows app theme. Iris marks the
/// selected tool and the primary Copy action. Brushes are dynamic resources.</summary>
internal static class Theme
{
    public static readonly Color Iris = Color.FromRgb(0x71, 0x60, 0xE8);
    public static readonly Color Ink = Color.FromRgb(0x19, 0x1A, 0x25);
    public static bool IsDark { get; private set; }
    public static event Action? Changed;

    public static void Initialize()
    {
        Apply();
        SystemEvents.UserPreferenceChanged += (_, e) =>
        {
            if (e.Category is UserPreferenceCategory.General or UserPreferenceCategory.Color or UserPreferenceCategory.VisualStyle)
                Application.Current.Dispatcher.BeginInvoke(() => Apply());
        };
    }

    private static bool SystemUsesDark()
    {
        try
        {
            using var key = Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize");
            return key?.GetValue("AppsUseLightTheme") is int light && light == 0;
        }
        catch (Exception) { return false; }
    }

    public static void Apply(bool? forceDark = null)
    {
        IsDark = forceDark ?? SystemUsesDark();
        var resources = Application.Current.Resources;
        void Set(string key, Color light, Color dark)
        {
            var brush = new SolidColorBrush(IsDark ? dark : light);
            brush.Freeze();
            resources[key] = brush;
        }
        Set("StudioSurface", Color.FromRgb(0xFA, 0xFA, 0xFC), Color.FromRgb(0x1D, 0x1E, 0x25));
        Set("StudioCanvas", Color.FromRgb(0xE6, 0xE7, 0xEF), Color.FromRgb(0x14, 0x15, 0x1A));
        Set("StudioField", Color.FromRgb(0xED, 0xED, 0xF5), Color.FromRgb(0x30, 0x33, 0x3D));
        Set("StudioHover", Color.FromArgb(0x14, 0x19, 0x1A, 0x25), Color.FromArgb(0x1F, 0xFF, 0xFF, 0xFF));
        Set("StudioPressed", Color.FromArgb(0x24, 0x19, 0x1A, 0x25), Color.FromArgb(0x2E, 0xFF, 0xFF, 0xFF));
        Set("StudioSelected", Color.FromArgb(0x24, 0x71, 0x60, 0xE8), Color.FromArgb(0x47, 0xB3, 0xA6, 0xFF));
        Set("StudioAccent", Iris, Color.FromRgb(0xB3, 0xA6, 0xFF));
        Set("StudioPrimary", Iris, Iris);
        Set("StudioPrimaryHover", Color.FromRgb(0x62, 0x51, 0xD8), Color.FromRgb(0x80, 0x70, 0xF0));
        Set("StudioOnPrimary", Colors.White, Colors.White);
        Set("StudioText", Ink, Color.FromRgb(0xF2, 0xF2, 0xF7));
        Set("StudioSecondaryText", Color.FromRgb(0x6B, 0x6B, 0x7A), Color.FromRgb(0xA4, 0xA6, 0xB4));
        Set("StudioDivider", Color.FromArgb(0x1A, 0x19, 0x1A, 0x25), Color.FromArgb(0x24, 0xFF, 0xFF, 0xFF));
        Set("StudioError", Color.FromRgb(0xC4, 0x2B, 0x1C), Color.FromRgb(0xFF, 0x8A, 0x80));
        foreach (Window window in Application.Current.Windows) ApplyTitleBar(window);
        Changed?.Invoke();
    }

    /// <summary>Matches the native title bar to the theme (Windows 10 2004+ and Windows 11).</summary>
    public static void ApplyTitleBar(Window window)
    {
        var handle = new WindowInteropHelper(window).Handle;
        if (handle != IntPtr.Zero) Native.UseDarkTitleBar(handle, IsDark);
    }

    public static Brush Brush(string key) => (Brush)Application.Current.Resources[key];
}
