# User guide

## Install and open

The Mac preview requires **Apple Silicon and macOS 14 or later**. [Download it here](../README.md#download-and-open).

Save open screenshots and quit any running copy of Velinshot first. Open the disk image and drag **Velinshot.app** onto **Applications**, then open `/Applications/Velinshot.app`. For the ZIP archive, unzip it and move the app into Applications. Keep that installed copy in one location before granting capture access.

The preview is ad-hoc signed and **not notarized** by Apple. If macOS says it could not verify Velinshot:

1. Click **Done** in the blocked-opening alert.
2. Go to **System Settings → Privacy & Security** and scroll to **Security**.
3. Click **Open Anyway** beside Velinshot, then confirm the opening prompt. Authenticate if macOS asks.

See [Apple's first-launch instructions](https://support.apple.com/en-us/102445).

Moving the app into Applications keeps its location consistent. Removing this first-launch approval for public downloads requires Developer ID signing and Apple notarization, which this preview does not have. The [contributor release guide](../CONTRIBUTING.md#signing-and-notarization) describes that path.

For capture, enable **Velinshot** under **Privacy & Security → Screen & System Audio Recording**, then relaunch if requested. See [capture access](#capture-access) for permission and shortcut troubleshooting.

## Capture and import

Press **⌘4** to capture and edit. Each connected display gets an overlay. Move the pointer to the display you want, then drag an area; the first click starts selection even on a different monitor. You can drag across display boundaries. **Space** switches to window selection. **Escape** cancels. Set a different global shortcut in Settings if needed.

**Capture Display** in the File or menu-bar menu waits for you to click the display to capture, rather than choosing one immediately from the pointer's starting location. A visible outline identifies the current target. Changing the connected displays during capture cancels the selection so you can start again.

Open an existing image through the File menu or the editor's **More** menu, paste an image from the clipboard, or drop an image into the editor. The editor opens after capture or import.

## Frame and annotate

Use **Frame**, **Backdrop** and **Output** to adjust geometry, backgrounds and export size. Outer padding and inner inset are separate. Inset fill follows the visible image's dominant edge color by default. Choosing a color turns Auto off; use Auto to restore matching. Older saved presets and history retain their recorded colors.

The larger tool rail keeps **Select**, **Arrow**, **Rectangle**, **Text**, **Highlight**, **Redact** and **Crop** visible. **More tools** contains Draw, Line, Ellipse, Number and Blur. A secondary tool stays indicated on that button while selected; every tool also keeps its letter shortcut.

Frame shows Padding, Corners, Shadow and Auto balance first. Expand **Advanced frame** for Inset, Inset fill and Border. Reset crop remains visible. The header's **More** menu contains Fit to Preview, Copy Image Text, Share Screenshot, import, history and Settings actions. Copy and Save stay visible at the bottom.

| Backdrop | Output |
|---|---|
| ![Backdrop controls](images/editor-backdrop.png) | ![Output controls](images/editor-output.png) |

Draw anywhere in the framed canvas, including the mat around the screenshot. Crop and blur stay within the image. Shift constrains boxes to squares, ellipses to circles, and arrows/lines to 45-degree directions. Use Select to move, resize or recolor marks. Double-click text to edit it. Tab cycles through marks, including marks hidden after a canvas resize.

Double-click empty background in Select to copy and close. Text editing owns letter shortcuts while you type. The outer canvas is the export boundary.

## Copy, save and share

**C** copies the finished image and closes the editor when that preference is enabled. **S** opens the native save picker so you can choose the destination, PNG/JPEG format and JPEG quality. The File menu also offers the original, unframed image.

Drag export advertises a promised PNG file and PNG pasteboard data. **More → Share Screenshot** opens the native macOS destination picker. Final Finder receipt and Share destination delivery remain [manual preview checks](QA.md#remaining-manual-checks).

## Shortcuts

| Key | Action |
|---|---|
| ⌘4 | Capture and edit, configurable |
| ⌃⌥⌘5 | Capture and copy, configurable |
| C / ⌘C | Copy; optionally close |
| S / ⌘S | Choose where to save |
| ⌘Z / ⇧⌘Z | Undo / redo |
| D · A · R · E | Draw · Arrow · Rectangle · Ellipse |
| T · H · B · K | Text · Highlight · Blur · Redact |
| N · X · L · V | Number · Crop · Line · Select |
| Delete | Remove selected mark |
| Tab / Shift-Tab in Select | Cycle through marks |
| Escape | Cancel capture or release canvas focus |
| ⌘0 · ⌘+ · ⌘− | Fit · Zoom in · Zoom out |
| ⌘1 · ⌘2 · ⌘3 | Frame · Backdrop · Output |
| ⇧⌘T | Reopen the last closed screenshot |

## Capture access

Install into **Applications** and open that copy before allowing Velinshot in **System Settings → Privacy & Security → Screen & System Audio Recording**. Settings has a shortcut to that pane. Relaunch if macOS asks. First-launch Gatekeeper approval is a [separate step](#install-and-open).

If access appears enabled but capture fails after replacing a locally built app, the permission may belong to an older signature. Use **Show This App in Finder** in Settings to identify the current copy, then refresh that app's Screen Recording entry. A rebuilt ad-hoc app can require consent again.

If a shortcut is unavailable, use **Retry shortcuts** or record another combination. Availability comes from macOS registration, rather than whether another screenshot app is running.

## Local files and limits

History is off by default. When enabled, it keeps at most **50 entries or 250 MB** in Application Support, or a dedicated `Velinshot History` subfolder at your chosen location. Presets and imported background assets are stored locally. The most recently closed screenshot stays in memory until replaced or the app quits.

Image input is limited to **40 megapixels**, **16,384 pixels per side** and **250 MB encoded input**. Fixed-size exports fit the source uniformly and fill extra space with the selected background. Watermark text can be rejected if the chosen output is too small; clear it or use a larger canvas. Dynamic or inaccessible wallpapers fall back to the current gradient.

## Build from source

Mac builds require macOS 14 or later and Apple's Swift toolchain. The [package manifest](../Package.swift) declares Swift 5.9 tools or later.

```sh
git clone https://github.com/Jacknelson6/Velinshot.git
cd Velinshot
bash scripts/build-app.sh
bash scripts/install-app.sh
open /Applications/Velinshot.app
```

The build creates a locally ad-hoc signed app. The installer verifies the bundle, refuses to replace a running app and preserves the previous installation. It also supports a destination such as `~/Applications/Velinshot.app`. See [Contributing](../CONTRIBUTING.md) for checks, packaging, backups and signing. Full Xcode runs XCTest; Command Line Tools use the documented native assertion fallback.

For Windows SDK requirements and build commands, see [Windows builds](../windows/README.md#build-from-source).
