# App updates

Choose **Velinshot > Check for Updates** to check, download and install a newer version inside the app. You choose when it restarts. Finish captures/imports, close screenshot editors and dismiss dialogs first. Updates do not silently close work, enable history or upload screenshots.

**Settings > Updates > Automatically check for updates** is off by default. Enabling it allows periodic native update notifications. It does not enable automatic installation. The setting belongs to Sparkle's preferences and survives app restarts. Checks use public GitHub HTTPS endpoints without system profiling, analytics parameters or screenshot data.

Preview 2 and older do not contain an updater. Install the first updater-enabled preview manually once. A source build with no configured public signing key keeps update checks disabled and explains that in Settings. Release packaging refuses that incomplete configuration.

Sparkle signatures authenticate the feed and downloaded archive before extraction. They are separate from Apple Developer ID signing/notarization. The current preview is still ad-hoc signed; first-download Gatekeeper approval and renewed Screen Recording consent after replacement can still apply.

## Release maintainers

The app uses official **Sparkle 2.10.1**, pinned in the package manifest/resolution. Its framework and required helpers are embedded with preserved symlinks and signed inside-out. The full third-party license is shipped under `Contents/Resources/ThirdPartyNotices`.

The canonical feed is `https://raw.githubusercontent.com/Jacknelson6/Velinshot/updates/appcast.xml`, on a dedicated branch in this repository. No Pages site or separate account is required. The app requires a signed feed, validates archive signatures before extraction, and never expires into an unsigned-feed fallback. Keep profiling and silent installation disabled. Do not use the stable-only `/releases/latest/download` route for preview updates.

One app-specific Ed25519 key stays in the release Mac's login Keychain: service `https://sparkle-project.org`, account `com.jacknelson.velinshot.ed25519`. Provisioning happens once under the release owner's authority, after checking for an existing app key. Reuse that key; never regenerate/rotate it casually, use the global `ed25519` account, export the private key, put it in CI/GitHub secrets, or commit it. Only its public `SUPublicEDKey` belongs in `Resources/Info.plist`. Keychain prompts that cannot be completed non-interactively are a concrete release blocker.

After a clean committed gate and final package:

```sh
python3 scripts/prepare-appcast.py build/release/Velinshot-preview-arm64.zip v1.0.0-preview.3
```

For later releases, pass the current downloaded feed with `--previous-feed` so existing entries remain. The script uses official Sparkle tools and the existing local Keychain item, rejects source/key/version mismatches, and prepares a versioned ZIP, signed `appcast.xml` and public `UPDATER-INFO.json` under `build/appcast`. It creates no keys and publishes nothing. Use a fresh output folder for each release.

Upload the versioned ZIP to the specified immutable release URL, download it again and verify its hash/signature. Only then publish the unchanged signed feed to the `updates` branch and fetch it publicly to verify its bytes/signature. Publishing the feed is the final visibility switch. Editing XML or release notes after signing invalidates authentication. Increment `CFBundleVersion` monotonically for every update. Keep release signing on this Mac rather than moving the private key to automation.

If the private key is lost before Developer ID recovery is available, distribute a new bootstrap app manually. Do not relax signature requirements to recover. [Official security and key rotation guidance](https://sparkle-project.org/documentation/#3-segue-for-security-concerns).

## Verification

The native gate covers update configuration and busy-work restart policy. A separate signed fixture must prove actual Sparkle download, replacement and relaunch into a private synthetic app, plus refusal of modified feeds/archives and preservation of busy work. Fixture keys and bundle IDs are test-only and never replace the production app or use its Keychain account. Follow [fixture instructions](../scripts/checks/README.md) and record what was actually observed in [QA](QA.md). A successful browser open, feed parse or unit check alone is not an updater pass.
