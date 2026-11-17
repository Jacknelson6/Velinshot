using System.IO;
using System.Text.Json.Serialization;
using System.Windows;
using System.Windows.Media.Imaging;

namespace Velinshot.Core;

public sealed record HistoryEntry
{
    [JsonConverter(typeof(UpperGuidConverter))] public Guid Id { get; init; }
    [JsonConverter(typeof(ReferenceDateConverter))] public DateTimeOffset CreatedAt { get; init; }
    public string ImageFile { get; init; } = "";
    public string StateFile { get; init; } = "";
    public int Width { get; init; }
    public int Height { get; init; }

    internal string Stem => Id.ToString("D").ToUpperInvariant();
}

internal static class SafeFiles
{
    /// <summary>Writes beside the destination, then replaces it, so readers never see a partial file.</summary>
    public static void WriteAtomic(string path, byte[] data)
    {
        var temporary = Path.Combine(Path.GetDirectoryName(path)!, $".{Path.GetFileName(path)}.{Guid.NewGuid():N}.tmp");
        try
        {
            File.WriteAllBytes(temporary, data);
            File.Move(temporary, path, overwrite: true);
        }
        finally
        {
            if (File.Exists(temporary)) File.Delete(temporary);
        }
    }

    public static bool IsPlainFile(string path, long maximumBytes, out long length)
    {
        length = 0;
        var info = new FileInfo(path);
        if (!info.Exists || info.Attributes.HasFlag(FileAttributes.ReparsePoint) || info.Attributes.HasFlag(FileAttributes.Directory)) return false;
        length = info.Length;
        return length <= maximumBytes;
    }
}

/// <summary>Optional editable history: the original PNG, its edit state and a metadata file that
/// acts as the commit marker. Bounded by entry count and bytes; only owned names are touched.</summary>
public sealed class HistoryStore
{
    public string Directory { get; }
    public int MaxEntries { get; }
    public long MaxBytes { get; }

    public HistoryStore(string directory, int maxEntries = 50, long maxBytes = 250_000_000)
    {
        Directory = Path.GetFullPath(directory);
        MaxEntries = Math.Max(1, Math.Min(500, maxEntries));
        MaxBytes = Math.Max(1, maxBytes);
    }

    public HistoryEntry Save(BitmapSource image, EditState state)
    {
        System.IO.Directory.CreateDirectory(Directory);
        CanvasRenderer.Layout(new Size(image.PixelWidth, image.PixelHeight), state);
        var id = Guid.NewGuid();
        var stem = id.ToString("D").ToUpperInvariant();
        var entry = new HistoryEntry
        {
            Id = id, CreatedAt = DateTimeOffset.FromUnixTimeMilliseconds(DateTimeOffset.UtcNow.ToUnixTimeMilliseconds()), ImageFile = $"{stem}.png", StateFile = $"{stem}.state.json",
            Width = image.PixelWidth, Height = image.PixelHeight
        };
        var imageData = ImageExporter.Data(image, ImageFormat.Png);
        var stateData = VelinshotJson.Serialize(state);
        var entryData = VelinshotJson.Serialize(entry);
        if (stateData.Length > 64_000_000 || (long)imageData.Length + stateData.Length + entryData.Length > MaxBytes)
            throw VelinshotException.CorruptHistory("This screenshot exceeds the history storage limit. It can still be exported.");
        var created = new List<string>();
        try
        {
            var imagePath = SafePath(entry.ImageFile); SafeFiles.WriteAtomic(imagePath, imageData); created.Add(imagePath);
            var statePath = SafePath(entry.StateFile); SafeFiles.WriteAtomic(statePath, stateData); created.Add(statePath);
            // Metadata is the commit marker. A reader never sees half of a new entry.
            var entryPath = SafePath(MetadataName(entry.Id)); SafeFiles.WriteAtomic(entryPath, entryData); created.Add(entryPath);
            EnforceLimits();
            return entry;
        }
        catch
        {
            foreach (var path in created) try { File.Delete(path); } catch { /* best effort */ }
            throw;
        }
    }

    public IReadOnlyList<HistoryEntry> Entries()
    {
        if (!System.IO.Directory.Exists(Directory)) return Array.Empty<HistoryEntry>();
        var entries = new List<HistoryEntry>();
        foreach (var path in System.IO.Directory.EnumerateFiles(Directory, "*.entry.json"))
        {
            try
            {
                var name = Path.GetFileName(path);
                var checkedPath = SafePath(name);
                if (!SafeFiles.IsPlainFile(checkedPath, 16_384, out _)) throw VelinshotException.CorruptHistory("Invalid history metadata.");
                var entry = VelinshotJson.Deserialize<HistoryEntry>(File.ReadAllBytes(checkedPath));
                Validate(entry);
                if (name != MetadataName(entry.Id)) throw VelinshotException.CorruptHistory("History metadata has the wrong identifier.");
                entries.Add(entry);
            }
            catch (VelinshotException) { throw; }
            catch (Exception)
            {
                throw VelinshotException.CorruptHistory("The metadata is damaged. Clear history to remove damaged entries.");
            }
        }
        return entries.OrderByDescending(e => e.CreatedAt).ToList();
    }

    public (BitmapSource image, EditState state) Load(HistoryEntry entry)
    {
        Validate(entry);
        var imagePath = SafePath(entry.ImageFile);
        var statePath = SafePath(entry.StateFile);
        try
        {
            if (!SafeFiles.IsPlainFile(statePath, 64_000_000, out _))
                throw VelinshotException.CorruptHistory("The edit data is invalid or too large.");
            if (!SafeFiles.IsPlainFile(imagePath, ImageLoader.MaximumEncodedBytes, out _))
                throw VelinshotException.CorruptHistory("The source image is missing or invalid.");
            var image = ImageLoader.Load(imagePath);
            if (image.PixelWidth != entry.Width || image.PixelHeight != entry.Height)
                throw VelinshotException.CorruptHistory("The source image does not match its metadata.");
            var state = VelinshotJson.Deserialize<EditState>(File.ReadAllBytes(statePath));
            CanvasRenderer.Layout(new Size(image.PixelWidth, image.PixelHeight), state);
            return (image, state);
        }
        catch (VelinshotException) { throw; }
        catch (Exception)
        {
            throw VelinshotException.CorruptHistory("The source or edit data is missing or damaged.");
        }
    }

    public void Update(HistoryEntry entry, EditState state)
    {
        Validate(entry);
        var metadataPath = SafePath(MetadataName(entry.Id));
        var imagePath = SafePath(entry.ImageFile);
        var statePath = SafePath(entry.StateFile);
        try
        {
            if (!SafeFiles.IsPlainFile(metadataPath, 16_384, out var metadataLength))
                throw VelinshotException.CorruptHistory("The history metadata is invalid.");
            var stored = VelinshotJson.Deserialize<HistoryEntry>(File.ReadAllBytes(metadataPath));
            if (stored != entry) throw VelinshotException.CorruptHistory("This history entry no longer matches its metadata.");
            CanvasRenderer.Layout(new Size(entry.Width, entry.Height), state);
            var stateData = VelinshotJson.Serialize(state);
            if (!SafeFiles.IsPlainFile(imagePath, ImageLoader.MaximumEncodedBytes, out var imageLength) || stateData.Length > 64_000_000 ||
                stateData.Length + imageLength + metadataLength > MaxBytes)
                throw VelinshotException.CorruptHistory("The updated entry exceeds the history storage limit.");
            SafeFiles.WriteAtomic(statePath, stateData);
            EnforceLimits();
        }
        catch (VelinshotException) { throw; }
        catch (Exception)
        {
            throw VelinshotException.CorruptHistory("The history metadata or source is missing, damaged or unwritable.");
        }
    }

    public void Clear()
    {
        if (!System.IO.Directory.Exists(Directory)) return;
        // Recognized names only. An unexpected user file in this folder is preserved.
        foreach (var path in System.IO.Directory.EnumerateFiles(Directory).ToList())
        {
            var name = Path.GetFileName(path);
            if (IsOwnedName(name)) File.Delete(SafePath(name));
        }
    }

    private static string MetadataName(Guid id) => $"{id.ToString("D").ToUpperInvariant()}.entry.json";

    private void Validate(HistoryEntry entry)
    {
        if (entry.ImageFile != $"{entry.Stem}.png" || entry.StateFile != $"{entry.Stem}.state.json")
            throw VelinshotException.InvalidHistoryPath();
        ImageLimits.Validate(entry.Width, entry.Height);
        SafePath(entry.ImageFile);
        SafePath(entry.StateFile);
    }

    private static bool IsOwnedName(string name)
    {
        foreach (var suffix in new[] { ".state.json", ".entry.json", ".png" })
        {
            if (!name.EndsWith(suffix, StringComparison.Ordinal)) continue;
            var stem = name[..^suffix.Length];
            if (Guid.TryParse(stem, out var id) && id.ToString("D").ToUpperInvariant() == stem) return true;
        }
        return false;
    }

    private string SafePath(string name)
    {
        if (string.IsNullOrEmpty(name) || name != Path.GetFileName(name) || name.Contains('/') || name.Contains('\\') ||
            name is "." or ".." || name.IndexOfAny(Path.GetInvalidFileNameChars()) >= 0)
            throw VelinshotException.InvalidHistoryPath();
        var candidate = Path.GetFullPath(Path.Combine(Directory, name));
        if (!string.Equals(Path.GetDirectoryName(candidate), Directory.TrimEnd(Path.DirectorySeparatorChar), StringComparison.OrdinalIgnoreCase))
            throw VelinshotException.InvalidHistoryPath();
        if (File.Exists(candidate) && new FileInfo(candidate).Attributes.HasFlag(FileAttributes.ReparsePoint))
            throw VelinshotException.InvalidHistoryPath();
        return candidate;
    }

    private void EnforceLimits()
    {
        var items = Entries().ToList();
        var sizes = new Dictionary<Guid, long>();
        foreach (var item in items)
        {
            long sum = 0;
            foreach (var name in new[] { item.ImageFile, item.StateFile, MetadataName(item.Id) })
            {
                var info = new FileInfo(SafePath(name));
                if (info.Exists) sum += info.Length;
            }
            sizes[item.Id] = sum;
        }
        var total = sizes.Values.Sum();
        while (items.Count > MaxEntries || total > MaxBytes)
        {
            if (items.Count == 0) break;
            var oldest = items[^1];
            items.RemoveAt(items.Count - 1);
            foreach (var name in new[] { MetadataName(oldest.Id), oldest.ImageFile, oldest.StateFile })
            {
                var path = SafePath(name);
                if (File.Exists(path)) File.Delete(path);
            }
            total -= sizes.GetValueOrDefault(oldest.Id);
        }
    }
}

public sealed class StylePreset
{
    [JsonConverter(typeof(UpperGuidConverter))] public Guid Id { get; set; } = Guid.NewGuid();
    public string Name { get; set; } = "";
    public CanvasStyle Style { get; set; } = new();
}

public sealed class PresetStore
{
    public string FilePath { get; }
    public PresetStore(string filePath) => FilePath = filePath;

    public List<StylePreset> Load()
    {
        if (!File.Exists(FilePath)) return new();
        try
        {
            if (new FileInfo(FilePath).Length > 1_000_000) throw VelinshotException.InvalidPreset("The preset file is too large.");
            var presets = VelinshotJson.Deserialize<List<StylePreset>>(File.ReadAllBytes(FilePath));
            Validate(presets);
            return presets;
        }
        catch (VelinshotException) { throw; }
        catch (Exception)
        {
            throw VelinshotException.InvalidPreset("The preset file is damaged or unreadable.");
        }
    }

    public void Save(List<StylePreset> presets)
    {
        Validate(presets);
        var data = VelinshotJson.Serialize(presets);
        if (data.Length > 1_000_000) throw VelinshotException.InvalidPreset("The preset file is too large.");
        System.IO.Directory.CreateDirectory(Path.GetDirectoryName(Path.GetFullPath(FilePath))!);
        SafeFiles.WriteAtomic(FilePath, data);
    }

    private static void Validate(List<StylePreset> presets)
    {
        if (presets.Count > 200 || presets.Select(p => p.Id).Distinct().Count() != presets.Count ||
            presets.Any(p => string.IsNullOrWhiteSpace(p.Name) || p.Name.Length > 120))
            throw VelinshotException.InvalidPreset("Use unique presets with names of 1 to 120 characters.");
        // Validate settings without depending on a particular screenshot's size.
        foreach (var preset in presets) CanvasRenderer.Layout(new Size(1, 1), new EditState(preset.Style));
    }
}
