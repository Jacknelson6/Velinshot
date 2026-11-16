# Contributing

Keep the capture-to-copy path short and the app native. Use system frameworks and add a dependency only when its benefit is clear enough to justify its size and lifecycle.

Build with `bash scripts/build-app.sh`. Run `bash scripts/check.sh` serially with other local builds. A full Xcode install runs XCTest; Command Line Tools can use the documented native assertion runner. Do not call that fallback an XCTest pass.

Core image coordinates use top-left original source pixels. `panelRect` contains inset plus source; `imageRect` is the source placement. Keep preview and export on the same renderer. Test meaningful pixels, dimensions, alpha, undo and error handling when behavior changes.

Make a small branch, describe the user-visible trigger and result, and include relevant verification. Use synthetic screenshots in issues and examples. Changes to capture, clipboard, file writes and image limits need tests that exercise their failure paths.

The app must remain useful without an account, service subscription or mandatory watermark. Automatic PII detection is outside the current scope.
