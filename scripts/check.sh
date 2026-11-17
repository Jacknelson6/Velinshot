#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
python3 scripts/core-checks.py
python3 scripts/checks/check-update-metadata.py
bash scripts/build-app.sh
build/Velinshot.app/Contents/MacOS/Velinshot --smoke-check .build/integration-checks
python3 scripts/verify-bundle.py build/Velinshot.app
