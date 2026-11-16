# Validation and known limits

This is a prerelease. Automated checks, native editing, live capture and cross-app delivery are recorded separately.

## Current preview

The [published preview](https://github.com/Jacknelson6/Velinshot/releases/tag/v1.0.0-preview.1) is an Apple Silicon app of about 2.2 MB. Its executable was built from `9751d62`; release source `73ead73` adds a CI runner correction with identical native build inputs. The public archive was downloaded, re-extracted and matched against the installed executable and signature. [Build metadata](https://github.com/Jacknelson6/Velinshot/releases/download/v1.0.0-preview.1/BUILD-INFO.json) and [archive checksums](https://github.com/Jacknelson6/Velinshot/releases/download/v1.0.0-preview.1/SHA256SUMS.txt) accompany the release.

The preview is ad-hoc signed without Developer ID or notarization. Normal macOS first-launch approval was completed and the unchanged app opened successfully. Screen Recording consent is separate and belongs to the installed app's signature. See [installation](../README.md#download-and-open) and [capture access](USAGE.md#capture-access).

## Automated checks

| Environment | Result |
|---|---|
| Full Xcode, Intel macOS 15 | [115 XCTest cases](https://github.com/Jacknelson6/Velinshot/actions/runs/43937679951), release compilation and bundle validation passed |
| Local Apple Silicon, Command Line Tools | 115 core scenario bodies, 10 assertion-failure probes and 152 native integration checks passed |
| Release package | Bundle, strict signature, linkage and downloaded archive checks passed |

The Command Line Tools fallback executes the scenario bodies through an explicitly named native assertion harness. Unsupported constructs fail. It is not an XCTest result. All 90 earlier core cases remain, with 17 palette and eight full-canvas markup cases added.

Coverage includes image dimensions, all eight EXIF orientations, ICC/alpha fidelity, frozen input after file replacement, source-coordinate crops, original-pixel exports, undo/redo, persistence, cancellation, error paths and input limits. Exact balance is compared with a brute-force oracle on 886 fixtures. [Core test notes](../Tests/VelinshotCoreTests/README.md) describe the bounded preview-only antialiasing tolerance; full exports remain strict.

Native checks use synthetic images, isolated preferences, a private pasteboard and hidden AppKit views. They exercise drawing, text editing, selection, resizing, promised PNG writing, decoding, OCR, hotkey registration/conflict retry and asynchronous worker behavior. Unit promise writing does not prove receipt by Finder.

## Observed native behavior

The installed preview passed file import, automatic inset color, a pointer-drawn arrow extending onto the mat, JPEG export with pixel verification, S/save, C/copy-close, clipboard reopening and real display capture. Area selection overlay and Escape cancellation also passed.

Earlier native GUI exercises cover text editing, PNG export, presets, save cancellation, original-image copy, reopen-last-closed, image drops and opening/canceling the Share picker. These are specific observed actions, rather than a claim that every destination or device combination has passed.

Automatic inset checks cover crop changes, manual overrides, saved-style compatibility, interrupted gestures and stale results. Full-canvas checks cover mat-only/crossing marks, movement, resizing, text, hidden-mark recovery, undo/redo and preview/export agreement.

Light/dark, default/minimum-size and export renders received independent visual review. [Image provenance](images/editor-provenance.json) records the native layouts. Two development crash reports led to file-promise initialization and validation scheduling corrections. Subsequent observed launches, including the approved first launch, produced no new report.

## Remaining manual checks

- Physical area/window capture gestures and global-hotkey delivery.
- Finder receiving a promised file and the selected Share destination receiving the result.
- Capture across multiple displays.
- A real logout/login cycle with launch at login enabled.

The controls exist, but these final flows are not live passes. The package is Apple Silicon; hosted Intel tests validate the source, not an Intel release download. Developer ID signing and notarization are still absent.

Run local checks with `bash scripts/check.sh`. Use synthetic fixtures for GUI validation. [Performance measurements](PERFORMANCE.md) have their own source, device and timing limits.
