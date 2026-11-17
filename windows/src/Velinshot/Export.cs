using System.IO;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Media.Imaging;
using Velinshot.Core;
using Windows.ApplicationModel.DataTransfer;
using Windows.Storage;
using Windows.Storage.Streams;

namespace Velinshot;

/// <summary>Clipboard, drag and temporary-file exports.</summary>
internal static class ClipboardExport
{
    public static string TemporaryDirectory { get; } = Path.Combine(Path.GetTempPath(), "Velinshot");

    /// <summary>Copies a bitmap (for apps that read CF_DIB) plus PNG data (keeps transparency in
    /// apps that read the "PNG" format). The data stays available after Velinshot quits.</summary>
    public static bool Copy(BitmapSource image)
    {
        var png = ImageExporter.Data(image, ImageFormat.Png);
        for (var attempt = 0; attempt < 5; attempt++)
        {
            try
            {
                var data = new DataObject();
                data.SetImage(image);
                data.SetData("PNG", new MemoryStream(png), false);
                System.Windows.Clipboard.SetDataObject(data, copy: true);
                return true;
            }
            catch (COMException)
            {
                Thread.Sleep(60); // Another app is holding the clipboard open.
            }
        }
        return false;
    }

    /// <summary>A finished PNG file plus image data for drag and drop.</summary>
    public static DataObject DragData(BitmapSource image, string title)
    {
        var png = ImageExporter.Data(image, ImageFormat.Png);
        var path = WriteTemporary(png, title, "png");
        var data = new DataObject();
        data.SetFileDropList(new System.Collections.Specialized.StringCollection { path });
        data.SetData("PNG", new MemoryStream(png), false);
        data.SetImage(image);
        return data;
    }

    public static string WriteTemporary(byte[] data, string title, string extension)
    {
        var folder = Path.Combine(TemporaryDirectory, Guid.NewGuid().ToString("N")[..8]);
        Directory.CreateDirectory(folder);
        var name = string.Concat(title.Select(c => Path.GetInvalidFileNameChars().Contains(c) ? '-' : c)).Trim();
        if (name.Length == 0 || name.Length > 80) name = "Screenshot";
        if (Path.HasExtension(name)) name = Path.GetFileNameWithoutExtension(name);
        var path = Path.Combine(folder, $"{name}.{extension}");
        File.WriteAllBytes(path, data);
        return path;
    }

    /// <summary>Removes drag and share files older than a day.</summary>
    public static void CleanTemporaryFiles()
    {
        try
        {
            if (!Directory.Exists(TemporaryDirectory)) return;
            foreach (var folder in Directory.EnumerateDirectories(TemporaryDirectory))
                if (Directory.GetLastWriteTimeUtc(folder) < DateTime.UtcNow.AddDays(-1)) Directory.Delete(folder, recursive: true);
        }
        catch (Exception) { /* Temporary files are best effort. */ }
    }
}

/// <summary>The Windows Share sheet for a desktop window (no built-in cloud upload).</summary>
internal static class ShareExport
{
    public static async Task ShowAsync(IntPtr window, BitmapSource image, string title)
    {
        var png = await StaWorker.Work.Run(() => ImageExporter.Data(image, ImageFormat.Png));
        var path = ClipboardExport.WriteTemporary(png, title, "png");
        var file = await StorageFile.GetFileFromPathAsync(path);
        var manager = DataTransferManagerInterop.GetForWindow(window);
        void Requested(DataTransferManager sender, DataRequestedEventArgs args)
        {
            manager.DataRequested -= Requested;
            var request = args.Request;
            request.Data.Properties.Title = string.IsNullOrWhiteSpace(title) ? "Screenshot" : title;
            request.Data.Properties.Description = "Framed with Velinshot";
            request.Data.SetStorageItems(new IStorageItem[] { file });
            request.Data.SetBitmap(RandomAccessStreamReference.CreateFromFile(file));
        }
        manager.DataRequested += Requested;
        DataTransferManagerInterop.ShowShareUIForWindow(window);
    }
}

internal static class Sound
{
    public static void Play(AppSettings preferences)
    {
        if (!preferences.Sound) return;
        try
        {
            var path = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Windows), "Media", "Windows Navigation Start.wav");
            if (File.Exists(path)) new System.Media.SoundPlayer(path).Play();
            else System.Media.SystemSounds.Asterisk.Play();
        }
        catch (Exception) { /* Sound is optional. */ }
    }
}
