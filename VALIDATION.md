# Preview status

This repository contains the runnable native preview and complete source. [Download the free preview](https://github.com/Jacknelson6/Velinshot/releases/tag/v1.0.0-preview.1), or build the MIT-licensed source. The published app was downloaded again, re-extracted and checked against the installed binary's hash and signature. This is a prerelease.

The local Apple Silicon gate passes 115 core scenario bodies, 10 assertion-failure probes and 152 native checks, plus release compilation, actual image decode/encode, OCR and bundle verification. The local core harness uses the documented Command Line Tools fallback, not XCTest. [Full-Xcode CI](https://github.com/Jacknelson6/Velinshot/actions/runs/43937679951) passed all 115 XCTest cases, release compilation and bundle verification on Intel macOS. Its native build inputs match the installed Apple Silicon app.

Native gesture checks cover arrows wholly on the mat, crossing the photo edge, selection, movement, resizing, undo/redo, text editing and recovery of hidden marks. Automatic inset checks cover cropped palette changes, manual overrides, saved-style compatibility and stale results. Native light/dark renders at default and minimum sizes received independent visual review.

The installed 9751d62 build passed actual file import, automatic inset selection, a pointer-drawn mat arrow with JPEG pixel verification, S/save, C/copy-close, clipboard reopening and real display capture. Its Screen Recording entry matches the installed signature. Area overlay and Escape cancellation also passed. Physical area/window gestures and global-hotkey delivery, Finder receiving a promised file, final Share destination readback, multiple displays and a real logout/login cycle remain separate checks. Earlier live synthetic checks cover text, PNG export, presets and the Share picker.

The Apple Silicon app is about 2.2 MB and uses system frameworks only. It is ad-hoc signed, without Developer ID or notarization. [Detailed QA](docs/QA.md) and [performance evidence](docs/PERFORMANCE.md) describe the measured scope and remaining checks.
