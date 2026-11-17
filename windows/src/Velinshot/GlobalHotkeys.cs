using System.Windows.Interop;

namespace Velinshot;

/// <summary>System-wide shortcuts registered with RegisterHotKey on a message-only window.
/// Availability is decided by Windows: another app may already own a combination.</summary>
internal sealed class GlobalHotkeys : IDisposable
{
    private const int CaptureId = 1, QuickCopyId = 2;
    private readonly AppSettings settings;
    private readonly HwndSource source;
    private bool suspended;

    public event Action? Capture;
    public event Action? QuickCopy;
    public string? CaptureError { get; private set; }
    public string? QuickCopyError { get; private set; }

    public GlobalHotkeys(AppSettings settings)
    {
        this.settings = settings;
        source = new HwndSource(new HwndSourceParameters("VelinshotHotkeys") { ParentWindow = new IntPtr(-3), WindowStyle = 0 });
        source.AddHook(WndProc);
    }

    public void Refresh()
    {
        Native.UnregisterHotKey(source.Handle, CaptureId);
        Native.UnregisterHotKey(source.Handle, QuickCopyId);
        CaptureError = QuickCopyError = null;
        if (suspended) return;
        CaptureError = Register(CaptureId, settings.CaptureShortcut);
        QuickCopyError = settings.QuickCopyShortcut == settings.CaptureShortcut
            ? "Capture and copy uses the same shortcut as capture."
            : Register(QuickCopyId, settings.QuickCopyShortcut);
    }

    /// <summary>Releases the shortcuts while one is being recorded in Settings.</summary>
    public void Suspend() { suspended = true; Refresh(); }
    public void Resume() { suspended = false; Refresh(); }

    private string? Register(int id, Shortcut shortcut) =>
        Native.RegisterHotKey(source.Handle, id, shortcut.Modifiers | Native.MOD_NOREPEAT, shortcut.VirtualKey)
            ? null
            : $"Windows could not register {shortcut.Display}. Another app may be using it. Retry, record another shortcut, or use {Shortcut.Fallback.Display}.";

    private IntPtr WndProc(IntPtr hwnd, int message, IntPtr wParam, IntPtr lParam, ref bool handled)
    {
        if (message != Native.WM_HOTKEY) return IntPtr.Zero;
        handled = true;
        switch (wParam.ToInt32())
        {
            case CaptureId: Capture?.Invoke(); break;
            case QuickCopyId: QuickCopy?.Invoke(); break;
        }
        return IntPtr.Zero;
    }

    public void Dispose()
    {
        Native.UnregisterHotKey(source.Handle, CaptureId);
        Native.UnregisterHotKey(source.Handle, QuickCopyId);
        source.RemoveHook(WndProc);
        source.Dispose();
    }
}
