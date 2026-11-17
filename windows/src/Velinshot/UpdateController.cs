using System.ComponentModel;
using System.IO;
using System.Net.Http;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.RegularExpressions;
using System.Windows;
using System.Windows.Interop;
using System.Xml;
using System.Xml.Linq;
using Microsoft.Win32;
using NetSparkleUpdater;
using NetSparkleUpdater.Configurations;
using NetSparkleUpdater.Enums;
using NetSparkleUpdater.Interfaces;
using NetSparkleUpdater.SignatureVerifiers;
using WpfUpdateUI = NetSparkleUpdater.UI.WPF.UIFactory;

namespace Velinshot;

/// <summary>NetSparkle owns discovery, versions, download verification, installation and scheduling.</summary>
internal sealed class UpdateController : IDisposable
{
    private const string InstallerArguments = "/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /SP- /NOCLOSEAPPLICATIONS /NORESTARTAPPLICATIONS";
    private readonly App app;
    private readonly AppSettings settings;
    private readonly UpdateRelease release;
    private readonly SparkleUpdater? updater;
    private readonly SignedUpdateFeed? feed;
    private bool manuallyChecking, disposed;
    private string? notifiedVersion;
    internal string? UnavailableReason { get; }
    internal bool Available => updater is not null;

    internal UpdateController(App app, AppSettings settings) : this(app, settings, UpdateRelease.Current()) { }

    private UpdateController(App app, AppSettings settings, UpdateRelease release)
    {
        this.app = app; this.settings = settings; this.release = release;
        try
        {
            release.Validate();
            feed = new SignedUpdateFeed(release);
            updater = new SparkleUpdater(release.Feed.AbsoluteUri, new Ed25519Checker(SecurityMode.Strict, release.PublicKey))
            {
                UIFactory = new WpfUpdateUI(UI.AppIcon(32)) { HideReleaseNotes = true },
                Configuration = new UpdatePreferences(settings, release.Version),
                AppCastDataDownloader = feed,
                UserInteractionMode = UserInteractionMode.NotSilent,
                RelaunchAfterUpdate = true,
                RestartExecutableName = SafeExecutable(),
                RestartExecutablePath = Path.GetDirectoryName(SafeExecutable())!,
                CustomInstallerArguments = InstallerArguments,
                CheckServerFileName = false
            };
            updater.UpdateDetected += (_, args) =>
            {
                // SignedUpdateFeed has already authenticated and checked every candidate's platform metadata.
                if (manuallyChecking) return;
                args.NextAction = NextUpdateAction.ProhibitUpdate;
                if (settings.AutomaticUpdateChecks && notifiedVersion != args.LatestVersion.Version)
                {
                    notifiedVersion = args.LatestVersion.Version;
                    app.NotifyUpdate("A Velinshot update is available", "Choose Check for Updates from the notification-area menu when you're ready.");
                }
            };
            updater.PreparingToExit += PreparingToExit;
            updater.InstallerProcessAboutToStart += (_, _) => app.Dispatcher.Invoke(() =>
            {
                try { release.ValidateInstallTarget(SafeExecutable()); }
                catch (InvalidDataException error)
                {
#if VELINSHOT_UPDATE_TESTS
                    if (!release.FixtureBuild)
#endif
                        Dialogs.Error(null, error.Message);
                    return false;
                }
                if (app.TryBeginUpdateRestart()) return true;
                ShowBusy(); return false;
            });
            updater.InstallUpdateFailed += (_, _) => app.Dispatcher.Invoke(() => { app.CancelUpdateRestart(); return false; });
            updater.CloseApplication += () => app.Dispatcher.Invoke(() =>
            {
                // Admission freezes new capture/import actions. Check once more at the actual shutdown boundary.
                if (!app.UpdateRestarting || app.UpdateBlockReason() is not null)
                {
                    app.CancelUpdateRestart();
                    throw new InvalidOperationException("Velinshot is busy. The update cannot close the app.");
                }
                app.Shutdown();
            });
            settings.Changed += PreferencesChanged;
        }
        catch (Exception error)
        {
            UnavailableReason = "Updates are unavailable in this build. " + error.Message;
            updater?.Dispose(); feed?.Dispose();
            updater = null; feed = null;
        }
    }

    internal async void Start()
    {
        if (updater is null || disposed) return;
        // The library's scheduler reads UpdatePreferences, whose only persisted opt-in is AppSettings.
        // It performs no request while that setting is false. No second timer or preference store exists.
        try { await updater.StartLoop(doInitialCheck: true, forceInitialCheck: false, TimeSpan.FromHours(24)); }
        catch (Exception) { /* Automatic checks remain quiet; a manual check reports its error. */ }
    }

    internal async void CheckForUpdates()
    {
        if (updater is null)
        {
            MessageBox.Show(UnavailableReason, "Velinshot updates", MessageBoxButton.OK, MessageBoxImage.Information);
            return;
        }
        if (manuallyChecking || disposed) return;
        manuallyChecking = true;
        try { await updater.CheckForUpdatesAtUserRequest(); }
        catch (Exception error) { Dialogs.Error(null, "The update could not be verified. " + error.Message); }
        finally { manuallyChecking = false; }
    }

    private void PreparingToExit(object? sender, CancelEventArgs args) => app.Dispatcher.Invoke(() =>
    {
        if (app.UpdateBlockReason() is null) return;
        args.Cancel = true;
        ShowBusy();
    });

    private void PreferencesChanged() => updater?.Configuration.Reload();

    private void ShowBusy()
    {
#if VELINSHOT_UPDATE_TESTS
        if (release.FixtureBuild) return;
#endif
        MessageBox.Show(app.UpdateBlockReason() ?? "Finish your current action before installing the update.",
            "Keep your screenshots safe", MessageBoxButton.OK, MessageBoxImage.Information);
    }

    private static string SafeExecutable()
    {
        var path = Environment.ProcessPath ?? throw new InvalidDataException("The running executable could not be located.");
        if (!Path.IsPathFullyQualified(path) || path.IndexOfAny(['"', '%', '!', '\r', '\n']) >= 0)
            throw new InvalidDataException("The executable path is not safe for the update helper. Install Velinshot in its standard folder.");
        return path;
    }

    public void Dispose()
    {
        if (disposed) return;
        disposed = true;
        settings.Changed -= PreferencesChanged;
        updater?.Dispose(); feed?.Dispose();
    }

    /// <summary>NetSparkle's configuration is an adapter over the existing settings file, not another authority.</summary>
    private sealed class UpdatePreferences : Configuration
    {
        private readonly AppSettings settings;
        internal UpdatePreferences(AppSettings settings, string version) : base(new ReleaseAssembly(version))
        { this.settings = settings; Reload(); }
        public override void Reload()
        {
            CheckForUpdate = settings.AutomaticUpdateChecks;
            LastCheckTime = settings.LastUpdateCheckUtc == DateTime.MinValue ? DateTime.MinValue : settings.LastUpdateCheckUtc.ToLocalTime();
            LastVersionSkipped = settings.SkippedUpdateVersion;
            DidRunOnce = true; IsFirstRun = false;
        }
        public override void TouchCheckTime() { base.TouchCheckTime(); settings.LastUpdateCheckUtc = DateTime.UtcNow; }
        public override void SetVersionToSkip(string version) { base.SetVersionToSkip(version); settings.SkippedUpdateVersion = version; }
    }

    private sealed class ReleaseAssembly(string version) : IAssemblyAccessor
    {
        public string AssemblyCompany => "Velinshot";
        public string AssemblyCopyright => "Copyright (c) 2026 Jack Nelson";
        public string AssemblyDescription => "Native screenshot editing for Windows";
        public string AssemblyTitle => "Velinshot";
        public string AssemblyProduct => "Velinshot";
        public string AssemblyVersion => version;
    }

#if VELINSHOT_UPDATE_TESTS
    internal static UpdateController ForFixture(App app, AppSettings settings, UpdateRelease release) => new(app, settings, release);
    internal SparkleUpdater FixtureEngine => updater ?? throw new InvalidOperationException(UnavailableReason);
    internal bool FixtureDataIsOptedIn => updater?.Configuration.CheckForUpdate == true;
#endif
}

internal sealed record UpdateRelease(Uri Feed, string PublicKey, string Version, string Runtime, string SourceCommit, bool SourceClean, bool FixtureBuild)
{
    internal const string PublicFixtureKey = "11qYAYKxCrfVS/7TyWQHOg7hcvPapiMlrwIaaPcHURo=";
    internal const int MinimumWindowsBuild = 19041;
    internal static readonly XNamespace Sparkle = "http://www.andymatuschak.org/xml-namespaces/sparkle";
    internal static readonly XNamespace Velinshot = "https://github.com/Jacknelson6/Velinshot/updates";

    internal static UpdateRelease Current()
    {
        var assembly = Assembly.GetExecutingAssembly();
        var metadata = assembly.GetCustomAttributes<AssemblyMetadataAttribute>().ToDictionary(a => a.Key, a => a.Value ?? "");
        var runtime = metadata.GetValueOrDefault("VelinshotRuntime", "");
        var fileVersion = assembly.GetCustomAttribute<AssemblyFileVersionAttribute>()?.Version ?? "";
        var path = runtime == "win-arm64" ? "appcast-arm64.xml" : "appcast.xml";
        return new UpdateRelease(new Uri("https://raw.githubusercontent.com/Jacknelson6/Velinshot/updates/windows/" + path),
            metadata.GetValueOrDefault("VelinshotUpdatePublicKey", ""), fileVersion, runtime,
            metadata.GetValueOrDefault("VelinshotSourceCommit", ""), metadata.GetValueOrDefault("VelinshotSourceClean") == "true",
            metadata.GetValueOrDefault("VelinshotFixtureBuild") == "true");
    }

    internal void Validate()
    {
        byte[] key;
        try { key = Convert.FromBase64String(PublicKey); }
        catch (FormatException) { throw new InvalidDataException("No valid Windows release public key is configured."); }
        if (key.Length != 32 || Convert.ToBase64String(key) != PublicKey || key.All(value => value == 0))
            throw new InvalidDataException("The Windows release public key is invalid.");
        if (!System.Version.TryParse(Version, out var version) || version.Revision < 1 || version.Build < 0)
            throw new InvalidDataException("The Windows update build number is missing.");
        if (Runtime is not ("win-x64" or "win-arm64") || !Regex.IsMatch(SourceCommit, "^[0-9a-f]{40}$") || !SourceClean)
            throw new InvalidDataException("This build has no clean Windows source or architecture provenance.");
#if VELINSHOT_UPDATE_TESTS
        if (FixtureBuild)
        {
            if (PublicKey != PublicFixtureKey || !Feed.IsLoopback || Feed.Scheme != "http")
                throw new InvalidDataException("Fixture builds require the public fixture key and a loopback feed.");
            ValidateInstallTarget(Environment.ProcessPath);
            return;
        }
#endif
        if (FixtureBuild || PublicKey == PublicFixtureKey || Feed.Scheme != "https" || Feed.Host != "raw.githubusercontent.com" ||
            !Feed.AbsolutePath.StartsWith("/Jacknelson6/Velinshot/updates/windows/", StringComparison.Ordinal))
            throw new InvalidDataException("Test keys, test builds and unexpected feed locations are forbidden in production.");
        if (!OperatingSystem.IsWindowsVersionAtLeast(10, 0, MinimumWindowsBuild))
            throw new InvalidDataException("Updates require Windows 10 version 2004 or later.");
        var architecture = RuntimeInformation.ProcessArchitecture == Architecture.X64 ? "win-x64" :
                           RuntimeInformation.ProcessArchitecture == Architecture.Arm64 ? "win-arm64" : "unsupported";
        if (Runtime != architecture) throw new InvalidDataException("This build does not match the running Windows architecture.");
        ValidateInstallTarget(Environment.ProcessPath);
    }

    internal void ValidateInstallTarget(string? executable)
    {
        const string instruction = "Install Velinshot with its Setup download to enable in-app updates. Moved and portable copies are not replaced automatically.";
        var appId = "Velinshot.Windows";
#if VELINSHOT_UPDATE_TESTS
        if (FixtureBuild) appId += ".UpdateFixture";
#endif
        // Inno's per-user uninstall record is also how its next installer locates the previous target.
        // Match that registered directory rather than accepting a copied uninstaller beside an EXE.
        using var registration = Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Uninstall\" + appId + "_is1");
        var registered = registration?.GetValue("InstallLocation") as string;
        if (executable is null || !Path.IsPathFullyQualified(executable) || !File.Exists(executable) ||
            string.IsNullOrWhiteSpace(registered) || !Path.IsPathFullyQualified(registered))
            throw new InvalidDataException(instruction);
        var directory = Path.TrimEndingDirectorySeparator(Path.GetFullPath(Path.GetDirectoryName(executable)!));
        var target = Path.TrimEndingDirectorySeparator(Path.GetFullPath(registered));
        if (!StringComparer.OrdinalIgnoreCase.Equals(directory, target)) throw new InvalidDataException(instruction);
    }

    internal void ValidateFeed(byte[] bytes)
    {
        using var stream = new MemoryStream(bytes, writable: false);
        using var reader = XmlReader.Create(stream, new XmlReaderSettings { DtdProcessing = DtdProcessing.Prohibit, XmlResolver = null, MaxCharactersInDocument = 1_000_000 });
        var document = XDocument.Load(reader);
        if (document.Root?.Name != "rss" || document.Root.Element("channel") is not { } channel)
            throw new InvalidDataException("The Windows update feed is invalid.");
        foreach (var item in channel.Elements("item"))
        {
            var enclosure = item.Element("enclosure") ?? throw new InvalidDataException("The update has no installer.");
            var versionText = (string?)enclosure.Attribute(Sparkle + "version");
            var displayVersion = (string?)enclosure.Attribute(Sparkle + "shortVersionString");
            var source = (string?)enclosure.Attribute(Velinshot + "sourceCommit") ?? "";
            var runtime = (string?)enclosure.Attribute(Velinshot + "runtime");
            if (!System.Version.TryParse(versionText, out var version) || version.Revision < 1 ||
                !int.TryParse((string?)enclosure.Attribute(Velinshot + "build"), out var build) || build != version.Revision ||
                !Regex.IsMatch(source, "^[0-9a-f]{40}$") || runtime != Runtime ||
                !int.TryParse((string?)enclosure.Attribute(Velinshot + "minimumWindowsBuild"), out var minimumBuild) ||
                minimumBuild < MinimumWindowsBuild || minimumBuild > Environment.OSVersion.Version.Build ||
                (string?)enclosure.Attribute(Sparkle + "os") != "windows" ||
                !long.TryParse((string?)enclosure.Attribute("length"), out var length) || length < 1 ||
                string.IsNullOrWhiteSpace((string?)enclosure.Attribute(Sparkle + "signature")))
                throw new InvalidDataException("The signed update metadata does not match this Windows build.");
            if (displayVersion is null || !Regex.IsMatch(displayVersion, "^[0-9]+\\.[0-9]+\\.[0-9]+(?:-preview\\.[0-9]+)?$"))
                throw new InvalidDataException("The update display version is invalid.");
            var baseVersion = $"{version.Major}.{version.Minor}.{version.Build}";
            if (displayVersion != baseVersion && displayVersion != $"{baseVersion}-preview.{build}")
                throw new InvalidDataException("The update's display and numeric build versions disagree.");
            if (!Uri.TryCreate((string?)enclosure.Attribute("url"), UriKind.Absolute, out var download))
                throw new InvalidDataException("The update download URL is invalid.");
            var expectedName = $"Velinshot-{displayVersion}-{Runtime}-setup.exe";
            var allowed = download.Scheme == "https" && download.Host == "github.com" &&
                download.AbsolutePath == $"/Jacknelson6/Velinshot/releases/download/v{displayVersion}/{expectedName}";
#if VELINSHOT_UPDATE_TESTS
            allowed |= FixtureBuild && download.Scheme == "http" && download.IsLoopback && download.Authority == Feed.Authority &&
                       download.AbsolutePath == "/" + expectedName;
#endif
            if (!allowed || download.Query.Length != 0 || download.Fragment.Length != 0)
                throw new InvalidDataException("The signed update points to an unexpected installer.");
        }
    }
}

/// <summary>Authenticate bounded feed bytes before parsing platform metadata. NetSparkle verifies them again.</summary>
internal sealed class SignedUpdateFeed : IAppCastDataDownloader, IDisposable
{
    private readonly UpdateRelease release;
    private readonly HttpClient http = new(new HttpClientHandler { AllowAutoRedirect = false }) { Timeout = TimeSpan.FromSeconds(30) };
    private readonly SemaphoreSlim gate = new(1, 1);
    private string? signature;
    internal SignedUpdateFeed(UpdateRelease release)
    { this.release = release; http.DefaultRequestHeaders.UserAgent.ParseAdd("Velinshot-Windows-Updates/1.0"); }
    public Encoding GetAppCastEncoding() => new UTF8Encoding(encoderShouldEmitUTF8Identifier: false, throwOnInvalidBytes: true);
    public string DownloadAndGetAppCastData(string url) => DownloadAndGetAppCastDataAsync(url).GetAwaiter().GetResult();
    public async Task<string> DownloadAndGetAppCastDataAsync(string url)
    {
        await gate.WaitAsync().ConfigureAwait(false);
        try
        {
            if (url == release.Feed.AbsoluteUri + ".signature" && signature is not null) return signature;
            if (url != release.Feed.AbsoluteUri) throw new InvalidDataException("Unexpected update feed request.");
            var bytes = await Download(release.Feed, 1_000_000).ConfigureAwait(false);
            var detached = Encoding.ASCII.GetString(await Download(new Uri(url + ".signature"), 256).ConfigureAwait(false)).Trim();
            var verifier = new Ed25519Checker(SecurityMode.Strict, release.PublicKey);
            if (verifier.VerifySignature(detached, bytes) != ValidationResult.Valid)
                throw new InvalidDataException("The Windows update feed signature is invalid.");
            release.ValidateFeed(bytes);
            signature = detached;
            return GetAppCastEncoding().GetString(bytes);
        }
        finally { gate.Release(); }
    }
    private async Task<byte[]> Download(Uri uri, int limit)
    {
        using var deadline = new CancellationTokenSource(TimeSpan.FromSeconds(30));
        using var response = await http.GetAsync(uri, HttpCompletionOption.ResponseHeadersRead, deadline.Token).ConfigureAwait(false);
        response.EnsureSuccessStatusCode();
        if (response.Content.Headers.ContentLength > limit) throw new InvalidDataException("The update feed exceeds its size limit.");
        await using var input = await response.Content.ReadAsStreamAsync(deadline.Token).ConfigureAwait(false);
        using var output = new MemoryStream();
        var buffer = new byte[8192];
        int read;
        while ((read = await input.ReadAsync(buffer, deadline.Token).ConfigureAwait(false)) != 0)
        {
            if (output.Length + read > limit) throw new InvalidDataException("The update feed exceeds its size limit.");
            output.Write(buffer, 0, read);
        }
        return output.ToArray();
    }
    public void Dispose() { http.Dispose(); }
}
