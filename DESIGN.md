# Interface design

The screenshot leads. Velinshot uses quiet neutral chrome, a spacious preview, an exact tool rail and a narrow inspector. Surface contrast and spacing separate controls without stroked panel borders. Iris marks the selected tool and primary Copy action.

## Layout and controls

- Default editor: 950 × 650pt. Minimum: 820 × 560pt, fitted to the visible display when smaller.
- Inspector: 238pt. Tool rail: 50pt. Toolbar: 50pt. Footer: 54pt.
- Drawing symbols: 20pt within 38 × 32pt targets. Other toolbar symbols: 17pt. Preserve vector proportions and zero alignment insets.
- Tool and toolbar controls: 32pt high. Footer actions: 36pt high.
- Native system type: 12pt controls, 13pt body, 18pt section titles and 26pt welcome heading. Use monospaced digits for measurements.
- Iris: `#7160E8`. Light ink: `#191A25`. Light paper: `#F6F5F8`. Dark appearance and secondary labels follow native colors.

## Interaction

Capture opens the editable preview. C copies and optionally closes; S opens the save picker. Text fields own letter shortcuts while editing. Contextual annotation controls replace the composition inspector when needed. Every inspector section scrolls at the minimum window size.

Focus, hover and selection are event-driven. Avoid perpetual animation, idle render timers and live blur. Decode files outside drawing methods. Keep preview and export geometry on the same renderer.

Use Apple's [toolbar guidance](https://developer.apple.com/design/human-interface-guidelines/toolbars), [SF Symbols](https://developer.apple.com/sf-symbols/), [layout guidance](https://developer.apple.com/design/human-interface-guidelines/layout) and [accessibility guidance](https://developer.apple.com/design/human-interface-guidelines/accessibility). The dimensions above are this app's implementation choices.

Repository images are native AppKit views rendered with synthetic fixtures. Review light/dark appearance and default/minimum window sizes. Rendered views do not replace live capture or cross-app delivery checks.
