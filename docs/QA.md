# Validation

Compilation, automated checks, actual native GUI exercises and OS-consent-dependent capture are recorded separately. No check implies perfection or universal performance.

## Current local gate

The current editor candidate passes **115 core scenario bodies, 10 assertion failure probes and 135 native integration checks**, plus release compilation, actual image decode/encode, Vision OCR and bundle/signature/linkage validation. All 90 earlier core scenarios remain unchanged. Additional seeded tests compare exact balance against the prior brute-force oracle on 886 thin, threshold, random, transparent and edge fixtures.

This Mac has Command Line Tools without XCTest or Swift Testing. `scripts/core-checks.py` runs the same source scenario bodies in an explicitly identified native assertion harness. Unsupported constructs fail rather than being skipped. These are not reported as XCTest results. Hosted full-Xcode CI runs XCTest separately.

## Native behavior

The finite `--smoke-check <directory>` path uses isolated preferences, synthetic images, a private pasteboard and hidden native views. It checks all drawing tools, document/field undo, coalesced sliders, text cancellation, source-coordinate crop/resize, URL settings, real OS hotkey registration and occupied-key retry, promised PNG data/files, refusal to overwrite, accepted save-extension encoding, optional history failure, worker cancellation and batch presentation ordering. Interrupted strokes and delayed mouse-up after undo cannot leave stale annotation indexes.

Actual native GUI work has exercised copy/close, clipboard reopening, reopen-last-closed, OCR, a save destination panel, real PNG/JPEG output, format switching and quality, save cancellation, source copy, arrow/box drawing, text typing/cancellation/undo, fixed dimensions, watermark entry, saving/deleting a test preset, a real PNG drag into the editor and opening/canceling the system Share picker. GUI runs used our own synthetic fixture, with no user images published. The frozen e4e7b84 app also passed the padded watermark field's typing and undo, final C copy/close, and native denied-capture guidance with Later returning safely. A file dragged from its export button back into the editor reopened as a flattened image at the expected framed dimensions. Finder receipt remains unconfirmed.

Full-Xcode [CI at e4e7b84](https://github.com/Jacknelson6/Velinshot/actions/runs/43813596037) passed all 90 XCTest cases, release build and bundle validation. Later source changes have their own checks and source binding in the candidate report.

## Crash corrections

Two macOS crash reports from development validation identified an Objective-C file-promise initializer trap and a mis-scheduled validation load. Both were corrected. The source-preparation API reports a scheduling error instead of terminating the process, and the test now uses a real asynchronous worker with a bounded completion wait. Subsequent integrated checks and the three normal launches created no new crash report. This is bounded observed evidence, not a promise that every environment is crash-free.

## Rendering and file fidelity

Tests cover all eight EXIF orientations, ICC and alpha, immutable encoded inputs after file replacement/deletion, odd/narrow source dimensions, arbitrary crops, original-pixel annotation alignment, fixed export sizes and exact full-resolution export samples above the proxy size. The cached proxy bitmap is internal to the core module and unavailable to app export APIs. Tight crops fall back to the already-decoded original region when the whole-image proxy lacks detail.

Preview-only edge antialiasing has an explicitly bounded tolerance in [the test notes](../Tests/VelinshotCoreTests/README.md). Full exports remain strict. A valid 64 MP metadata fixture is rejected before native decode; the product limit remains 40 MP/16,384 pixels and 250 MB encoded input. Injected-reader cases verify exact caps, short reads, growth, EOF and failures without large allocations.

## Native appearance artifacts

`--render-studio <directory>` exports the real AppKit view hierarchy in light/dark, default 950×650 and minimum 820×560 layouts, with isolated settings. These are native rendered UI artifacts with a synthetic fixture, not live screen recordings. The design uses 20pt drawing symbols, 17pt toolbar symbols, preserved vector aspect ratios, 38×32pt drawing targets, 36pt footer actions and no stroked panel borders. Native tests measure the actual button frames. `docs/images/editor-provenance.json` records the layouts.

## Remaining consent and GUI checks

The owner confirmed capture works in the installed 4fd7102 build after its obsolete code-signature permission binding was repaired. This does not pass every capture mode or a later ad-hoc binary. Privacy grants are never automated. Mode-by-mode area/window/display and physical global-hotkey acceptance, real Finder receiving a promised file, final Share readback, launch-at-login and multiple-display capture remain distinct checks. A unit promise writer is not a real Finder drop. Unrun checks remain pending.

## Distribution and performance

The current package is an Apple Silicon native app of about 2.2 MB, using system frameworks only, with an ad-hoc signature. It has no Developer ID or notarization receipt. A rebuilt ad-hoc app may need macOS consent again. The final release report binds source commit, executable SHA256, size, hosted tests, native QA and remaining consent gates. [Performance notes](PERFORMANCE.md) describe synthetic timings and their limits.

## Focused appearance repair

The minimum Frame inspector has tighter spacing so Reset crop fits. Active markup replaces the composition list and has a direct route back. Underline tabs and a softer text field remove heavy control slabs; color wells show both a swatch and hex value. Drag uses the same native button drawing as the other actions. Automatic analysis also waits for inspector and watermark gestures, with explicit idle/active regression checks. Refreshed native appearance exports receive independent review.

The export panel uses direct PNG/JPEG segments. During automated native-popup QA, a process sample showed the old format popup was still in macOS menu tracking; dismissing it restored normal save and cancel. The direct choices simplify that interaction. Native checks verify their encoding and quality enablement; file extensions remain authoritative at the final write. Visible action titles also provide semantic accessibility names rather than generic SF Symbol labels.

Welcome synchronizes with manual shortcut retry and Settings refresh. Shortcut availability comes from the OS registration result; another process running does not imply a conflict. Isolated validation/export modes finish AppKit startup before drawing native text. Normal application launch uses the standard application run loop.

## Full-canvas markup and automatic inset

Source-coordinate annotations can extend into negative coordinates and beyond the image dimensions. A shared transform maps them into the framed composition. Eight additional core scenarios cover mat-only and crossing arrows, crop/inset/fixed output alignment, proxy/export agreement, blur clipping, paint order, canvas shrinkage and older saved styles. Native gestures cover mat selection, movement, resizing, text editing, undo/redo and Tab recovery of hidden marks. The outer canvas remains the export boundary.

Seventeen palette scenarios pin dominant visible edge clusters, alpha thresholds, exact ties, crop bounds and transparent fallbacks. The inset uses a sample bounded to 64 pixels per side on the existing serial worker. Results are cached by crop, deferred during gestures and canceled on manual color choice. Native checks cover manual/Auto persistence, undo/redo, cropped palette refresh and a late automatic document preserving a newer manual default. Independent read-only QA opened all seven light/dark, default/minimum, margin and export renders and found no material blocker.
