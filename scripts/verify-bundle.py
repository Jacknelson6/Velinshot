#!/usr/bin/env python3
from pathlib import Path
import plistlib, subprocess, sys

bundle=Path(sys.argv[1]).resolve()
info=plistlib.loads((bundle/'Contents/Info.plist').read_bytes())
assert info['CFBundleIdentifier']=='com.jacknelson.velinshot'
assert info['LSMinimumSystemVersion']=='14.0'
assert info['CFBundleExecutable']=='Velinshot'
binary=bundle/'Contents/MacOS/Velinshot'
assert binary.is_file() and binary.stat().st_size>100_000
assert (bundle/'Contents/Resources/AppIcon.icns').stat().st_size>1000
subprocess.run(['codesign','--verify','--deep','--strict',str(bundle)],check=True,capture_output=True)
libraries=subprocess.run(['otool','-L',str(binary)],check=True,capture_output=True,text=True).stdout
for line in libraries.splitlines()[1:]:
 path=line.strip().split(' (',1)[0]
 assert path.startswith(('/System/Library/','/usr/lib/','@rpath/libswift')),f'Unexpected external runtime: {path}'
total=sum(path.stat().st_size for path in bundle.rglob('*') if path.is_file())
print(f'Bundle verified: {total:,} bytes; stable identity, ad-hoc signature, system frameworks only.')
