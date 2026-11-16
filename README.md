<div align="center">
  <h1>Velinshot</h1>
  <p><strong>A good screenshot. In a moment.</strong></p>
  <p>Capture, frame, mark it up. Copy and carry on.</p>
  <p>
    <a href="LICENSE"><img alt="MIT license" src="https://img.shields.io/badge/license-MIT-7160E8?style=flat-square"></a>
    <img alt="macOS 14 or later" src="https://img.shields.io/badge/macOS-14%2B-191A25?style=flat-square">
    <img alt="Swift and AppKit" src="https://img.shields.io/badge/built_with-Swift_%26_AppKit-F05138?style=flat-square">
    <a href="docs/QA.md"><img alt="Local checks: 115 core scenarios and 152 native checks" src="https://img.shields.io/badge/local_checks-115_core_%2B_152_native-7160E8?style=flat-square"></a>
  </p>
  <p><a href="Sources">Source</a> · <a href="#make-it-yours">Build the preview</a> · <a href="docs/FEATURES.md">Features</a></p>
</div>

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/images/editor-dark.png">
  <img src="docs/images/editor.png" alt="Velinshot framing and annotating a synthetic screenshot">
</picture>

<sub>Native UI rendered from the real app with a synthetic fixture.</sub>

**Preview build.** Capture has been confirmed on the owner's Mac. Local checks cover native editing, full-canvas markup, automatic inset color and PNG/JPEG saves. Mode-by-mode capture, Finder delivery and Share destination checks remain open. [Current validation](VALIDATION.md).

Free, native screenshot editing for macOS. No account, subscription, watermark requirement or browser runtime. Built from scratch with Swift and the frameworks already on your Mac.

## One short flow

**⌘4 → capture → edit → C to copy, or S to choose where to save.**

Drag an area, press Space to capture a window, or capture a whole display. The screenshot opens straight into a compact editor. Add an arrow, draw a box, soften the corners, give it some breathing room, and send it on its way.

| Capture | Mark it up | Make it look right | Get it out |
|---|---|---|---|
| Area, window, display | Pen, arrow, line | Separate padding and inner inset | One-key copy and save |
| File and clipboard import | Rectangle, ellipse | Rounded corners, shadows, borders | PNG and compressed JPEG |
| Drag an image into the editor | Text and numbered steps | Gradient, color, image, desktop wallpaper | Drag export, with Finder validation pending |
| Editable local history, opt-in | Highlight, blur, opaque redact | Exact pixel sizes and social canvases | Native Share picker |
| Reopen the last closed capture | Move, resize, recolor, undo | Saved presets and optional text watermark | Copy or save the original image |

Local OCR lets you select and copy the words in your image. Automatic PII detection is intentionally excluded. Manual redaction stays available.

| Backdrop | Output |
|---|---|
| ![Backdrop controls in the native editor](docs/images/editor-backdrop.png) | ![Output controls in the native editor](docs/images/editor-output.png) |

<sub>Real native views, shown with the same synthetic screenshot.</sub>

## Make it yours

Requires macOS 14 or later. The packaged build targets Apple Silicon; the source can be built on a compatible Mac with Apple's Swift toolchain.

```sh
git clone https://github.com/Jacknelson6/Velinshot.git
cd Velinshot
bash scripts/build-app.sh
open build/Velinshot.app
```

The build script makes an app bundle with a local ad-hoc signature. A Developer ID and Apple notarization are not included. Downloaded builds may require macOS's normal approval to open; building locally avoids depending on a distribution signing service.

On first capture, allow **Velinshot** in **System Settings → Privacy & Security → Screen & System Audio Recording**. The Settings window has a shortcut to that pane. macOS may require a relaunch, and a newly rebuilt ad-hoc app may need consent again.

**Shortcut already in use?** If macOS refuses the selected shortcut, record another one in Settings or try ⌘⇧2.

## Your hands can stay on the keyboard

| Key | Action |
|---|---|
| ⌘4 | Capture and edit, configurable |
| ⌃⌥⌘5 | Capture and copy, configurable |
| C / ⌘C | Copy finished image; optionally close |
| S / ⌘S | Native save picker |
| ⌘Z / ⇧⌘Z | Undo / redo |
| D · A · R · E | Draw · Arrow · Rectangle · Ellipse |
| T · H · B · K | Text · Highlight · Blur · Redact |
| N · X · L · V | Number · Crop · Line · Select |
| Delete | Remove a selected mark |
| Tab / Shift-Tab in Select | Cycle marks, including marks outside the canvas |
| ⌘0 · ⌘+ · ⌘− | Fit · Zoom in · Zoom out |
| ⌘1 · ⌘2 · ⌘3 | Frame · Backdrop · Output inspector |
| ⇧⌘T | Reopen the last closed screenshot |

Draw and place text anywhere in the framed canvas, including the mat around the screenshot. Crop and blur stay within the image. Shift constrains boxes to squares, ellipses to circles, and arrows/lines to 45-degree directions. In Select, double-click a text mark to edit it or empty background to copy and close. Tab cycles through marks; Escape or tabbing past the last mark releases canvas focus. Letter shortcuts yield while you are typing.

Inset fill follows the visible image's dominant edge color by default. The Auto control restores matching after a manual choice; choosing a fill color turns Auto off. Saved older history and presets retain their recorded colors.

## Small by design

The app uses **AppKit, Core Graphics, ScreenCaptureKit, ImageIO and Vision**. There are no Swift package dependencies, embedded Chromium, Electron, Tauri, Rust runtime or background web service. Shared layout and drawing code keep rounding, crops and annotations aligned. File decoding and exact balance analysis run on one serial worker. A cached display proxy makes editing cheaper; copies, saves, OCR and history use the retained original pixels.

Images are limited to 40 megapixels and 16,384 pixels per side. Previews render at a reduced raster size. Local history is off by default and capped at 50 entries or 250 MB when enabled. The most recently closed image is retained in memory until replaced or the app quits. There is no polling service or recurring idle render. See [performance notes](docs/PERFORMANCE.md) for measured scope and limits.

## Local work stays local

Capturing, rendering, OCR and history work on your Mac. No screenshot is uploaded, and there are no analytics or account requests. A manual **Check for Updates** command asks GitHub for public release metadata. Sharing happens only through the destination you choose in macOS's Share picker.

History and presets live in Application Support by default. A custom history location uses a dedicated `Velinshot History` subfolder. Custom backgrounds are copied into a managed local asset store so presets can reopen them.

## Built to be checked

```sh
bash scripts/check.sh
```

Full Xcode runs the XCTest suite. Command Line Tools installations without XCTest run the same scenario bodies through an explicitly named native assertion harness. Unsupported test constructs fail rather than being skipped. Local checks also exercise hidden native canvas gestures, preferences, promised PNG files, real image decoding and OCR.

Hosted CI runs XCTest, a release build and bundle validation. Screen Recording and real drag/Share flows require a Mac GUI and are reported separately. See [validation notes](docs/QA.md) for evidence and remaining permission-dependent checks.


Contributions are welcome. [Read the guide](CONTRIBUTING.md), keep the app small, and make the screenshot better.

[MIT licensed](LICENSE).
