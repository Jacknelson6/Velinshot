<div align="center">
  <p><img src="Resources/AppIcon.png" alt="Velin logo" width="96" height="96"></p>
  <h1>Velinshot</h1>
  <p>Free, native screenshot editing for macOS.</p>
  <p>
    <a href="https://github.com/Jacknelson6/Velinshot/actions/workflows/ci.yml"><img alt="Native build and tests" src="https://github.com/Jacknelson6/Velinshot/actions/workflows/ci.yml/badge.svg?branch=main"></a>
    <img alt="macOS 14 or later" src="https://img.shields.io/badge/macOS-14%2B-191A25?style=flat-square">
    <a href="LICENSE"><img alt="MIT license" src="https://img.shields.io/badge/license-MIT-191A25?style=flat-square"></a>
  </p>
  <p><a href="https://github.com/Jacknelson6/Velinshot/releases/tag/v1.0.0-preview.2"><strong>Download preview</strong></a> · <a href="#build-from-source">Build from source</a> · <a href="docs/USAGE.md">User guide</a></p>
</div>

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/images/editor-dark.png">
  <img src="docs/images/editor.png" alt="The native Velinshot editor framing and annotating a synthetic screenshot">
</picture>

<sub>Real AppKit views rendered with a synthetic screenshot.</sub>

**⌘4 → capture → edit → C to copy or S to save.**

Capture opens a compact editor. Draw an arrow, adjust the frame, then copy the result or choose where to save it. Shortcuts are configurable. The editor keeps common tools in a larger rail and puts extra tools and advanced frame options within reach when needed.

- **Capture:** area, window and display, with overlays on every connected monitor and a deliberate click to choose a full display. Also import files, clipboard images and image drops.
- **Annotate:** arrows, boxes, pen, text, numbered steps, highlight and manual redaction. Draw across the entire canvas, including the mat outside your screenshot.
- **Frame:** automatic inset color, padding, rounded corners, shadows, backgrounds, exact sizes and saved presets.
- **Export:** PNG or JPEG, one-key copy/save, drag export and the native Share picker.
- **Keep working:** local OCR, undo/redo, reopen the last screenshot and optional editable history.

## Download and open

[Download the Apple Silicon disk image](https://github.com/Jacknelson6/Velinshot/releases/download/v1.0.0-preview.2/Velinshot-preview-arm64.dmg) or [ZIP archive](https://github.com/Jacknelson6/Velinshot/releases/download/v1.0.0-preview.2/Velinshot-preview-arm64.zip). Requires **macOS 14 or later**.

Quit any running copy first. Open the disk image and drag **Velinshot.app** onto **Applications**, then open `/Applications/Velinshot.app`. For the ZIP, unzip and move the app into Applications. Keep that installed copy in one location before granting capture access.

The preview is ad-hoc signed and **not notarized** by Apple. If macOS says it could not verify Velinshot:

1. Click **Done** in the blocked-opening alert.
2. Go to **System Settings → Privacy & Security** and scroll to **Security**.
3. Click **Open Anyway** beside Velinshot, then confirm the opening prompt. Authenticate if macOS asks.

See [Apple's first-launch instructions](https://support.apple.com/en-us/102445).

Moving the app into Applications keeps its location consistent. Removing this first-launch approval for public downloads requires Developer ID signing and Apple notarization, which this preview does not have. The [contributor release guide](CONTRIBUTING.md#signing-and-notarization) describes that path.

For capture, enable **Velinshot** under **Privacy & Security → Screen & System Audio Recording**, then relaunch if requested. The [user guide](docs/USAGE.md#capture-access) explains permission and shortcut troubleshooting.

**Preview status:** multi-display capture and the simplified editor have dedicated native regression checks. Physical two-monitor capture and some cross-app delivery checks remain open. [Validation and known limits](docs/QA.md).

## Small and local

Built with Swift, AppKit and system frameworks. No external package dependencies or embedded browser. Image preparation runs on a serial worker, and editing reuses a reduced display proxy while exports retain the original pixels. [Measured performance](docs/PERFORMANCE.md).

No account, subscription, analytics or required watermark. Screenshots stay on your Mac unless you share them. History is off by default. **Check for Updates** opens the public GitHub releases page in your browser, including preview releases. Automatic PII detection is excluded; manual blur and redaction are available.

## Windows

A Windows 10 and 11 edition lives in [`windows/`](windows/README.md): the same capture, edit and copy workflow, built natively with C#, .NET 10 and WPF. Presets and history use the same file formats as the macOS app.

## Build from source

Requires macOS 14 or later and Apple's Swift toolchain. The [package manifest](Package.swift) declares Swift 5.9 tools or later.

```sh
git clone https://github.com/Jacknelson6/Velinshot.git
cd Velinshot
bash scripts/build-app.sh
bash scripts/install-app.sh
open /Applications/Velinshot.app
```

The build creates a locally ad-hoc signed app. The installer verifies the bundle, refuses to replace a running app and preserves an existing installation in a hidden backup folder beside Applications. It also accepts a separate destination such as `~/Applications/Velinshot.app`. Run checks with `bash scripts/check.sh`. Full Xcode runs XCTest; Command Line Tools use the documented native assertion fallback. [Contributing](CONTRIBUTING.md).

## Documentation

| Use the app | Work on the app |
|---|---|
| [User guide and shortcuts](docs/USAGE.md) | [Contributing](CONTRIBUTING.md) |
| [Feature reference](docs/FEATURES.md) | [Product scope](PRODUCT.md) |
| [Preview validation](docs/QA.md) | [Interface design](DESIGN.md) |
| [Report a bug](https://github.com/Jacknelson6/Velinshot/issues/new/choose) | [Performance evidence](docs/PERFORMANCE.md) |

[MIT licensed](LICENSE).
