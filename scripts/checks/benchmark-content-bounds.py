#!/usr/bin/env python3
"""Measure release contentBounds time and process peak RSS on synthetic images."""
from pathlib import Path
import argparse
import importlib.util
import json
import shutil
import time

root = Path(__file__).resolve().parents[2]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--label", choices=["before", "after"], required=True)
args = parser.parse_args()
spec = importlib.util.spec_from_file_location("core_checks", root / "scripts/core-checks.py")
checks = importlib.util.module_from_spec(spec)
spec.loader.exec_module(checks)
package = root / ".build/content-bounds-benchmark"
core = package / "Sources/VelinshotCore"
core.mkdir(parents=True, exist_ok=True)
for path in (root / "Sources/VelinshotCore").glob("*.swift"):
    shutil.copy2(path, core / path.name)
checks.write_changed(package / "Sources/Benchmark/main.swift", (root / "scripts/checks/ContentBoundsBenchmark.swift").read_text())
checks.write_changed(package / "Package.swift", '''// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "ContentBoundsBenchmark", platforms: [.macOS(.v14)], targets: [.target(name: "VelinshotCore"), .executableTarget(name: "Benchmark", dependencies: ["VelinshotCore"])], swiftLanguageVersions: [.v5])
''')
stamp = time.time_ns()
logs = root / ".build/core-checks-logs"
logs.mkdir(parents=True, exist_ok=True)
build_log = logs / f"content-bounds-{args.label}-{stamp}-build.log"
with build_log.open("w") as output:
    code = checks.run_bounded(["swift", "build", "-c", "release", "--product", "Benchmark", "-j", "2"], package, output, 1200)
if code:
    print("\n".join(build_log.read_text().splitlines()[-30:]))
    raise SystemExit(code)
binary = package / ".build/release/Benchmark"
for width, height in [(3840, 2304), (7680, 4320)]:
    log = logs / f"content-bounds-{args.label}-{stamp}-{width}x{height}.log"
    with log.open("w") as output:
        code = checks.run_bounded(["/usr/bin/time", "-l", str(binary), str(width), str(height)], package, output, 1200)
    if code:
        print("\n".join(log.read_text().splitlines()[-30:]))
        raise SystemExit(code)
    lines = log.read_text().splitlines()
    report = json.loads(next(line for line in lines if line.startswith("{")))
    print(json.dumps({"label": args.label, **report, "log": str(log)}, sort_keys=True))
print("Build log:", build_log)
