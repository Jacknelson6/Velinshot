# Preview status

The runnable native app and complete source are on [feature/native-macos](https://github.com/Jacknelson6/Velinshot/tree/feature/native-macos), under review in [PR 1](https://github.com/Jacknelson6/Velinshot/pull/1). This main branch presents the original identity and real native editor views while release acceptance remains open.

Source 68722db56862b34c3bfa4a4dc3d2ab2343c9e3c4 passes [full-Xcode CI](https://github.com/Jacknelson6/Velinshot/actions/runs/43818101131): all 90 XCTest cases, release compilation and bundle verification. The local gate also passed 10 assertion-failure probes, 92 native integration checks, actual image decode/encode and OCR. Native AppKit appearance review passed at 9.5/10 overall; that subjective score does not prove function.

Live synthetic GUI checks cover drawing, text entry, undo, copy/close, clipboard reopening, PNG/JPEG export and native save cancellation, presets and the Share picker. The exact packaged 68722db app passed launch, shortcut retry message synchronization and Save/cancel/C copy-close.

Live area/window/display capture and physical global-hotkey end-to-end behavior remain pending the owner's Screen Recording approval. Finder receiving a promised file is unconfirmed; native image drag and isolated file-promise checks passed. Multi-display capture and a real logout/login cycle remain separate checks.

The candidate is an Apple Silicon app of 2,141,559 bytes, using system frameworks only. It is locally ad-hoc signed, without Developer ID or notarization. No final app release, live capture acceptance, universal zero-CPU claim or perfect reliability is claimed. Performance and additional test scope are documented on the source branch.

The launch film is being reviewed as a draft. Its final render and public embedding await explicit draft approval. No team messages have been sent.
