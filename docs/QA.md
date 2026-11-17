# Validation and known limits

This is a prerelease. Automated checks, native editing, live capture and cross-app delivery are recorded separately.

## Current preview

The [current preview](https://github.com/Jacknelson6/Velinshot/releases/tag/v1.0.0-preview.2) targets Apple Silicon and macOS 14 or later. [Build metadata](https://github.com/Jacknelson6/Velinshot/releases/download/v1.0.0-preview.2/BUILD-INFO.json) records its exact source revision, executable hash, architecture and signing status. [Archive checksums](https://github.com/Jacknelson6/Velinshot/releases/download/v1.0.0-preview.2/SHA256SUMS.txt) cover the ZIP, disk image and metadata.

The preview is ad-hoc signed without Developer ID or notarization. The development Mac currently has no valid Developer ID signing identity. Installation to Applications keeps the path stable but does not remove Gatekeeper's first-launch approval. Screen Recording consent is separate and belongs to the installed app's signature. See [installation](../README.md#download-and-open), [capture access](USAGE.md#capture-access) and the [trusted-signing workflow](../CONTRIBUTING.md#signing-and-notarization).

This revision adds native regression coverage for multi-display geometry, capture-session state, inactive-overlay first-mouse acceptance, display choice, larger editor targets, moved actions and access to secondary tools. Physical capture across two monitors still needs a connected second display. Automated geometry checks are not a physical multi-monitor pass.

## Current automated checks

| Environment | Result |
|---|---|
| Local Apple Silicon, Swift 6.3.2, Command Line Tools | 123 core scenarios through the native assertion fallback, zero failures, and 451 native integration checks passed |
| Native bundle | Optimized compilation, strict ad-hoc signature, stable identity and system-framework linkage passed |
| Installer, private temporary fixture | Running-app refusal, previous-app backup and restoration after a controlled final-verification failure passed |

The added editor checks exercise common and secondary tools, all letter shortcuts, moved menu actions, text focus, real crop/reset and selected Blur strength, plus default/minimum-size layout and expanded-inspector access in light and dark appearances. Capture checks cover synthetic display geometry, hidden overlay first-mouse behavior and guarded session state. Physical capture and cross-app receipt remain separate checks below.

## Recorded preview 1 checks

The following results belong to [preview 1](https://github.com/Jacknelson6/Velinshot/releases/tag/v1.0.0-preview.1), rather than a claim that its counts describe the current source. Preview 1 was built from `9751d62`; release source `73ead73` only corrected the hosted runner. Its downloaded archive matched the installed executable and signature.

| Environment | Result |
|---|---|
| Full Xcode, Intel macOS 15 | [115 XCTest cases](https://github.com/Jacknelson6/Velinshot/actions/runs/43937679951), release compilation and bundle validation passed |
| Local Apple Silicon, Command Line Tools | 115 core scenario bodies, 10 assertion-failure probes and 152 native integration checks passed |
| Release package | Bundle, strict signature, linkage and downloaded archive checks passed |

The Command Line Tools fallback executes the scenario bodies through an explicitly named native assertion harness. Unsupported constructs fail. It is not an XCTest result. All 90 earlier core cases remain, with 17 palette and eight full-canvas markup cases added.

Coverage includes image dimensions, all eight EXIF orientations, ICC/alpha fidelity, frozen input after file replacement, source-coordinate crops, original-pixel exports, undo/redo, persistence, cancellation, error paths and input limits. Exact balance is compared with a brute-force oracle on 886 fixtures. [Core test notes](../Tests/VelinshotCoreTests/README.md) describe the bounded preview-only antialiasing tolerance; full exports remain strict.

Native checks use synthetic images, isolated preferences, a private pasteboard and hidden AppKit views. They exercise drawing, text editing, selection, resizing, promised PNG writing, decoding, OCR, hotkey registration/conflict retry and asynchronous worker behavior. Unit promise writing does not prove receipt by Finder.

## Previously observed native behavior

The installed preview 1 passed file import, automatic inset color, a pointer-drawn arrow extending onto the mat, JPEG export with pixel verification, S/save, C/copy-close, clipboard reopening and real display capture. Area selection overlay and Escape cancellation also passed. Normal first-launch approval was completed for that unchanged app and it opened successfully.

Earlier native GUI exercises cover text editing, PNG export, presets, save cancellation, original-image copy, reopen-last-closed, image drops and opening/canceling the Share picker. These are specific observed actions, rather than a claim that every destination or device combination has passed.

Automatic inset checks cover crop changes, manual overrides, saved-style compatibility, interrupted gestures and stale results. Full-canvas checks cover mat-only/crossing marks, movement, resizing, text, hidden-mark recovery, undo/redo and preview/export agreement.

Preview 1 light/dark, default/minimum-size and export renders received independent visual review. [Image provenance](images/editor-provenance.json) records the documentation image layouts. Two development crash reports led to file-promise initialization and validation scheduling corrections. Subsequent observed preview 1 launches, including the approved first launch, produced no new report.

## Remaining manual checks

- Physical area/window capture gestures and global-hotkey delivery.
- Finder receiving a promised file and the selected Share destination receiving the result.
- Physical capture across multiple displays, including a selection spanning screens with different scales.
- A real logout/login cycle with launch at login enabled.

The controls exist, but these final flows are not live passes. The package is Apple Silicon; hosted Intel tests validate the source, not an Intel release download. Developer ID signing and notarization are still absent. A rebuilt ad-hoc signature can require renewed Screen Recording consent even when the app stays in Applications.

Run local checks with `bash scripts/check.sh`. Use synthetic fixtures for GUI validation. [Performance measurements](PERFORMANCE.md) have their own source, device and timing limits.
