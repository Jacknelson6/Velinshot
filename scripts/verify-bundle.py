#!/usr/bin/env python3
"""Validate app contents and report the signature that is actually present."""
import argparse
from pathlib import Path
import plistlib
import subprocess

parser = argparse.ArgumentParser()
parser.add_argument('bundle', type=Path)
parser.add_argument('--require-developer-id', action='store_true')
parser.add_argument('--require-notarized', action='store_true')
args = parser.parse_args()
bundle = args.bundle.resolve()

def require(condition, message):
    if not condition:
        raise SystemExit(message)

require(bundle.is_dir(), f'App bundle is missing: {bundle}')
info = plistlib.loads((bundle / 'Contents/Info.plist').read_bytes())
require(info.get('CFBundleIdentifier') == 'com.jacknelson.velinshot', 'Unexpected bundle identifier.')
require(info.get('LSMinimumSystemVersion') == '14.0', 'Unexpected minimum macOS version.')
require(info.get('CFBundleExecutable') == 'Velinshot', 'Unexpected app executable.')
binary = bundle / 'Contents/MacOS/Velinshot'
require(binary.is_file() and binary.stat().st_size > 100_000, 'App executable is missing or incomplete.')
icon = bundle / 'Contents/Resources/AppIcon.icns'
require(icon.is_file() and icon.stat().st_size > 1000, 'App icon is missing or incomplete.')
subprocess.run(['codesign', '--verify', '--deep', '--strict', str(bundle)], check=True, capture_output=True)
signature = subprocess.run(['codesign', '--display', '--verbose=4', str(bundle)],
                           check=True, capture_output=True, text=True).stderr
developer_id = 'Authority=Developer ID Application:' in signature
signature_kind = 'Developer ID' if developer_id else ('ad-hoc' if 'Signature=adhoc' in signature else 'other')
if args.require_developer_id or args.require_notarized:
    require(developer_id, 'This operation requires a Developer ID Application signature.')
    require('(runtime)' in signature and 'Timestamp=' in signature,
            'Developer ID distribution requires hardened runtime and a secure timestamp.')
if args.require_notarized:
    subprocess.run(['xcrun', 'stapler', 'validate', str(bundle)], check=True, capture_output=True)
    subprocess.run(['spctl', '--assess', '--type', 'execute', str(bundle)], check=True, capture_output=True)
libraries = subprocess.run(['otool', '-L', str(binary)], check=True, capture_output=True, text=True).stdout
for line in libraries.splitlines()[1:]:
    path = line.strip().split(' (', 1)[0]
    require(path.startswith(('/System/Library/', '/usr/lib/', '@rpath/libswift')),
            f'Unexpected external runtime: {path}')
total = sum(path.stat().st_size for path in bundle.rglob('*') if path.is_file())
trust = '; notarization and Gatekeeper verified' if args.require_notarized else '; notarization not checked'
print(f'Bundle verified: {total:,} bytes; stable identity, {signature_kind} signature, system frameworks only{trust}.')
