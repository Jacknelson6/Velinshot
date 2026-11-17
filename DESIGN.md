# Interface design

The screenshot leads. Velinshot uses quiet neutral chrome, a spacious preview, an exact tool rail and a narrow inspector. Surface contrast and spacing separate controls without stroked panel borders. Iris marks the selected tool and primary Copy action.

## Layout and controls

- Default editor: 950 × 650pt. Minimum: 820 × 560pt, fitted to the visible display when smaller.
- Inspector: 250pt. Tool rail: 64pt. Header: 60pt. Footer: 64pt.
- Drawing symbols: 20pt within 44 × 44pt targets. Other toolbar symbols: 18pt. Preserve vector proportions and zero alignment insets.
- Header, inspector action and footer controls: 40pt high. Shared dimensions live in `StudioMetrics`.
- Native system type: 13pt controls and body, 15pt inspector headings and 26pt welcome heading. Use monospaced digits for measurements.
- Iris: `#7160E8`. Light ink: `#191A25`. Light paper: `#F6F5F8`. Dark appearance and secondary labels follow native colors.

## Interaction

Capture opens the editable preview. C copies and optionally closes; S opens the save picker. Text fields own letter shortcuts while editing. Contextual annotation controls replace the composition inspector when needed. Every inspector section scrolls at the minimum window size.

The tool rail shows Select, Arrow, Rectangle, Text, Highlight, Redact and Crop, followed by More tools. Draw, Line, Ellipse, Number and Blur remain in that menu and keep their letter shortcuts. More keeps its ellipsis and an anchored chevron when selected; the highlight, status label, checked menu item and accessible value identify the active secondary tool. All tool controls expose their names.

The header shows Capture, Undo, Redo and More. Fit to Preview, Copy Image Text and Share Screenshot live in More with import, history and settings. Save and primary Copy form the right footer pair; quiet Drag sits with the information on the left. Frame starts with Padding, Corners, Shadow, Auto balance and Reset crop; Advanced frame reveals Inset, Inset fill and Border. Reset crop is enabled only when a crop exists and stays above the disclosure at minimum size. Frame actions align to the inspector column; inset fill uses a label above its checkbox and larger color control.

Markup shows only relevant controls. Blur hides Color and text size, explains the gesture, and labels the existing intensity choices Soft, Medium and Strong. These choices use the renderer's existing stroke-width-derived strength without changing image pixels or adding a new rendering parameter.

Focus, hover and selection are event-driven. Avoid perpetual animation, idle render timers and live blur. Decode files outside drawing methods. Keep preview and export geometry on the same renderer.

Use Apple's [toolbar guidance](https://developer.apple.com/design/human-interface-guidelines/toolbars), [SF Symbols](https://developer.apple.com/sf-symbols/), [layout guidance](https://developer.apple.com/design/human-interface-guidelines/layout) and [accessibility guidance](https://developer.apple.com/design/human-interface-guidelines/accessibility). The dimensions above are this app's implementation choices.

Repository images are native AppKit views rendered with synthetic fixtures. Review light/dark appearance and default/minimum window sizes. Rendered views do not replace live capture or cross-app delivery checks.
