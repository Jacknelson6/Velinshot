# Feature coverage

Velinshot is an independent native macOS screenshot editor. The table below maps its capabilities to the app's controls. Validation status and remaining live checks are recorded separately in QA.md.

| Function | Velinshot route |
|---|---|
| Custom global screenshot shortcut | Settings, default ⌘4; macOS registration determines availability |
| Capture and copy shortcut | Settings, default ⌃⌥⌘5 |
| Area, Space/window, full display | Native ScreenCaptureKit selection overlays and File menu |
| Preview after capture | Compact resizable native editor |
| Copy and close | C / ⌘C, configurable; background double-click copies/closes |
| Save / Save As | S / ⌘S always opens the native destination picker |
| Copy/save original | File menu, unframed source pixels |
| Drawing and annotations | Pen, line, arrows, boxes, ellipses, text, highlight and numbered steps |
| Manual blur/redact | Separate blur and opaque redaction tools |
| Edit marks | Select/move/resize/recolor, text editing, delete, undo/redo |
| Padding and inset | Independent outer mat and inner fill, original-pixel units |
| Balance | Conservative uniform-edge trim, applied on import/capture or explicit toggle |
| Automatic color | Edge-band sampling on import/capture or explicit toggle |
| Rounded corners, shadow | One native renderer for preview and export |
| Desktop/color/gradient/image/none backgrounds | Inspector, managed imported image assets, transparent PNG |
| Ratios, social canvases, exact output sizes | Canvas picker and custom ratio/size input |
| Custom presets | Save, restore and delete named frame styles |
| Optional watermark text | Inspector; empty by default, corner/color controls |
| OCR text selection/copy | Editor text button or Edit menu, native selectable text window |
| Drag finished image | Native promised PNG file plus PNG pasteboard data |
| Share | macOS Share picker; no built-in cloud upload |
| Open file/clipboard | File menu, toolbar and image drop |
| Screenshot history | Opt-in editable history with local storage bounds and folder selection |
| Reopen closed screenshot | One most recent closed image kept in memory |
| Launch/login, Dock, sound, filenames, default save folder | Settings using native macOS services |
| Updates | Manual public GitHub release check |
| Automatic PII detection | Excluded at the owner's request |
| Cloud upload | Not implemented |
| License management/purchase | No equivalent needed: MIT-licensed source, no paywall or required watermark |

Insets and padding scale with source geometry. Fixed-size exports fit the source uniformly and fill extra space with the chosen background. Watermark size and margins use export pixels. A very small fixed output may reject watermark text that cannot fit; clear the text or choose a larger canvas.

Dynamic or inaccessible desktop wallpapers fall back visibly to the current gradient. Imported image files remain available as backgrounds.
