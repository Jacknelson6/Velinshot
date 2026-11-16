# Contributing

Keep the capture-to-copy path short and the app native. Use system frameworks; add a dependency only when its benefit justifies its size and lifecycle. The app must remain useful without an account, subscription or required watermark.

## Build and check

```sh
bash scripts/build-app.sh
bash scripts/check.sh
```

Run heavy local builds serially. Full Xcode runs XCTest. Command Line Tools use the documented [native assertion fallback](scripts/checks/README.md); report it by that name. GUI capture and cross-app delivery need separate checks on a Mac.

## Changes

Use a small branch and describe the concrete trigger and resulting behavior. Include the relevant verification and name any manual check still pending. Documentation-only changes should check links, commands and factual claims.

Core coordinates use top-left original source pixels. `panelRect` contains inset plus source; `imageRect` is the source placement. Keep preview and export on the same renderer. Test meaningful pixels, dimensions, alpha, undo and error handling when behavior changes. Capture, clipboard, file writes and input limits need failure-path coverage.

Use synthetic screenshots in examples and issues. See [product scope](PRODUCT.md), [interface design](DESIGN.md) and [current validation](docs/QA.md). Automatic PII detection is outside the current scope.
