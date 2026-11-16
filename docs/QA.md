# Validation

Validation separates executable checks from GUI exercises and OS-consent-dependent behavior. Compilation does not prove capture permission, a successful file write or a visual result.

## Core

The core suite contains 62 scenarios, including image orientation, Retina/crop/inset mapping, all annotation kinds, alpha, JPEG quality, image bounds, OCR, atomic history/presets, corrupt data and safe paths, old-style decoding, exact output sizes, watermark fitting and scaled shadows. The original forty scenarios are retained.

On the development Mac, Command Line Tools does not include XCTest or Swift Testing. `scripts/core-checks.py` executes the unchanged source scenario bodies through a native assertion runner and runs ten deliberate assertion-failure probes. That result is explicitly separate from an XCTest execution. Hosted CI uses full Xcode for XCTest.

## Native integration

`--smoke-check <directory>` uses isolated preferences, private pasteboard objects, synthetic images and hidden native views. It exercises canvas gestures, settings round trips, known shortcut protection, promised-file output, PNG/JPEG decoding and OCR. It does not synthesize hardware input or grant OS permissions.

Manual native QA has exercised the real editor, the C copy/close flow, reopening the clipboard image, local text recognition, the S save picker, a real PNG file and cancellation preserving the document. The first round caught a URL preference setter issue and the need to protect Xnapper's known shortcuts explicitly. Those were corrected and require the final integrated readback.

## Permission-dependent checks

Area/window/display capture requires the owner to grant Screen Recording to the built app. Denial is handled in the app with a route to Settings. Live capture is not considered passed until actual consent and image capture have been observed.

Real drag to Finder, system Share, launch-at-login state and multiple displays need manual GUI evidence. A private pasteboard/file-promise unit check is not a substitute for a real destination receiving the drag. UI checks that have not run remain pending.

## Distribution

The build script verifies a stable bundle identifier, a local ad-hoc signature, bundle metadata and system-framework-only linkage. There is no Developer ID signature or notarization receipt. The packaged build is Apple Silicon. Rebuilt ad-hoc signatures may cause macOS to ask for Screen Recording access again.

The final release report records the tested source version, bundle digest/size, measured render time, native QA scope and any remaining OS permission gates.
