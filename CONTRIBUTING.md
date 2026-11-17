# Contributing

Keep the capture-to-copy path short and the app native. Use system frameworks; add a dependency only when its benefit justifies its size and lifecycle. The app must remain useful without an account, subscription or required watermark.

## Build and check

```sh
bash scripts/build-app.sh
bash scripts/check.sh
```

Run heavy local builds serially. Full Xcode runs XCTest. Command Line Tools use the documented [native assertion fallback](scripts/checks/README.md); report it by that name. GUI capture and cross-app delivery need separate checks on a Mac.

## Install and package

After saving your work and quitting Velinshot:

```sh
bash scripts/install-app.sh build/Velinshot.app /Applications/Velinshot.app
open /Applications/Velinshot.app
```

The installer checks the source, staged and installed bundles, compares executable hashes, and preserves the previous app under `.Velinshot Backups` beside the destination. It refuses a running app, a different destination bundle identity and overlapping source/destination paths. An install failure restores the previous app. A custom destination supports a user Applications folder or a temporary validation folder.

Commit the release source, run `bash scripts/check.sh`, then package that clean revision:

```sh
bash scripts/package-release.sh
```

The package contains a ZIP and a disk image with an Applications shortcut, plus `BUILD-INFO.json` and `SHA256SUMS.txt`. Packaging rejects a dirty source tree or an app built from another revision. Metadata records the source SHA, executable hash, architecture and observed signature/notarization status. Publish as a preview until the remaining manual checks are closed.

## Signing and notarization

The default build is ad-hoc signed. Moving it into Applications does not make it notarized. Apple-trusted distribution requires an Apple Developer Program membership, a **Developer ID Application** certificate and its private key, and an existing `notarytool` keychain profile. Keep credentials outside the repository. See [Apple's Developer ID guide](https://developer.apple.com/developer-id/) and [notarization workflow](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution).

When those prerequisites are available:

```sh
VELINSHOT_SIGNING_IDENTITY='Developer ID Application: Your Name (TEAMID)' bash scripts/build-app.sh
bash scripts/notarize.sh build/Velinshot.app existing-keychain-profile
bash scripts/package-release.sh
```

An explicitly requested identity must exist; the build never silently falls back to ad-hoc signing. That mode enables hardened runtime and a secure timestamp. The notarization script requires Developer ID signing, waits at most 15 minutes for Apple's acceptance, staples the ticket and checks both the staple and Gatekeeper. Packaging derives notarization status from validation. Current preview downloads are still ad-hoc signed and not notarized.

Replacing an ad-hoc build can require Screen Recording consent again because its signature changed. Do not change TCC records or remove quarantine attributes to bypass macOS checks. **Check for Updates** uses the bundled Sparkle updater. [Update release instructions](docs/UPDATES.md#release-maintainers) cover the separate app-scoped Ed25519 key and signed feed. Do not export that private key to CI or another host.

## Changes

Use a small branch and describe the concrete trigger and resulting behavior. Include the relevant verification and name any manual check still pending. Documentation-only changes should check links, commands and factual claims.

Core coordinates use top-left original source pixels. `panelRect` contains inset plus source; `imageRect` is the source placement. Keep preview and export on the same renderer. Test meaningful pixels, dimensions, alpha, undo and error handling when behavior changes. Capture, clipboard, file writes and input limits need failure-path coverage.

Use synthetic screenshots in examples and issues. See [product scope](PRODUCT.md), [interface design](DESIGN.md) and [current validation](docs/QA.md). Automatic PII detection is outside the current scope.
