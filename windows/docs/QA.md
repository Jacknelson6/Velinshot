# Validation

## Windows updater change

The updater adds pinned NetSparkle 3.1.0 with strict Ed25519 checks for both the feed and installer, one opt-in preference in the existing settings file, standard per-user Inno Setup packaging, and clean-source build metadata. Missing production keys, public fixture keys, dirty source, unexpected architecture, unsupported Windows builds and fixture-enabled releases fail closed.

Local verification of this change is cross-target compilation on macOS with the official .NET 10.0.404 SDK. This does not execute WPF or establish that installation/relaunch works on Windows. The earlier native Windows measurements below remain the earlier baseline.

The Windows workflow prepares separate build3/build4 fixture installers, then a macOS job imports public RFC8032 test material into a disposable CI-only Keychain and signs with checksum-pinned official Sparkle 2.10.1 tools. A Windows job uses the production updater controller to verify interoperability, signed-feed rejection, architecture/OS rejection, actual cancellable busy-state callbacks, tampered-installer refusal and the standard install/relaunch path. Fixture keys, loopback feeds, isolated AppData and commands are compiled out of production. No production signing key is exported or placed in CI.

Those new runtime checks are **prepared, not recorded passes** until the exact source's Windows CI jobs run successfully. Real Windows acceptance still includes the update notification UI, manual choice to download/install, non-admin install behavior, restart after active-document deferral, and persistence in the final released package. Public binaries and feed bytes must be read back after release before they are called delivered.

The planned [preview 3 validation receipt](https://github.com/Jacknelson6/Velinshot/releases/download/v1.0.0-preview.3/VALIDATION.json) will record the exact candidate source, CI runs and downloaded artifact hashes after those checks complete. This source document does not predeclare their result.

The new installer uses the app's named mutex and `CloseApplications=no` / `RestartApplications=no`. It refuses a running app. In-app update admission blocks editors, capture, imports and modal state; the final installer and shutdown callbacks recheck the current state. A single-file executable is located with `Environment.ProcessPath`, never `Assembly.Location`. Admission also requires its folder to match its own per-user Inno AppId's `InstallLocation`, including valid custom targets; a copied uninstaller does not qualify a moved copy.

The prepared Windows fixtures exercise the actual scheduler with immediate opt-in and opt-out changes, require no requests while opted out, and introduce busy state after `PreparingToExit` has admitted idle state to exercise the second cancellable installer callback. They check moved-copy refusal using the separate fixture AppId, custom installation folder and isolated data directory. Packaging checks that the ZIP contains the notices manifest, and the installed fixture verifies each official notice against that manifest. Native notification UI and busy state introduced while interacting with a real download dialog remain Windows acceptance checks.

Windows panel clipping and shadow distance geometry remain circular in this updater change. The macOS continuous-corner change is separate; cross-platform continuous-corner parity is not claimed.

## Earlier Windows baseline

Recorded 2026-11-17 on Windows 11 Pro (build 26300), two 1920×1080 displays stacked vertically, .NET SDK 10.0.404. All content is synthetic.

## Automated (`scripts/check.ps1`)

| Group | Result | Scope |
|---|---|---|
| Engine checks | 29/29 pass | Layout math, pixel-exact plain render, solid/inset/rounded frame, gradient coverage, shadow never darkens transparent pixels, zero-padding shadow clip, shadow scale parity at 2× and 4×, opaque redaction, multiply highlighter, blur confined to its rectangle, markup on the mat, shapes/text/numbers, watermark placement and rejection, proxy preview vs export geometry, PNG/JPEG round trips, size limits, macOS JSON compatibility, content bounds, inset color, matched colors, history save/load/update/clear/limits/path escape, preset validation, Windows OCR |
| Interaction check | 21/21 pass | The real editor, off-screen: draw arrow, Shift 45° snap, undo/redo, select, move, corner resize, Delete, crop and undo, text entry, numbering, padding slider and undo, letter shortcuts and Escape, export size; capture selection for area, plain click, Space→window, display mode and snapshot crop |
| Platform self-check | 7/7 pass (clipboard self-skipped) | Live virtual-screen snapshot of both displays (249 ms), monitor and window enumeration, Ctrl+Shift+4/5 registration, export encode/decode, OCR, Share interop available, history round trip. The clipboard check skips itself when the clipboard holds non-text data, so it never destroys user content; it ran as "skipped" here |
| Rendered windows | Reviewed | Editor (Frame, Backdrop, Output, Blur markup), minimum size with markup, welcome and settings, light and dark; capture overlay in area mode |

Measured (Release, this PC): demo preview 1400 px 57 ms without shadow, ~96 ms with shadow, ~31 ms per frame while dragging markup (cached frame); 1424×944 export ~80 ms; 2848×1888 export ~330 ms. Idle in the notification area: ~44 MB private memory (standalone and framework-dependent builds).

## Manual checks still open

These need a person at the PC; they were not exercised by the automated runs:

- Pressing the global shortcuts from another app, and the overlay taking focus over full-screen and elevated (administrator) windows. A non-elevated Velinshot cannot receive input over elevated windows.
- A real mouse drag across the two displays, and mixed-DPI setups (for example 100% + 150%). The selection math is per-monitor physical pixels and is unit-checked; the DPI change path of overlay windows is not yet observed on mixed-scale hardware.
- Clipboard paste of a copied image into Paint, Word, Teams/Slack and a browser, including transparency.
- Drag export into File Explorer, Outlook and chat apps; the Share sheet delivering to a target app.
- Color popup, More menus, Save dialog and Settings shortcut recorder by hand; keyboard-only navigation and Narrator labels.
- Windows 10 2004+ (only Windows 11 was available) and Windows on Arm (`-Runtime win-arm64` builds but was not run).
- Launch at sign-in (writes a per-user `Run` value; not toggled during testing).

## Known differences from the macOS preview

- Default shortcuts are Ctrl+Shift+4 / Ctrl+Shift+5 instead of ⌘4 / ⌃⌥⌘5.
- JPEG quality is a Settings slider rather than a control inside the Save dialog.
- Window capture crops the frozen screen, so overlapping windows in front of the chosen window are included, as in a normal screenshot.
- The clipboard bitmap (CF_DIB) has no alpha; transparency travels in the PNG clipboard format.
- The shadow falls downward. Core Graphics shadow offsets are in base space (y up), so the macOS renderer's +28% vertical offset may lift its shadow; compare the two outputs before treating either as the reference.
- The earlier baseline opened the GitHub releases page for updates. The updater change above replaces that path for authenticated installed releases; portable and unconfigured development builds explain their limitation.
