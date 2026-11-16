# Performance evidence

The app retains full-resolution source pixels for export while reusing one reduced display proxy for editing. Decode, exact balance and source preparation run on a serial worker. A newer request cancels queued work and suppresses stale delivery. Batch imports wait for main-thread presentation before preparing the next document. There are no recurring idle render timers or polling services.

Exact balance uses the same original-resolution content predicate, corner safeguards and two-pixel safety margin as the earlier brute-force scan. Boundary seeking skips content interiors without downsampling thin marks. A retained normalization bitmap avoids a second owned full-size byte-array copy. Frozen encoded input uses a bounded bulk read plus a bounded short-read/growth continuation.

## Measurement scope

Release synthetic benchmarks cover PNG, JPEG and HEIC at tiny, 1.6 MP, 8.85 MP and 33.18 MP, plus high-entropy and alpha fixtures. Reports separate encoded read/metadata, native decode, exact balance, first render, proxy creation and three style redraws. Fresh-process means app-cache cold, with OS cache uncontrolled; warm is a same-process repeat. No global cache purge is used. These timings exclude actual OS capture, clipboard transfer and GUI compositor paint.

Initial matrices show materially less exact-analysis and repeated-preview CPU on screenshot-like images. They also show variable end-to-end decoding times, including a slower first preparation for a high-entropy PNG. A bounded paired baseline/current comparison and native idle CPU interval are being recorded before the final performance claims. No universal instant-load or zero-CPU claim is made.

The one-document 33 MP synthetic preparation target is below 600 MiB process peak. The latest complete matrix peaked at 479.9 MiB after the bounded-reader change, compared with 550.6 MiB in the preceding prepared path. This is process RSS during that finite benchmark, not an aggregate limit for many open documents. Each open document retains its original pixel buffer, and one closed document is retained for Reopen Closed Screenshot.

Reproduce finite current-path evidence with `python3 scripts/checks/benchmark-pipeline.py --mode prepared`. A historical baseline must use the corresponding earlier core source; passing `--mode baseline` alone on new core source does not restore the earlier algorithm. The final report records source hashes and medians/ranges instead of selecting the fastest samples.
