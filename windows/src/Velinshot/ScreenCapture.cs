using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using Velinshot.Core;

namespace Velinshot;

/// <summary>A frozen picture of every connected display in virtual-screen physical pixels.
/// Selection happens on this snapshot, so the result matches exactly what was on screen.</summary>
internal sealed class ScreenSnapshot
{
    public required BitmapSource Image { get; init; }
    public required Int32Rect Bounds { get; init; }
    public required IReadOnlyList<Int32Rect> Monitors { get; init; }
    public required IReadOnlyList<CaptureWindow> Windows { get; init; }

    /// <summary>Crops a virtual-screen rectangle (physical pixels) out of the snapshot.</summary>
    public BitmapSource Crop(Int32Rect area)
    {
        var x = Math.Max(area.X, Bounds.X);
        var y = Math.Max(area.Y, Bounds.Y);
        var right = Math.Min(area.X + area.Width, Bounds.X + Bounds.Width);
        var bottom = Math.Min(area.Y + area.Height, Bounds.Y + Bounds.Height);
        if (right - x < 1 || bottom - y < 1) throw VelinshotException.InvalidImage("The selection is outside every display.");
        ImageLimits.Validate(right - x, bottom - y);
        var cropped = new CroppedBitmap(Image, new Int32Rect(x - Bounds.X, y - Bounds.Y, right - x, bottom - y));
        return ImageLoader.Adopt(cropped);
    }
}

internal sealed record CaptureWindow(IntPtr Handle, string Title, Int32Rect Bounds);

internal static class ScreenCapture
{
    public static ScreenSnapshot Take()
    {
        var bounds = new Int32Rect(Native.GetSystemMetrics(Native.SM_XVIRTUALSCREEN), Native.GetSystemMetrics(Native.SM_YVIRTUALSCREEN),
                                   Native.GetSystemMetrics(Native.SM_CXVIRTUALSCREEN), Native.GetSystemMetrics(Native.SM_CYVIRTUALSCREEN));
        if (bounds.Width <= 0 || bounds.Height <= 0) throw VelinshotException.InvalidImage("No display is available to capture.");
        // Windows are listed before any overlay appears, in front-to-back order.
        var windows = VisibleWindows();
        var image = Copy(bounds);
        return new ScreenSnapshot { Image = image, Bounds = bounds, Monitors = Monitors(), Windows = windows };
    }

    public static IReadOnlyList<Int32Rect> Monitors()
    {
        var monitors = new List<Int32Rect>();
        Native.EnumDisplayMonitors(IntPtr.Zero, IntPtr.Zero, (IntPtr monitor, IntPtr dc, ref Native.RECT rect, IntPtr data) =>
        {
            var info = new Native.MONITORINFOEX { cbSize = Marshal.SizeOf<Native.MONITORINFOEX>() };
            if (Native.GetMonitorInfo(monitor, ref info))
                monitors.Add(new Int32Rect(info.rcMonitor.Left, info.rcMonitor.Top, info.rcMonitor.Width, info.rcMonitor.Height));
            return true;
        }, IntPtr.Zero);
        return monitors;
    }

    private static BitmapSource Copy(Int32Rect bounds)
    {
        var screen = Native.GetDC(IntPtr.Zero);
        var memory = Native.CreateCompatibleDC(screen);
        var header = new Native.BITMAPINFOHEADER
        {
            biSize = Marshal.SizeOf<Native.BITMAPINFOHEADER>(), biWidth = bounds.Width, biHeight = -bounds.Height, // top-down
            biPlanes = 1, biBitCount = 32
        };
        var section = Native.CreateDIBSection(screen, ref header, 0, out var bits, IntPtr.Zero, 0);
        try
        {
            if (section == IntPtr.Zero) throw VelinshotException.TooLarge();
            var previous = Native.SelectObject(memory, section);
            // CAPTUREBLT includes layered (translucent) windows.
            if (!Native.BitBlt(memory, 0, 0, bounds.Width, bounds.Height, screen, bounds.X, bounds.Y, Native.SRCCOPY | Native.CAPTUREBLT))
                throw VelinshotException.InvalidImage("Windows did not allow the screen to be copied.");
            Native.SelectObject(memory, previous);
            var stride = bounds.Width * 4;
            var data = new byte[stride * bounds.Height];
            Marshal.Copy(bits, data, 0, data.Length);
            for (var i = 3; i < data.Length; i += 4) data[i] = 255; // The desktop is opaque.
            var image = BitmapSource.Create(bounds.Width, bounds.Height, 96, 96, PixelFormats.Pbgra32, null, data, stride);
            image.Freeze();
            return image;
        }
        finally
        {
            if (section != IntPtr.Zero) Native.DeleteObject(section);
            Native.DeleteDC(memory);
            Native.ReleaseDC(IntPtr.Zero, screen);
        }
    }

    private static List<CaptureWindow> VisibleWindows()
    {
        var own = (uint)Environment.ProcessId;
        var windows = new List<CaptureWindow>();
        Native.EnumWindows((hwnd, _) =>
        {
            if (!Native.IsWindowVisible(hwnd) || Native.IsIconic(hwnd)) return true;
            Native.GetWindowThreadProcessId(hwnd, out var process);
            if (process == own) return true;
            if (Native.DwmGetWindowAttribute(hwnd, Native.DWMWA_CLOAKED, out int cloaked, sizeof(int)) == 0 && cloaked != 0) return true;
            var extended = (long)Native.GetWindowLongPtr(hwnd, Native.GWL_EXSTYLE);
            if ((extended & Native.WS_EX_TOOLWINDOW) != 0 && (extended & Native.WS_EX_APPWINDOW) == 0) return true;
            var className = Native.ClassName(hwnd);
            if (className is "Progman" or "WorkerW") return true;
            if (Native.DwmGetWindowAttribute(hwnd, Native.DWMWA_EXTENDED_FRAME_BOUNDS, out Native.RECT frame, Marshal.SizeOf<Native.RECT>()) != 0 &&
                !Native.GetWindowRect(hwnd, out frame)) return true;
            if (frame.Width < 8 || frame.Height < 8) return true;
            windows.Add(new CaptureWindow(hwnd, Native.WindowTitle(hwnd), new Int32Rect(frame.Left, frame.Top, frame.Width, frame.Height)));
            return true;
        }, IntPtr.Zero);
        return windows;
    }

    public static string? DesktopWallpaperPath()
    {
        var builder = new System.Text.StringBuilder(1024);
        if (Native.SystemParametersInfo(Native.SPI_GETDESKWALLPAPER, (uint)builder.Capacity, builder, 0))
        {
            var path = builder.ToString();
            if (path.Length > 0 && System.IO.File.Exists(path)) return path;
        }
        // Slideshow and some personalization paths keep only the transcoded copy.
        var transcoded = System.IO.Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
                                                "Microsoft", "Windows", "Themes", "TranscodedWallpaper");
        return System.IO.File.Exists(transcoded) ? transcoded : null;
    }

    [Conditional("DEBUG")]
    public static void Trace(string message) => Debug.WriteLine($"[capture] {message}");
}
