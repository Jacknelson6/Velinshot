<div align="center">
  <p><img src="../Resources/AppIcon.png" alt="Velin logo" width="96" height="96"></p>
  <h1>Velinshot for Windows</h1>
  <p>Free, native screenshot editing for Windows 10 and 11.</p>
  <p><a href="#build-from-source"><strong>Build from source</strong></a> · <a href="docs/USAGE.md">User guide</a> · <a href="docs/QA.md">Validation</a></p>
</div>

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/images/editor-dark.png">
  <img src="docs/images/editor.png" alt="The Velinshot editor framing and annotating a synthetic screenshot">
</picture>

<sub>The real WPF editor window, rendered with a synthetic screenshot.</sub>

**Ctrl+Shift+4 → capture → edit → C to copy or S to save.**

This is the Windows edition of Velinshot, alongside the [native macOS app](../README.md) in this repository. It keeps the same workflow, editor layout, frame engine and saved-file formats, rebuilt on Windows technologies: C#, .NET 10 and WPF with the Windows 11 Fluent theme.

- **Capture:** area, window and display, across every connected monitor, from a frozen snapshot so you get exactly what was on screen. Also open files, clipboard images and image drops.
- **Annotate:** arrows, boxes, pen, line, ellipse, text, numbered steps, highlight, blur and manual redaction, anywhere on the canvas including the mat outside the screenshot.
- **Frame:** automatic inset color, padding, rounded corners, shadows, gradient/solid/image/transparent backgrounds, desktop wallpaper, ratios, social sizes, exact output sizes and saved presets.
- **Export:** PNG or JPEG, one-key copy (keeps transparency for apps that read PNG), Save As, drag into any app or folder, and the Windows Share sheet.
- **Keep working:** local OCR with the Windows OCR engine, undo/redo, reopen the last closed screenshot, optional editable history.

No account, subscription, analytics, uploads or watermark. Screenshots stay on your PC unless you share them. History is off by default.

<img src="docs/images/capture-overlay.png" alt="The capture overlay selecting an area of a synthetic screen" width="640">

## Run it

Download or build `Velinshot.exe` (see below) and run it. There is no installer: the standalone exe needs nothing else installed. Velinshot lives in the notification area so its shortcuts keep working after you close its windows; quit from that icon's menu.

The preview exe is **not code-signed**, so Windows SmartScreen may say it "protected your PC". Choose **More info → Run anyway** for a build you produced or trust. Removing that prompt for public downloads needs an Authenticode code-signing certificate.

Windows needs no screen-recording permission. Content an app protects from capture (some video players, DRM) appears black, as in every Windows screenshot tool.

## Build from source

Requires Windows 10 version 2004 or later and the [.NET 10 SDK](https://dotnet.microsoft.com/download/dotnet/10.0). No other packages are used.

```powershell
git clone https://github.com/Jacknelson6/Velinshot.git
cd Velinshot\windows
powershell -ExecutionPolicy Bypass -File scripts/check.ps1      # build + every automated check
powershell -ExecutionPolicy Bypass -File scripts/package.ps1    # dist\Velinshot-<version>-win-x64.zip
```

`package.ps1` options: `-Runtime win-arm64` for Windows on Arm; `-FrameworkDependent` for a 25 MB exe that needs the .NET 10 Desktop Runtime. For day-to-day work, `dotnet run --project src/Velinshot` starts the app.

## How it maps to the Mac app

| macOS (Swift) | Windows (C#) |
|---|---|
| AppKit editor, `CanvasView`, inspector | WPF `EditorWindow`, `CanvasView`, same 60/64/250/64 layout |
| Core Graphics + Core Image renderer | `CanvasRenderer`: WPF media + Windows Imaging Component, with pixel passes for shadow, blur and multiply highlight |
| ScreenCaptureKit overlays per display | Frozen virtual-screen snapshot (GDI) with one overlay per display, physical pixels, per-monitor DPI v2 |
| Carbon global hot keys | `RegisterHotKey` |
| Vision OCR | `Windows.Media.Ocr` |
| `NSSharingServicePicker` | Windows Share sheet (`DataTransferManager`) |
| Menu-bar item and Dock | Notification-area icon and menu |
| `UserDefaults`, Application Support | `%APPDATA%\Velinshot\settings.json`, `%APPDATA%\Velinshot` |
| SMAppService launch at login | Per-user `Run` registry value |

Presets (`presets.json`), edit states and history metadata use the same JSON shapes as the macOS app, so they can move between the two.

Default shortcuts differ because ⌘4 has no safe Windows equivalent: Ctrl+4 would steal browser tab switching system-wide. Capture is **Ctrl+Shift+4**, capture-and-copy **Ctrl+Shift+5**, both configurable.

## Project layout

| Path | Contents |
|---|---|
| `src/Velinshot.Core` | The image engine: models, layout, renderer, auto balance and color, image I/O, history and presets, OCR |
| `src/Velinshot` | The app: editor, canvas, capture overlay, tray, hotkeys, settings, history, export |
| `tests/Velinshot.Checks` | Dependency-free engine checks (pixels, layout, JSON compatibility, storage, OCR, timings) |
| `scripts/` | `check.ps1`, `package.ps1`, `make-icon.ps1` (all run from this `windows` folder) |

The app also has developer modes used by `check.ps1`: `--interaction-check <folder>` drives the editor and capture selection off-screen, `--self-check <folder>` exercises the live platform (screen snapshot, hotkeys, OCR, share interop), and `--render-docs <folder>` renders every window in light and dark mode.

[MIT licensed](../LICENSE), like the macOS app.
