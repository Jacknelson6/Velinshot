# Core checks on macOS

Run `python3 scripts/core-checks.py` from any directory. Full Xcode uses standard `swift test --no-parallel -j 2`. A failing XCTest run is returned as a failure and never triggers a fallback.

On a Command Line Tools installation without XCTest, the script compiles the original core test method bodies into a native assertion runner. It changes only the test superclass and XCTest import in generated copies under `.build/velinshot-core-checks`. The original tests remain untouched. Every supported assertion is checked with a deliberate failure before product scenarios run. Unsupported signatures, async tests, lifecycle methods, conditional compilation and unsupported assertions stop the gate instead of being skipped.

Use `--runner xctest` to require XCTest, or `--runner native` to exercise the fallback explicitly. `--jobs 2` and `--timeout 1200` are the defaults. Run this serially with other heavy builds on the machine. The deadline stops only the process group started by this script.

Logs and source hashes are saved under `.build/core-checks-logs`. A nonzero exit is a failed or unavailable gate. The fallback is not XCTest and provides no XCTest discovery, async, lifecycle or UI-test services. These checks exercise image processing, OCR and persistence; live capture, OS permissions and editor interaction require separate integration checks.

For isolated diagnosis, use `python3 scripts/checks/run-one.py Suite.testMethod`. It is explicitly separate from the full gate. To measure full-resolution automatic balancing, run `python3 scripts/checks/benchmark-content-bounds.py --label before` and repeat with `--label after` following a change. The benchmark builds a release-only scratch package and reports three timings plus process peak RSS for synthetic 8.85 MP and 33.18 MP images with a single-pixel mark. It measures this function, not total capture latency or idle app memory.

## Actual Sparkle fixture

This is separate from the native assertion gate. It builds a synthetic app with a unique fixture bundle ID and two different executables, using a fixed public RFC test key in a private temporary file. It never uses the production Keychain account or replaces the production app. Preparation performs no launch or publication. Run it only in the serial heavy-build slot after resolving Sparkle:

```sh
python3 scripts/checks/updater-fixture.py prepare .build/updater-fixture \
  --feed-base-url 'https://raw.githubusercontent.com/Jacknelson6/Velinshot/updater-fixture-test/' \
  --download-url-prefix 'https://github.com/Jacknelson6/Velinshot/releases/download/updater-fixture-test/'
```

Use fresh, clearly named staging branch/release URLs for the real run. Preparation creates signed feeds and archives under `assets`, plus deliberately invalid feed/archive cases and a no-update feed. Official Sparkle tools verify the positive signatures and reject the modified bytes. This alone is not a native update pass.

The release owner uploads only the synthetic `assets` files to the corresponding staging HTTPS endpoints, downloads them again and matches `fixture.json` hashes. Do not upload the test private-key file, source copies or local manifest. The normal GitHub TLS chain must be used, with no trust/ATS bypass. The `missing-appcast.xml` endpoint is deliberately absent for the network/error case.

For each scenario, quit the previous fixture first, then prepare the private installed version 1:

```sh
python3 scripts/checks/updater-fixture.py install .build/updater-fixture --scenario valid
```

Open only the printed fixture `.app` path using the approved native app surface. Check for Updates, complete the native download/install/restart, and require actual version 2 launch plus exact executable hash:

```sh
python3 scripts/checks/updater-fixture.py assert .build/updater-fixture --version 2
```

Repeat from version 1 with `--scenario bad-feed` and `--scenario bad-archive`; each must keep version 1 and show Sparkle's signature error. `assert --version 1 --require-error` checks the installed executable and actual SDK error log. Also exercise `no-update`, `offline`, cancellation and retry. Inspect the exact SDK error text so a network failure cannot masquerade as signature refusal.

For busy-work protection, begin an update while idle, open the fixture's synthetic screenshot (or toggle capture/import busy) before accepting Install, then verify `assert --version 1 --require-event relaunchDenied`. Close/clear the work, check again, and prove version 2 installs exactly once. This exercises Sparkle's delegate abort/retry semantics; production busy-state wiring has separate native checks. Fixture events go to the unique temporary JSONL path in `fixture.json`, reset for each installed scenario. No watcher/server/poller is left running.

After quitting the fixture, `python3 scripts/checks/updater-fixture.py cleanup .build/updater-fixture` removes its private apps, test key, archives and event log. Remove the synthetic public staging assets/branch through the authorized release owner's normal cleanup. An ad-hoc fixture does not prove notarized update policy or Screen Recording-consent retention.
