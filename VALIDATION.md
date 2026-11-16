# Preview status

This repository contains the runnable native preview and complete source. The preview is free and MIT licensed. A stable app release has not been published.

The current local gate passes 115 core scenario bodies, 10 assertion-failure probes and 135 native checks, plus release compilation, actual image decode/encode, OCR and bundle verification. This Mac uses the documented Command Line Tools assertion harness, not XCTest. Earlier source passed [90 hosted XCTest cases](https://github.com/Jacknelson6/Velinshot/actions/runs/43818101131); that historical result does not validate the current source. Current hosted CI is tracked separately.

Native gesture checks cover arrows wholly on the mat, crossing the photo edge, selection, movement, resizing, undo/redo, text editing and recovery of hidden marks. Automatic inset checks cover cropped palette changes, manual overrides, saved-style compatibility and stale results. Native light/dark renders at default and minimum sizes received independent visual review.

The owner confirmed capture works in the installed 4fd7102 build after its stale Screen Recording signature binding was repaired. A changed ad-hoc binary may need fresh consent. Mode-by-mode area/window/display and physical global-hotkey acceptance, Finder receiving a promised file, final Share destination readback, multiple displays and a real logout/login cycle remain separate checks. Prior live synthetic GUI checks cover drawing, text, copy/close, PNG/JPEG save, cancellation, presets and the Share picker.

The Apple Silicon app is about 2.2 MB and uses system frameworks only. It is ad-hoc signed, without Developer ID or notarization. [Detailed QA](docs/QA.md) and [performance evidence](docs/PERFORMANCE.md) describe the measured scope and remaining checks.
