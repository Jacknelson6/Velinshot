#if VELINSHOT_UPDATE_TESTS
using System.IO;
using System.ComponentModel;
using System.Net;
using System.Reflection;
using System.Text.Json;
using System.Windows.Interop;
using NetSparkleUpdater;
using NetSparkleUpdater.Enums;
using NetSparkleUpdater.SignatureVerifiers;
using Velinshot.Core;

namespace Velinshot;

/// <summary>CI-only fixtures. Neither their commands nor their public test key can ship in a release.</summary>
internal static class UpdateChecks
{
    internal static bool TryRun(App app, string[] args)
    {
        var command = args.FirstOrDefault(value => value is "--update-check" or "--update-install-fixture" or "--update-fixture-relaunched");
        if (command is null) return false;
        var index = Array.IndexOf(args, command);
        if (index + 1 >= args.Length) throw new ArgumentException("An isolated signed-fixture folder is required.");
        var folder = Path.GetFullPath(args[index + 1]);
        Directory.CreateDirectory(folder);
        app.Dispatcher.BeginInvoke(async () =>
        {
            try
            {
                if (command == "--update-fixture-relaunched")
                {
                    var current = UpdateRelease.Current();
#pragma warning disable IL3000 // The fixture intentionally proves this property is empty after single-file publishing.
                    var assemblyLocation = Assembly.GetExecutingAssembly().Location;
#pragma warning restore IL3000
                    var proof = new { version = current.Version, sourceCommit = current.SourceCommit, fixtureBuild = current.FixtureBuild,
                        supportDirectory = AppSettings.SupportDirectory, filename = app.Settings.Filename,
                        executablePath = Environment.ProcessPath, singleFileAssemblyLocation = assemblyLocation };
                    File.WriteAllText(Path.Combine(folder, "relaunch-proof.json"), JsonSerializer.Serialize(proof));
                    app.Shutdown(0); return;
                }
                using var server = new FixtureServer(folder);
                app.Exit += (_, _) => server.Dispose();
                if (command == "--update-check")
                {
                    await Check(app, folder, server);
                    app.Shutdown(0);
                }
                else
                {
                    var controller = Controller(app, "appcast.xml");
                    app.Exit += (_, _) => controller.Dispose();
                    var engine = controller.FixtureEngine;
                    engine.UIFactory = null;
                    var available = await engine.CheckForUpdatesQuietly();
                    if (available.Status != UpdateStatus.UpdateAvailable) throw new InvalidDataException("The authenticated fixture update was not available.");
                    engine.RelaunchAfterUpdateCommandSuffix = "--update-fixture-relaunched \"" + folder + "\"";
                    engine.UserInteractionMode = UserInteractionMode.DownloadAndInstall;
                    await engine.InitAndBeginDownload(available.Updates[0]);
                    // The production controller shuts down only after both NetSparkle's guards admit the installer.
                    await Task.Delay(TimeSpan.FromMinutes(2));
                    throw new TimeoutException("The production updater did not hand off to its installer.");
                }
            }
            catch (Exception error)
            {
                File.WriteAllText(Path.Combine(folder, "update-error.txt"), error.ToString());
                app.Shutdown(2);
            }
        });
        return true;
    }

    private static UpdateController Controller(App app, string feedName, string? version = null)
    {
        var current = UpdateRelease.Current();
        return UpdateController.ForFixture(app, app.Settings, current with {
            Feed = new Uri("http://127.0.0.1:18763/" + feedName), Version = version ?? current.Version
        });
    }

    private static async Task Check(App app, string folder, FixtureServer server)
    {
        var checks = new List<string>();
        void Check(bool value, string message)
        {
            if (!value) throw new InvalidDataException("Updater check failed: " + message);
            checks.Add("PASS " + message);
        }
        async Task RejectFeed(string name)
        {
            using var candidate = Controller(app, name);
            var result = await candidate.FixtureEngine.CheckForUpdatesQuietly();
            Check(result.Status != UpdateStatus.UpdateAvailable, "strict production controller rejects " + name);
        }
        var verifier = new Ed25519Checker(SecurityMode.Strict, UpdateRelease.PublicFixtureKey);
        var payload = File.ReadAllBytes(Path.Combine(folder, "interop-payload.bin"));
        var signature = File.ReadAllText(Path.Combine(folder, "interop-payload.bin.signature")).Trim();
        Check(verifier.VerifySignature(signature, payload) == ValidationResult.Valid, "official Sparkle Keychain signer is accepted by NetSparkle");
        payload[0] ^= 1;
        Check(new Ed25519Checker(SecurityMode.Strict, UpdateRelease.PublicFixtureKey).VerifySignature(signature, payload) != ValidationResult.Valid, "changed signed bytes fail verification");
        var settingsPath = Path.Combine(AppSettings.SupportDirectory, "isolated-preferences.json");
        var preferences = new AppSettings(settingsPath);
        Check(!preferences.AutomaticUpdateChecks, "automatic checks are off by default");
        preferences.AutomaticUpdateChecks = true;
        Check(new AppSettings(settingsPath).AutomaticUpdateChecks, "automatic-check opt-in persists in the one settings authority");
        app.Settings.AutomaticUpdateChecks = false;
        using (var automatic = Controller(app, "appcast.xml"))
        {
            var scheduled = automatic.FixtureEngine;
            scheduled.UIFactory = null;
            Task NextLoop()
            {
                var completed = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
                void Finished(object sender, bool available) { scheduled.LoopFinished -= Finished; completed.TrySetResult(true); }
                scheduled.LoopFinished += Finished;
                return completed.Task.WaitAsync(TimeSpan.FromSeconds(15));
            }
            var before = server.FeedRequests;
            var first = NextLoop();
            await scheduled.StartLoop(doInitialCheck: true, forceInitialCheck: true, TimeSpan.FromMilliseconds(250));
            await first;
            Check(server.FeedRequests == before, "actual library scheduler makes no feed request while opted out");
            server.FeedRequested = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
            app.Settings.AutomaticUpdateChecks = true;
            Check(scheduled.Configuration.CheckForUpdate, "settings-change event immediately enables the library configuration");
            await server.FeedRequested.Task.WaitAsync(TimeSpan.FromSeconds(15));
            app.Settings.AutomaticUpdateChecks = false;
            Check(!scheduled.Configuration.CheckForUpdate, "settings-change event immediately disables the library configuration");
            before = server.FeedRequests;
            await NextLoop(); await NextLoop();
            Check(server.FeedRequests == before, "actual library scheduler starts no further feed requests after opting out");
        }
        using var controller = Controller(app, "appcast.xml");
        var engine = controller.FixtureEngine;
        engine.UIFactory = null;
        var info = await engine.CheckForUpdatesQuietly();
        Check(info.Status == UpdateStatus.UpdateAvailable && info.Updates[0].Version == "1.0.0.4", "real controller authenticates feed and finds the newer numeric build");
        using (var newer = Controller(app, "old-appcast.xml", "1.0.0.4"))
            Check((await newer.FixtureEngine.CheckForUpdatesQuietly()).Status != UpdateStatus.UpdateAvailable, "a signed older feed cannot downgrade the client");
        await RejectFeed("wrong-arch.xml");
        await RejectFeed("future-os.xml");
        server.TamperFeed = true;
        await RejectFeed("appcast.xml");
        server.TamperFeed = false;
        var current = UpdateRelease.Current();
        current.ValidateInstallTarget(Environment.ProcessPath);
        Check(true, "installed fixture matches only its per-user Inno AppId and custom installation target");
        var moved = Path.Combine(folder, "moved-installed-copy");
        Directory.CreateDirectory(moved);
        var movedExecutable = Path.Combine(moved, "Velinshot.exe");
        File.WriteAllText(movedExecutable, "A copied executable path must not qualify as the registered target.");
        File.WriteAllText(Path.Combine(moved, "unins000.exe"), "A copied uninstaller is not proof of installation.");
        try { current.ValidateInstallTarget(movedExecutable); throw new InvalidOperationException("A moved installation was accepted."); }
        catch (InvalidDataException) { checks.Add("PASS moved copy with an uninstaller cannot redirect an update away from the running EXE"); }
        foreach (var invalid in new[] {
            current with { PublicKey = "" }, current with { PublicKey = Convert.ToBase64String(new byte[32]) },
            current with { SourceClean = false }, current with { SourceCommit = "not-a-commit" }, current with { Runtime = "win-x86" },
            current with { FixtureBuild = false, Feed = new Uri("https://raw.githubusercontent.com/Jacknelson6/Velinshot/updates/windows/appcast.xml") }
        })
        {
            try { invalid.Validate(); throw new InvalidDataException("An invalid release configuration was accepted."); }
            catch (InvalidDataException error) when (error.Message != "An invalid release configuration was accepted.") { checks.Add("PASS fail-closed release configuration"); }
        }
        var item = info.Updates[0];
        var installer = Path.Combine(folder, new Uri(item.DownloadLink!).Segments.Last());
        var editor = app.Present(DemoFixture.Make(), DemoFixture.State(), "Updater safety fixture");
        editor.Left = -10000; editor.Top = -10000;
        await engine.InstallUpdate(item, installer);
        Check(engine.InstallerProcess is null && !app.UpdateRestarting && app.Windows.OfType<EditorWindow>().Contains(editor) && editor.State.Annotations.Count > 0,
            "late open editor cancels actual PreparingToExit without closing its unsaved document");
        editor.Close();
        foreach (var state in new[] { (Capture: true, Imports: 0), (Capture: false, Imports: 1) })
        {
            app.SetUpdaterBusyFixture(state.Capture, state.Imports);
            await engine.InstallUpdate(item, installer);
            Check(engine.InstallerProcess is null && !app.UpdateRestarting, "actual PreparingToExit cancels active capture or import");
        }
        app.SetUpdaterBusyFixture(false, 0);
        ComponentDispatcher.PushModal();
        try
        {
            await engine.InstallUpdate(item, installer);
            Check(engine.InstallerProcess is null && !app.UpdateRestarting, "actual PreparingToExit cancels an active native modal state");
        }
        finally { ComponentDispatcher.PopModal(); }
        var canceledLate = false;
        bool LateFailure(InstallUpdateFailureReason reason, string? path)
        { canceledLate = reason == InstallUpdateFailureReason.CanceledByUserViaEvent; return false; }
        void BecomeBusyAfterAdmission(object? sender, CancelEventArgs args) => app.SetUpdaterBusyFixture(true, 0);
        engine.InstallUpdateFailed += LateFailure;
        engine.PreparingToExit += BecomeBusyAfterAdmission;
        try
        {
            // The production PreparingToExit handler runs first and admits idle state. This subscriber
            // then introduces a capture, forcing the second production admission callback to cancel.
            await engine.InstallUpdate(item, installer);
            var neverStarted = false;
            try { _ = engine.InstallerProcess?.Id; }
            catch (InvalidOperationException) { neverStarted = true; }
            Check(canceledLate && neverStarted && !app.UpdateRestarting,
                "actual installer-start callback cancels a capture introduced after PreparingToExit admitted idle state");
        }
        finally
        {
            engine.InstallUpdateFailed -= LateFailure;
            engine.PreparingToExit -= BecomeBusyAfterAdmission;
            app.SetUpdaterBusyFixture(false, 0);
        }
        var installerBeforeTamper = engine.InstallerProcess;
        var damaged = Path.Combine(folder, "tampered-installer.exe");
        File.Copy(installer, damaged, overwrite: true);
        using (var file = new FileStream(damaged, FileMode.Open, FileAccess.ReadWrite)) { file.Position = file.Length - 1; var value = file.ReadByte(); file.Position--; file.WriteByte((byte)(value ^ 1)); }
        await engine.InstallUpdate(item, damaged);
        Check(ReferenceEquals(engine.InstallerProcess, installerBeforeTamper) && !app.UpdateRestarting, "actual NetSparkle installer path refuses a tampered archive");
        app.Settings.Filename = "updater-fixture-preserved";
        var history = Path.Combine(AppSettings.SupportDirectory, "History"); Directory.CreateDirectory(history);
        File.WriteAllText(Path.Combine(history, "preserved-fixture.txt"), "Updater must preserve AppData.");
        File.WriteAllLines(Path.Combine(folder, "update-check.txt"), checks.Append($"{checks.Count} updater checks passed."));
    }

    private sealed class FixtureServer : IDisposable
    {
        private readonly HttpListener listener = new();
        private readonly CancellationTokenSource deadline = new(TimeSpan.FromMinutes(3));
        private readonly string folder;
        private int disposed;
        internal bool TamperFeed { get; set; }
        internal int FeedRequests { get; private set; }
        internal TaskCompletionSource<bool>? FeedRequested { get; set; }
        internal FixtureServer(string folder)
        {
            this.folder = folder;
            listener.Prefixes.Add("http://127.0.0.1:18763/"); listener.Start();
            _ = Serve();
        }
        private async Task Serve()
        {
            try
            {
                while (!deadline.IsCancellationRequested)
                {
                    var context = await listener.GetContextAsync().WaitAsync(deadline.Token);
                    var filename = Path.GetFileName(context.Request.Url!.AbsolutePath);
                    if (filename == "appcast.xml") { FeedRequests++; FeedRequested?.TrySetResult(true); }
                    var path = Path.Combine(folder, filename);
                    if (!File.Exists(path)) { context.Response.StatusCode = 404; context.Response.Close(); continue; }
                    var data = await File.ReadAllBytesAsync(path, deadline.Token);
                    if (TamperFeed && filename == "appcast.xml") data[0] ^= 1;
                    context.Response.ContentLength64 = data.Length;
                    await context.Response.OutputStream.WriteAsync(data, deadline.Token);
                    context.Response.Close();
                }
            }
            catch (Exception) when (deadline.IsCancellationRequested || disposed != 0) { }
            finally { Dispose(); }
        }
        public void Dispose()
        {
            if (Interlocked.Exchange(ref disposed, 1) != 0) return;
            deadline.Cancel(); listener.Close();
        }
    }
}
#endif
