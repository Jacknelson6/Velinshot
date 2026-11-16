#!/usr/bin/env python3
"""Run normal XCTest on full Xcode, or the same scenarios with CLT-only Swift.

The native fallback is a small assertion runner, not XCTest. It preserves the
test method bodies, rejects unsupported XCTest features, and never falls back
after a real XCTest failure. Run serially with other builds on the machine.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import signal
import subprocess
import sys
import time


ROOT = Path(__file__).resolve().parents[1]
SUPPORTED_ASSERTIONS = {
    "XCTAssertEqual", "XCTAssertTrue", "XCTAssertFalse", "XCTAssertNil",
    "XCTAssertGreaterThan", "XCTAssertLessThan", "XCTAssertLessThanOrEqual",
    "XCTAssertThrowsError", "XCTAssertNoThrow", "XCTUnwrap",
}


def write_changed(path: Path, content: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    if not path.exists() or path.read_text() != content:
        path.write_text(content)


def full_xcode_has_xctest() -> bool:
    result = subprocess.run(["xcode-select", "-p"], capture_output=True, text=True)
    if result.returncode:
        return False
    developer = Path(result.stdout.strip())
    return any(path.exists() for path in [
        developer / "Platforms/MacOSX.platform/Developer/Library/Frameworks/XCTest.framework",
        developer / "Library/Frameworks/XCTest.framework",
    ])


def run_bounded(command: list[str], cwd: Path, output, timeout: int) -> int:
    process = subprocess.Popen(command, cwd=cwd, stdout=output, stderr=subprocess.STDOUT,
                               text=True, start_new_session=True)
    try:
        return process.wait(timeout=timeout)
    except (subprocess.TimeoutExpired, KeyboardInterrupt) as error:
        # The group belongs to the child launched above. Stop its compiler
        # descendants too, without touching other sessions' build processes.
        try:
            os.killpg(process.pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
        try:
            process.wait(timeout=10)
        except subprocess.TimeoutExpired:
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            process.wait()
        if isinstance(error, KeyboardInterrupt):
            raise
        return 124


def prepare_native_package() -> tuple[Path, int, dict[str, str]]:
    package = ROOT / ".build/velinshot-core-checks"
    core = package / "Sources/VelinshotCore"
    checks = package / "Sources/CoreChecks"
    core.mkdir(parents=True, exist_ok=True)
    checks.mkdir(parents=True, exist_ok=True)
    hashes: dict[str, str] = {}
    core_names: set[Path] = set()
    for original in sorted((ROOT / "Sources/VelinshotCore").rglob("*.swift")):
        relative = original.relative_to(ROOT / "Sources/VelinshotCore")
        destination = core / relative
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(original, destination)
        core_names.add(destination)
        hashes[str(original.relative_to(ROOT))] = hashlib.sha256(original.read_bytes()).hexdigest()
    if not core_names:
        raise ValueError("No VelinshotCore sources found.")
    cases: list[tuple[str, str, bool]] = []
    check_names: set[Path] = set()
    for original in sorted((ROOT / "Tests/VelinshotCoreTests").rglob("*.swift")):
        content = original.read_text()
        suites = re.findall(r"final\s+class\s+(\w+)\s*:\s*XCTestCase\b", content)
        declarations = re.findall(r"\bfunc\s+(test\w+)\s*\(", content)
        methods = re.findall(r"\bfunc\s+(test\w+)\s*\(\s*\)\s*(throws\s*)?\{", content)
        calls = set(re.findall(r"\b(XCT\w+)\s*\(", content))
        forbidden = re.search(r"\b(setUp|tearDown|expectation|waitForExpectations|measure)\s*\(|\basync\b|#if|#elseif|@available", content)
        if (len(suites) != 1 or sorted(declarations) != sorted(name for name, _ in methods)
                or calls - SUPPORTED_ASSERTIONS or forbidden):
            raise ValueError(f"Unsupported XCTest construct in {original.relative_to(ROOT)}. Use --runner xctest; no scenarios were skipped.")
        suite = suites[0]
        cases.extend((suite, name, bool(throwing)) for name, throwing in methods)
        transformed = re.sub(r"^\s*import XCTest\s*$", "", content, flags=re.MULTILINE)
        transformed = re.sub(r":\s*XCTestCase\b", ": CoreCheckSuite", transformed)
        destination = checks / original.relative_to(ROOT / "Tests/VelinshotCoreTests")
        write_changed(destination, "import Foundation\n" + transformed)
        check_names.add(destination)
        hashes[str(original.relative_to(ROOT))] = hashlib.sha256(original.read_bytes()).hexdigest()
    if not cases or len({(suite, name) for suite, name, _ in cases}) != len(cases):
        raise ValueError("No unique test scenarios found. Refusing an empty or ambiguous gate.")
    support = ROOT / "scripts/checks/LocalAssertions.swift"
    write_changed(checks / "LocalAssertions.swift", support.read_text())
    check_names.add(checks / "LocalAssertions.swift")
    hashes[str(support.relative_to(ROOT))] = hashlib.sha256(support.read_bytes()).hexdigest()
    calls = ",\n".join(
        f'    ("{suite}.{name}", {{ {"try " if throwing else ""}{suite}().{name}() }})'
        for suite, name, throwing in cases
    )
    main = r'''import Foundation
verifyLocalAssertions()
let cases: [(String, () throws -> Void)] = [
''' + calls + r'''
]
let started = ProcessInfo.processInfo.systemUptime
for (name, operation) in cases {
    let before = CheckLedger.failures.count
    do { try operation() } catch { CheckLedger.failures.append("\(name): threw \(error)") }
    print("\(CheckLedger.failures.count == before ? "PASS" : "FAIL") \(name)")
}
print("Executed \(cases.count) source scenarios using the native assertion runner, \(CheckLedger.failures.count) failures, \(ProcessInfo.processInfo.systemUptime - started) seconds. This is not XCTest.")
for failure in CheckLedger.failures { print("CHECK FAILURE: \(failure)") }
exit(CheckLedger.failures.isEmpty ? 0 : 1)
'''
    write_changed(checks / "main.swift", main)
    check_names.add(checks / "main.swift")
    # Remove stale generated Swift files only, so a deleted test/core file cannot
    # keep participating in a later run. Build caches remain intact.
    for directory, wanted in [(core, core_names), (checks, check_names)]:
        for stale in directory.rglob("*.swift"):
            if stale not in wanted:
                stale.unlink()
    write_changed(package / "Package.swift", '''// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "CoreChecks", platforms: [.macOS(.v14)], targets: [.target(name: "VelinshotCore"), .executableTarget(name: "CoreChecks", dependencies: ["VelinshotCore"])], swiftLanguageVersions: [.v5])
''')
    return package, len(cases), hashes


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--runner", choices=["auto", "xctest", "native"], default="auto")
    parser.add_argument("--jobs", type=int, default=2, choices=range(1, 9))
    parser.add_argument("--timeout", type=int, default=1200, help="Command deadline in seconds (default 1200).")
    args = parser.parse_args()
    if sys.platform != "darwin":
        parser.error("Velinshot requires macOS system frameworks.")
    if args.timeout < 1:
        parser.error("--timeout must be positive.")
    runner = args.runner
    if runner == "auto":
        runner = "xctest" if full_xcode_has_xctest() else "native"
    hashes: dict[str, str] = {}
    count = None
    if runner == "xctest":
        cwd = ROOT
        command = ["swift", "test", "--no-parallel", "-j", str(args.jobs)]
        print("Using standard XCTest. A failing gate will not trigger a fallback.", flush=True)
    else:
        cwd, count, hashes = prepare_native_package()
        command = ["swift", "run", "-j", str(args.jobs), "CoreChecks"]
        print(f"Using the native assertion runner for all {count} source scenarios. This is not XCTest.", flush=True)
    logs = ROOT / ".build/core-checks-logs"
    logs.mkdir(parents=True, exist_ok=True)
    log = logs / f"{runner}-{time.time_ns()}.log"
    started = time.monotonic()
    with log.open("w") as output:
        exit_code = run_bounded(command, cwd, output, args.timeout)
    if exit_code == 124:
        print(f"The {args.timeout}-second deadline was exceeded.", file=sys.stderr)
    lines = log.read_text().splitlines()
    selected = [line for line in lines if any(token in line for token in ["error:", "warning:", "failed", "Executed ", "Build complete", "CHECK FAILURE:", "FAIL "])]
    print("\n".join((selected or lines)[-60:]))
    print(f"Exit {exit_code}; elapsed {time.monotonic() - started:.2f}s; full log: {log}")
    log.with_suffix(".json").write_text(json.dumps({"runner": runner, "command": command, "scenarioCount": count,
        "exitCode": exit_code, "sourceSHA256": hashes}, indent=2) + "\n")
    return exit_code if exit_code >= 0 else 1


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ValueError) as error:
        print(f"core-checks: {error}", file=sys.stderr)
        raise SystemExit(1)
