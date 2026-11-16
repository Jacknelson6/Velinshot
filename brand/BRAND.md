# Velinshot brand kit

Velinshot gives a screenshot room to breathe. Its folded V turns a flat capture into something considered, without getting in the way of the work.

## Mark

Use `logo.png` as the transparent primary mark. `app-icon.png` is the same clean standalone V used by the shipped app; the build script generates its native `.icns` sizes. `wordmark-light.svg` and `wordmark-dark.svg` pair it with the name and tagline. Keep clear space of at least one quarter of the mark's width.

`brand-kit.svg` and `brand-kit.png` are the canonical identity board. Every placed mark uses the exact same generated PNG; the SVG remains editable. Exact-size 900×240 PNG wordmarks accompany the SVG files. The earlier generated board is kept as `brand-kit-exploration.png`, and the pre-refinement mark as `logo-original.png`. Those are process studies, not alternate production marks. `logo-exploration.png` contains twelve concepts across four directions; the final direction grew from B2. `icon-study.png` is an earlier tile study, not the shipped icon.

## Color

| Color | Hex | Use |
|---|---|---|
| Iris | `#7160E8` | Primary action, active tool, identity |
| Ink | `#191A25` | Text and dark brand surfaces |
| Mist | `#E9E5FB` | Quiet lavender surfaces |
| Paper | `#F6F5F8` | Light brand ground |
| Coral | `#F05A6E` | Expressive annotation accent |

The interface follows native macOS light/dark appearance. Screenshot backgrounds may use richer gradients; the control chrome stays quiet. Machine-readable values are in `palette.json` and `palette.css`.

## Type

Manrope is the brand face, with strong weight and clear spacing. The included variable font is from the official Google Fonts Manrope directory and includes its SIL Open Font License. The app uses the native system font, SF Pro, supplied by macOS. Apple font files are not bundled.

## Voice

**A good screenshot. In a moment.**

Use short, useful verbs: capture, draw, frame, copy, save. Show the image instead of making a performance claim. The app is free, local and keyboard-friendly.

## Provenance

The identity images were generated with the built-in image-generation tool on November 15, 2026. The mark is original artwork; no Xnapper art was reused. Exact prompts and reference roles are in `PROMPTS.md`. The production mark was refined for cleaner fold separation. Wordmarks and the current board are deterministic SVG compositions of that canonical transparent image and the included Manrope face, with PNG exports at their intrinsic aspect ratios. These compositions preserve the mark rather than asking a generator to redraw it.
