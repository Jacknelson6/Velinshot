#!/usr/bin/env python3
"""Run one native core scenario for diagnosis. This is never the full gate."""
from pathlib import Path
import importlib.util
import re
import sys
import time

root = Path(__file__).resolve().parents[2]
if len(sys.argv) != 2 or not re.fullmatch(r"\w+\.test\w+", sys.argv[1]):
    raise SystemExit("Usage: python3 scripts/checks/run-one.py Suite.testMethod")
suite, method = sys.argv[1].split(".")
spec = importlib.util.spec_from_file_location("core_checks", root / "scripts/core-checks.py")
checks = importlib.util.module_from_spec(spec)
spec.loader.exec_module(checks)
package, _, _ = checks.prepare_native_package()
test_source = "\n".join(path.read_text() for path in (package / "Sources/CoreChecks").glob("*.swift"))
if f"class {suite}: CoreCheckSuite" not in test_source or f"func {method}()" not in test_source:
    raise SystemExit("Scenario not found; no test was run.")
main = r'''import Foundation
verifyLocalAssertions()
do { try SUITE_CALL } catch { CheckLedger.failures.append("Unexpected error: \(error)") }
print("Diagnostic scenario CASE_NAME: \(CheckLedger.failures.count) failures. This is not the full gate.")
for failure in CheckLedger.failures { print("CHECK FAILURE: \(failure)") }
exit(CheckLedger.failures.isEmpty ? 0 : 1)
'''.replace("SUITE_CALL", f"{suite}().{method}()").replace("CASE_NAME", sys.argv[1])
checks.write_changed(package / "Sources/CoreChecks/main.swift", main)
log = root / ".build/core-checks-logs" / f"diagnostic-{time.time_ns()}.log"
log.parent.mkdir(parents=True, exist_ok=True)
with log.open("w") as output:
    code = checks.run_bounded(["swift", "run", "-j", "2", "CoreChecks"], package, output, 1200)
lines = log.read_text().splitlines()
selected = [line for line in lines if any(token in line for token in ["error:", "Diagnostic scenario", "Validated ", "CHECK FAILURE:"])]
print("\n".join(selected[-40:]))
print(f"Exit {code}; full log: {log}")
raise SystemExit(code)
