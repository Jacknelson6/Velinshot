# A calibrated light table

Velinshot keeps the screenshot at the center of the work. The native editor uses soft surface contrast and space between controls, with a restrained iris accent for selection and the primary Copy action. Panels have no stroked borders. The workspace well has a quiet rounded shape, while exported screenshot geometry stays literal.

Drawing symbols use 19pt optical size within 38×32pt targets. Toolbar symbols use 17pt. Vector proportions are preserved and drawing respects AppKit's flipped coordinates. Native segmented controls separate Frame, Backdrop and Output, with ⌘1/2/3 shortcuts. Annotation controls appear when a tool or mark needs them. C and S remain visible and accessible in the footer.

Light and dark colors follow native appearance. Focus, hover and selection are event-driven; no perpetual animation or live blur keeps a closed/idle app busy. File work never decodes images inside a view's draw method. One pending preview and one in flight keep live strokes responsive without building an obsolete render queue.

The design references Apple's [toolbar guidance](https://developer.apple.com/design/human-interface-guidelines/toolbars) for consistent grouping and Apple's [SF Symbols guidance](https://developer.apple.com/sf-symbols/) for optical weights, scales and alignment. The exact dimensions are Velinshot's implementation choices, not quoted Apple requirements.

The hero images are native AppKit views rendered from the real app with a synthetic fixture. They are not live screen recordings and do not substitute for Screen Recording-dependent capture acceptance. The generated folded V, image brand board, palette and original exploration are documented in [the brand kit](../brand/BRAND.md).
