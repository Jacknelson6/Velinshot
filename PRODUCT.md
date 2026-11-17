# Product scope

Velinshot is a free, native macOS screenshot editor for people who capture, annotate and share images throughout their workday. The main flow is capture, edit, then C to copy or S to choose where to save.

## Principles

- Keep capture and keyboard actions fast.
- Let the screenshot lead, with compact and legible controls.
- Use one image engine for preview and export.
- Keep screenshots local and history optional.
- Stay useful without an account, subscription or mandatory watermark.

## Platform and scope

macOS 14 or later, using Swift, AppKit, Core Graphics, ScreenCaptureKit, ImageIO and Vision, with pinned Sparkle 2.10.1 for authenticated updates. The packaged preview targets Apple Silicon. Source builds use the compatible Mac's native architecture. The screenshot editor remains native.

Capture area, window and display; import files and clipboard images; annotate, crop and frame; copy, save, drag and share. Local OCR, presets and optional editable history support the same workflow. Automatic PII detection and built-in cloud uploads are excluded. See the [feature reference](docs/FEATURES.md).

## Public evidence

Use synthetic screenshots and fixtures in documentation and issue reports. Distinguish implemented behavior from observed GUI checks. Record test scope and remaining manual checks in [validation](docs/QA.md), and measured resource use in [performance evidence](docs/PERFORMANCE.md).

The source is MIT licensed. The preview is ad-hoc signed, without Developer ID or Apple notarization; the release scripts support a separate, explicit Developer ID and notarization workflow.
