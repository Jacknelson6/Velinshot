#!/usr/bin/env python3
"""Finite release benchmark. Fresh process means app cache cold, never purged OS cache."""
from pathlib import Path
import argparse, importlib.util, json, shutil, time

root = Path(__file__).resolve().parents[2]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--mode", choices=["baseline", "prepared"], required=True)
args = parser.parse_args()
spec = importlib.util.spec_from_file_location("core_checks", root / "scripts/core-checks.py")
checks = importlib.util.module_from_spec(spec); spec.loader.exec_module(checks)
package = root / ".build/pipeline-benchmark"
core = package / "Sources/VelinshotCore"; core.mkdir(parents=True, exist_ok=True)
for path in (root / "Sources/VelinshotCore").glob("*.swift"):
    shutil.copy2(path, core / path.name)
checks.write_changed(package / "Sources/Benchmark/main.swift", (root / "scripts/checks/PipelineBenchmark.swift").read_text())
define = '[.define("PREPARED_IMAGE_PIPELINE")]' if args.mode == "prepared" else '[]'
checks.write_changed(package / "Package.swift", '''// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "PipelineBenchmark", platforms: [.macOS(.v14)], targets: [.target(name: "VelinshotCore"), .executableTarget(name: "Benchmark", dependencies: ["VelinshotCore"], swiftSettings: ''' + define + ''')], swiftLanguageVersions: [.v5])
''')
logs = root / ".build/core-checks-logs"; logs.mkdir(parents=True, exist_ok=True)
stamp = time.time_ns(); buildlog = logs / f"pipeline-{args.mode}-{stamp}-build.log"
with buildlog.open("w") as output:
    code = checks.run_bounded(["swift", "build", "-c", "release", "--product", "Benchmark", "-j", "2"], package, output, 1200)
if code:
    print("\n".join(buildlog.read_text().splitlines()[-35:])); raise SystemExit(code)
binary = package / ".build/release/Benchmark"
fixtures = root / ".build/pipeline-fixtures"; fixtures.mkdir(parents=True, exist_ok=True)
cases = [(w, h, "ui-thin", ext) for w, h in [(64, 48), (1600, 1000), (3840, 2304), (7680, 4320)] for ext in ["png", "jpg", "heic"]]
cases += [(7680, 4320, "noise", ext) for ext in ["png", "jpg", "heic"]] + [(3840, 2304, "alpha", "png")]
reports = []
for width, height, kind, ext in cases:
    path = fixtures / f"{width}x{height}-{kind}.{ext}"
    if not path.exists():
        fixturelog = logs / f"pipeline-fixture-{width}x{height}-{kind}-{ext}.log"
        with fixturelog.open("w") as output:
            code = checks.run_bounded([str(binary), "fixture", str(path), str(width), str(height), kind, "synthetic"], package, output, 300)
        if code:
            print(f"Fixture unavailable: {path.name}, exit {code}, log {fixturelog}")
            continue
    log = logs / f"pipeline-{args.mode}-{stamp}-{path.name}.log"
    with log.open("w") as output:
        code = checks.run_bounded([str(binary), "run", str(path)], package, output, 300)
    if code:
        print("\n".join(log.read_text().splitlines()[-20:])); raise SystemExit(code)
    rows = [json.loads(line) for line in log.read_text().splitlines() if line.startswith("{")]
    reports.extend(rows)
    print(path.name, "prepare ms", "/".join(str(round(row["preparationMs"], 1)) for row in rows),
          "peak MiB", round(max(row["peakPreparationRSSBytes"] for row in rows) / 1048576, 1), flush=True)
summary = logs / f"pipeline-{args.mode}-{stamp}.json"
summary.write_text(json.dumps({"mode": args.mode, "configuration": "release", "reports": reports,
    "limitations": "Finite synthetic fixtures; app-cache cold then same-process repeat; OS cache uncontrolled; no GUI paint or OS capture measured."}, indent=2) + "\n")
print("REPORT", summary)
