# Velinshot

<!-- impeccable:product-schema 1 -->

## Platform
macos

Native macOS desktop app. Impeccable's web/iOS/Android conventions are applied only where they fit AppKit; native macOS is the owning convention.

## Stack
Delegated by the request for the lightest practical implementation: Swift, AppKit, Core Graphics, ScreenCaptureKit, ImageIO and Vision. No embedded browser and no external runtime dependencies.

## Users
Jack Nelson captures screenshots throughout agency work and needs to annotate, frame, copy and save immediately. The public source is also useful to other Mac users who want a free local screenshot editor.

## Product Purpose
Capture, edit and share a beautiful screenshot in a short keyboard-driven flow. Command-4 captures, the preview supports drawing and framing, C copies quickly, S asks where to save.

## Operating Context
Xnapper 1.17.1 is the observed incumbent. Preserve its settings while building an independent alternative. The current shortcut is Command-4; the incumbent closes after copying and saves through a native file chooser.

## Capabilities and Constraints
Capture area, window and display; import image or clipboard; pen, arrows, shapes, text, highlight, manual blur and redact; crop, undo and redo; inset, rounding, shadows, backgrounds, ratios and presets; OCR and history; PNG/JPEG export. Automatic PII detection is excluded. Free source and no watermark. Offline operation, small native binary, bounded image memory and clear native privacy-permission handling.

## Brand Commitments
The owner requests an original unused name, a cool image-generated logo/brand kit and a beautiful repository. Velinshot is the selected working name after exact web/App Store/GitHub checks found no results. This is a practical naming check rather than a worldwide trademark clearance. No incumbent art or source is reused.

## Product Principles
- Capture and keyboard actions come first.
- Render preview and export through the same image engine.
- Keep screenshots local and make history explicit.
- Let the screenshot lead; controls stay compact and legible.

## Evidence on Hand
Observed installed preferences and current public feature list at https://xnapper.com/. All repository screenshots and fixtures must be synthetic, never Jack's real work.

## Implementation assumptions
macOS 14 or later, Apple Silicon first, MIT license and an optional opt-in local history are implementation choices made from the brief. Native system font and macOS keyboard/accessibility behavior are defaults. No claims of notarization, signed distribution identity or App Store publication.
