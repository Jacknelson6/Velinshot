# Core checks on macOS

Run `python3 scripts/core-checks.py` from any directory. Full Xcode uses standard `swift test --no-parallel -j 2`. A failing XCTest run is returned as a failure and never triggers a fallback.

On a Command Line Tools installation without XCTest, the script compiles the original core test method bodies into a native assertion runner. It changes only the test superclass and XCTest import in generated copies under `.build/velinshot-core-checks`. The original tests remain untouched. Every supported assertion is checked with a deliberate failure before product scenarios run. Unsupported signatures, async tests, lifecycle methods, conditional compilation and unsupported assertions stop the gate instead of being skipped.

Use `--runner xctest` to require XCTest, or `--runner native` to exercise the fallback explicitly. `--jobs 2` and `--timeout 1200` are the defaults. Run this serially with other heavy builds on the machine. The deadline stops only the process group started by this script.

Logs and source hashes are saved under `.build/core-checks-logs`. A nonzero exit is a failed or unavailable gate. The fallback is not XCTest and provides no XCTest discovery, async, lifecycle or UI-test services. These checks exercise image processing, OCR and persistence; live capture, OS permissions and editor interaction require separate integration checks.
