# User guide

## Install and update

Use the Windows Setup download to install under `%LOCALAPPDATA%\Programs\Velinshot`. It includes its .NET runtime and needs no administrator request. Quit Velinshot from the notification area before manually replacing an installation. Setup refuses a running copy and does not force-close screenshots.

Choose **Check for Updates…** from the notification-area menu or the editor's More menu. The installed app authenticates both the feed and installer. Save or copy your screenshots and close their editor windows before choosing installation. Active capture, imports and dialogs defer the handoff; installation and relaunch happen only after your confirmation.

Enable **Settings → Check for updates automatically** if you want daily availability notifications. It is off by default. This permission covers checking and notifying, not downloading or restarting without your choice.

Your `%APPDATA%\Velinshot` settings, presets, backgrounds and optional history remain separate from the app. Updating or uninstalling does not remove them. Portable copies are not replaced in place. Install with Setup to use in-app updates.

The preview has no Authenticode certificate. Update signatures authenticate downloaded updates but do not remove Windows SmartScreen first-launch warnings.

## Capture and import

Press **Ctrl+Shift+4** to capture and edit. Velinshot freezes every connected display, then shows an overlay on each one. Drag an area; you can drag across display boundaries. **Space** switches to window selection (click a window). **Escape** or a right-click cancels. A plain click without a drag keeps the overlay open.

**Capture Display** (notification-area menu) waits for you to click the display to capture. An outline marks the display under the pointer. Changing the connected displays during capture cancels it so you can start again.

**Ctrl+Shift+5** captures and copies straight to the clipboard with your last frame style, without opening the editor.

Open an existing image with **More → Open Image…** (Ctrl+O), paste one with **Open from Clipboard** (Ctrl+V), drop an image file onto the editor, or open image files with Velinshot from File Explorer. The editor opens after capture or import.

## Frame and annotate

Use **Frame**, **Backdrop** and **Output** (Ctrl+1, Ctrl+2, Ctrl+3) to adjust geometry, backgrounds and export size. Outer padding and inner inset are separate. Inset fill follows the visible image's dominant edge color while **Auto** is on; choosing a color turns Auto off.

The tool rail keeps **Select**, **Arrow**, **Rectangle**, **Text**, **Highlight**, **Redact** and **Crop** visible. **More tools** holds Draw, Line, Ellipse, Number and Blur; the More button stays highlighted while one of them is active. Every tool keeps its letter shortcut.

Draw anywhere in the framed canvas, including the mat around the screenshot. Crop and blur stay within the image. **Shift** constrains boxes to squares, ellipses to circles, and arrows and lines to 45° steps. In Select, drag a mark to move it, drag a corner handle to resize it, double-click text to edit it, and use **Tab**/**Shift+Tab** to cycle marks. Colors, stroke and text size apply to the selected mark.

Double-click the empty background in Select to copy and close.

## Copy, save and share

**C** copies the finished image and closes the editor when that setting is on. The clipboard receives a bitmap (for apps such as Paint and Office) and PNG data (keeps transparency in apps that read PNG, such as browsers, Slack and Teams). **S** opens the Save dialog; choose PNG or JPEG there. JPEG quality is in Settings.

**More → Copy Original / Save Original…** export the unframed screenshot. **Drag** in the footer drags the finished PNG into any app or folder. **More → Share Screenshot…** opens the Windows Share sheet. **More → Copy Image Text…** runs local OCR and shows selectable text.

## Shortcuts

| Key | Action |
|---|---|
| Ctrl+Shift+4 | Capture and edit, configurable |
| Ctrl+Shift+5 | Capture and copy, configurable |
| C / Ctrl+C | Copy; optionally close |
| S / Ctrl+S | Save |
| Ctrl+Z / Ctrl+Y or Ctrl+Shift+Z | Undo / redo |
| D · A · R · E | Draw · Arrow · Rectangle · Ellipse |
| T · H · B · K | Text · Highlight · Blur · Redact |
| N · X · L · V | Number · Crop · Line · Select |
| Delete / Backspace | Remove the selected mark |
| Tab / Shift+Tab in Select | Cycle through marks |
| Escape | Cancel capture, cancel text, or return to Select |
| Ctrl+0 · Ctrl+= · Ctrl+- | Fit · Zoom in · Zoom out (Ctrl+wheel or pinch also zooms) |
| Ctrl+1 · Ctrl+2 · Ctrl+3 | Frame · Backdrop · Output |
| Ctrl+Shift+T | Reopen the last closed screenshot |
| Ctrl+W | Close the editor |

If a global shortcut is taken by another app, Settings shows the error: use **Retry shortcuts**, record another combination, or use Ctrl+Shift+2. Shortcuts need Ctrl, Alt or Win (Print Screen and function keys may be used alone; Windows 11 may reserve Print Screen for Snipping Tool).

## Local files and limits

Settings live in `%APPDATA%\Velinshot\settings.json`; presets in `presets.json` and imported background images in `Backgrounds` beside it. History is off by default. When enabled, it keeps at most **50 entries or 250 MB** in `%APPDATA%\Velinshot\History`, or a dedicated `Velinshot History` folder at a location you choose. The most recently closed screenshot stays in memory until replaced or the app quits. Drag and Share write temporary PNGs to `%TEMP%\Velinshot`, removed after a day.

Image input is limited to **40 megapixels**, **16,384 pixels per side** and **250 MB encoded**. Fixed-size exports fit the source uniformly and fill extra space with the background. A watermark can be rejected if the output is too small.
