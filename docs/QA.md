# Validation

Compilation, automated checks, actual native GUI exercises and OS-consent-dependent capture are recorded separately. No check implies perfection or universal performance.

## Current local gate

The release candidate passes **90 core scenario bodies, 10 assertion failure probes and 86 native integration checks**, plus release compilation, actual image decode/encode, Vision OCR and bundle/signature/linkage validation. The original 67 scenarios remain unchanged; the original forty are a subset. Additional seeded tests compare exact balance against the prior brute-force oracle on 886 thin, threshold, random, transparent and edge fixtures.

This Mac has Command Line Tools without XCTest or Swift Testing. `scripts/core-checks.py` runs the same source scenario bodies in an explicitly identified native assertion harness. Unsupported constructs fail rather than being skipped. These are not reported as XCTest results. Hosted full-Xcode CI runs XCTest separately.

## Native behavior

The finite `--smoke-check <directory>` path uses isolated preferences, synthetic images, a private pasteboard and hidden native views. It checks all drawing tools, document/field undo, coalesced sliders, text cancellation, source-coordinate crop/resize, URL settings, hotkey collision protection, promised PNG data/files, refusal to overwrite, accepted save-extension encoding, optional history failure, worker cancellation and batch presentation ordering. Interrupted strokes and delayed mouse-up after undo cannot leave stale annotation indexes.

Actual native GUI work has exercised copy/close, clipboard reopening, reopen-last-closed, OCR, a save destination panel, real PNG output, save cancellation, source copy, arrow/box drawing, text typing/cancellation/undo, fixed dimensions, watermark entry, saving a preset, a real PNG drag into the editor and opening/canceling the system Share picker. GUI runs used our own synthetic fixture, with no user images published. A v3 launch candidate completed three normal launches and editor opening, background edit, undo and C copy/close after the crash corrections below. The final frozen candidate still receives a separate GUI readback.

## Crash corrections

Two macOS crash reports from development validation identified an Objective-C file-promise initializer trap and a mis-scheduled validation load. Both were corrected. The source-preparation API reports a scheduling error instead of terminating the process, and the test now uses a real asynchronous worker with a bounded completion wait. Subsequent integrated checks and the three normal launches created no new crash report. This is bounded observed evidence, not a promise that every environment is crash-free.

## Rendering and file fidelity

Tests cover all eight EXIF orientations, ICC and alpha, immutable encoded inputs after file replacement/deletion, odd/narrow source dimensions, arbitrary crops, original-pixel annotation alignment, fixed export sizes and exact full-resolution export samples above the proxy size. The cached proxy bitmap is internal to the core module and unavailable to app export APIs. Tight crops fall back to the already-decoded original region when the whole-image proxy lacks detail.

Preview-only edge antialiasing has an explicitly bounded tolerance in [the test notes](../Tests/VelinshotCoreTests/README.md). Full exports remain strict. A valid 64 MP metadata fixture is rejected before native decode; the product limit remains 40 MP/16,384 pixels and 250 MB encoded input. Injected-reader cases verify exact caps, short reads, growth, EOF and failures without large allocations.

## Native appearance artifacts

`--render-studio <directory>` exports the real AppKit view hierarchy in light/dark, default 950×650 and minimum 820×560 layouts, with isolated settings. These are native rendered UI artifacts with a synthetic fixture, not live screen recordings. The design uses 19pt drawing symbols, 17pt toolbar symbols, preserved vector aspect ratios, 38×32pt drawing targets and no stroked panel borders. `brand/editor-provenance.json` records the layouts.

## Remaining consent and GUI checks

Area/window/display capture is not passed until the owner grants Screen Recording to the final app and actual captures have been observed. Privacy grants are never automated. Real Finder receiving a promised file, final Share readback, launch-at-login registration and multiple-display capture remain distinct checks. A unit promise writer is not a real Finder drop. Unrun checks remain pending.

## Distribution and performance

The current package is an Apple Silicon native app of about 2.2 MB, using system frameworks only, with an ad-hoc signature. It has no Developer ID or notarization receipt. A rebuilt ad-hoc app may need macOS consent again. The final release report binds source commit, executable SHA256, size, hosted tests, native QA and remaining consent gates. [Performance notes](PERFORMANCE.md) describe synthetic timings and their limits.
