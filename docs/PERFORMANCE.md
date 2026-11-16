# Performance evidence

The app retains full-resolution source pixels for export while reusing one reduced display proxy for editing. Decode, exact balance and source preparation run on a serial worker. A newer request cancels queued work and suppresses stale delivery. Batch imports wait for main-thread presentation before preparing the next document. There are no recurring idle render timers or polling services.

Exact balance uses the same original-resolution content predicate, corner safeguards and two-pixel safety margin as the earlier brute-force scan. Boundary seeking skips content interiors without downsampling thin marks. A retained normalization bitmap avoids a second owned full-size byte-array copy. Frozen encoded input uses a bounded bulk read plus a bounded short-read/growth continuation.

## Measurement scope

Release synthetic benchmarks cover PNG, JPEG and HEIC at tiny, 1.6 MP, 8.85 MP and 33.18 MP, plus high-entropy and alpha fixtures. Reports separate encoded read/metadata, native decode, exact balance, first render, proxy creation and three style redraws. Fresh-process means app-cache cold, with OS cache uncontrolled; warm is a same-process repeat. No global cache purge is used. These timings exclude actual OS capture, clipboard transfer and GUI compositor paint.

## Paired historical comparison

Four alternating AB/BA pairs use actual core source from 85c74a9 and the frozen current core, identical fixture bytes, 40 fresh child processes and 80 cold/warm records. All source dimensions and crop bounds matched; source and fixture hashes were unchanged.

| Fresh-process preparation | Earlier median | Current median | Current range |
|---|---:|---:|---:|
|8.85 MP UI PNG|210.5 ms|95.5 ms|90.6–101.1 ms|
|33.18 MP UI PNG|725.1 ms|282.4 ms|262.1–342.9 ms|
|33.18 MP UI JPEG|821.9 ms|385.6 ms|366.5–408.1 ms|
|33.18 MP UI HEIC|857.4 ms|470.0 ms|417.2–627.9 ms|
|33.18 MP high-entropy PNG|632.5 ms|761.2 ms|See complete report; variable|

Fresh-process preparation CPU medians for the first four rows changed 207.4→96.7, 710.2→271.2, 730.2→292.8 and 696.4→296.3 ms. Three cached style redraws on the 33 MP UI PNG changed 149.7→39.7 ms elapsed and 154.5→45.2 ms CPU. These are finite synthetic measurements on one M2 Mac, not universal promises.

The high-entropy PNG is a real tradeoff: fresh median was slower, while its warm median changed 653.8→612.1 ms with broad ranges. Retaining a frozen encoded input and creating a reusable proxy add work to an image dominated by decompression. No universal instant-load claim is made.

Fresh single-preparation process peak reached 591 MiB, within the 600 MiB synthetic target. Cumulative warm high-water marks reached 752.8 MiB, compared with 875.9 MiB earlier, but the harness includes a separate encoded-thumbnail diagnostic before the repeat; those cumulative peaks cannot isolate repeat-preparation memory. This is not a total-memory cap for many documents. Each open document retains its original pixels; one closed source remains for Reopen Closed Screenshot. Native idle CPU is recorded separately after final GUI validation.

Reproduce finite current-path evidence with `python3 scripts/checks/benchmark-pipeline.py --mode prepared`. A historical baseline must use the corresponding earlier core source; `--mode baseline` alone does not restore the old algorithm. The paired report preserves source/fixture hashes, all records and ranges. Hosted CI and actual OS capture are separate validation axes.

## Native idle sample

The staged e4e7b84 app, using a 1280×800 synthetic source, consumed 0.01 CPU seconds over 20.01 seconds with the editor open, about 0.05% of one core. RSS moved from 61.4 to 65.5 MiB. After copy/close, a separate 20.02-second interval had no measurable CPU delta at 0.01-second counter resolution; RSS ended at 105.8 MiB, including retained last-closed image data and native caches. These are two finite process-counter samples on this Mac, not a zero-CPU guarantee or a memory bound for large/multiple documents. Later shortcut-recovery changes remain event-driven.
