# Velinshot design

## Product world
Native Mac utility, operated repeatedly during real work. The screenshot leads. Use a calibrated light table: quiet neutral chrome, a spacious preview, an exact tool rail and a narrow inspector. Iris marks selection and primary action; screenshot backgrounds can be expressive without coloring the whole application.

## Direction record
Seven grounded systems considered: Mac drawing inspector, desktop publishing pasteboard, photographic contact sheet, scientific lightbox, optical viewfinder, calibrated light table, camera control back. The concept seed assigned the sixth direction. The light table carries accurate framing and compact repeated use. Metro tiles, barcode art, orienteering maps, airport signs, reference-setting rails and boarding passes were weighed against task clarity; none improves native editing enough to replace it. Their useful disciplines are clear active-state contrast, strict measurement alignment, one accent for actionable state and persistent identity during changes. No decorative motifs are borrowed.

The owner delegated aesthetic decisions through the overnight build request. This is a code-led native build, with image-generated brand exploration and real integrated screenshots as evidence. No web detector applies to AppKit.

## Tokens
- Ink: #191A25, secondary text uses native secondaryLabelColor with accessible contrast.
- Iris: #7160E8, active tool and primary Copy action.
- Paper: #F6F5F8 in light appearance; native windowBackgroundColor for dark appearance.
- Default screenshot mat: pale iris gradient #B7AEF8 to #E6E3FF.
- Native SF font, 12-point controls, 13-point body, 18-point section title, 26-point welcome heading. Measurements use monospaced digits only.
- Inspector width 238, tool rail 50, footer 54, toolbar 50. Default editor 950 by 650, minimum 820 by 560. Respect a smaller visible display by fitting within it.
- Use native SF Symbols at 20 points for drawing tools and 17 points elsewhere, with preserved aspect ratios and native focus/hover/disabled affordances. Tool/toolbar controls are 32 points tall; footer actions are 36 points. Custom alignment insets are zero so drawn frames match declared targets. No emoji stand-ins.

## Behavior
Open directly into an editable preview. Bare C copies the flattened image and optionally closes; S always opens the native save chooser. Text editing owns letter keys. Capture overlays are separate from the editor, Space selects a window, Escape cancels, and hidden windows restore on failure or cancellation. The editor remains resizable and every inspector section scrolls on smaller windows.
