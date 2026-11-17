#!/usr/bin/env python3
"""Pinned Sparkle embedding and bundle checks shared by local release scripts."""
from pathlib import Path
import argparse
import base64
from collections import Counter
import json
import plistlib
import re
import shutil
import subprocess
import tempfile

SPARKLE_VERSION = '2.10.1'
SPARKLE_INSTALL_NAME = '@rpath/Sparkle.framework/Versions/B/Sparkle'
PRODUCTION_FEED = 'https://raw.githubusercontent.com/Jacknelson6/Velinshot/updates/appcast.xml'
KEYCHAIN_ACCOUNT = 'com.jacknelson.velinshot.ed25519'
ROOT = Path(__file__).resolve().parents[1]
FIXTURE_PUBLIC_KEY = base64.b64decode('11qYAYKxCrfVS/7TyWQHOg7hcvPapiMlrwIaaPcHURo=', validate=True)

def require(condition, message):
    if not condition:
        raise SystemExit(message)

def command(*arguments):
    return subprocess.run(list(map(str, arguments)), check=True, capture_output=True, text=True, timeout=60)

def distribution():
    artifacts = ROOT / '.build/artifacts'
    candidates = list(artifacts.glob('**/macos-arm64_x86_64/Sparkle.framework'))
    require(len(candidates) == 1, 'Resolve pinned Sparkle with swift package resolve before building the app.')
    framework = candidates[0]
    info = plistlib.loads((framework / 'Resources/Info.plist').read_bytes())
    require(info.get('CFBundleShortVersionString') == SPARKLE_VERSION, 'Unexpected Sparkle framework version.')
    tools = framework.parents[2] / 'bin'
    require((tools / 'generate_appcast').is_file() and (tools / 'sign_update').is_file(), 'Sparkle release tools are missing.')
    return framework, tools

def rpaths(binary):
    lines = command('otool', '-l', binary).stdout.splitlines()
    result = []
    for index, line in enumerate(lines):
        if line.strip() == 'cmd LC_RPATH':
            value = lines[index + 2].strip()
            require(value.startswith('path ') and ' (offset ' in value, 'Cannot read a Mach-O runpath.')
            result.append(value[5:].split(' (offset ', 1)[0])
    return result

def sign(target, identity, preserve_entitlements=False):
    arguments = ['codesign', '--force', '--sign', identity or '-']
    if identity:
        arguments += ['--options', 'runtime', '--timestamp']
    if preserve_entitlements:
        arguments += ['--preserve-metadata=entitlements']
    command(*arguments, target)

def framework_targets(framework):
    version = framework / 'Versions/B'
    return [
        (version / 'XPCServices/Installer.xpc', False),
        (version / 'XPCServices/Downloader.xpc', True),
        (version / 'Autoupdate', False),
        (version / 'Updater.app', False),
        (framework, False),
    ]

def embed(bundle, identity):
    framework, _ = distribution()
    destination = bundle / 'Contents/Frameworks/Sparkle.framework'
    destination.parent.mkdir(parents=True, exist_ok=True)
    if destination.exists():
        shutil.rmtree(destination)
    command('ditto', framework, destination)
    binary = bundle / 'Contents/MacOS/Velinshot'
    for runpath in rpaths(binary):
        if runpath.startswith('/') and not runpath.startswith(('/usr/lib/', '/System/Library/')):
            command('install_name_tool', '-delete_rpath', runpath, binary)
    if '@executable_path/../Frameworks' not in rpaths(binary):
        command('install_name_tool', '-add_rpath', '@executable_path/../Frameworks', binary)
    for target, preserve in framework_targets(destination):
        sign(target, identity, preserve)
    notices = bundle / 'Contents/Resources/ThirdPartyNotices'
    notices.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(ROOT / 'Resources/ThirdPartyNotices/Sparkle-LICENSE', notices / 'Sparkle-LICENSE')

def update_configuration(info):
    require(info.get('SUFeedURL') == PRODUCTION_FEED, 'Unexpected production update feed.')
    try:
        key = base64.b64decode(info.get('SUPublicEDKey', ''), validate=True)
    except (ValueError, TypeError):
        key = b''
    require(len(key) == 32 and any(key), 'A real app-scoped Sparkle public key is required before release.')
    require(key != FIXTURE_PUBLIC_KEY, 'The public RFC test key cannot authorize a production release.')
    for flag in ('SURequireSignedFeed', 'SUVerifyUpdateBeforeExtraction'):
        require(info.get(flag) is True, f'{flag} must be enabled.')
    expiry = info.get('SUSignedFeedFailureExpirationInterval')
    require(type(expiry) is int and expiry == 0, 'Signed-feed expiry must be integer zero, not a boolean or float.')
    for flag in ('SUEnableSystemProfiling', 'SUAutomaticallyUpdate', 'SUAllowsAutomaticUpdates', 'SUEnableAutomaticChecks', 'SUEnableJavaScript', 'SUShowReleaseNotes'):
        require(info.get(flag) is False, f'{flag} must be disabled.')
    return key

def verify_production_binary(binary):
    code = binary.read_bytes()
    markers = (b'com.jacknelson.velinshot.update-fixture.', b'VelinshotFixtureRunID', b'onFixtureEvent')
    require(not any(marker in code for marker in markers), 'A fixture-enabled executable cannot be released as the production app.')

def require_fresh_output(output):
    require(not output.exists() or (output.is_dir() and not any(output.iterdir())),
            'Use a fresh empty appcast output directory and pass the prior feed separately.')
    output.mkdir(parents=True, exist_ok=True)

def enclosure_snapshot(tree):
    namespace = {'sparkle': 'http://www.andymatuschak.org/xml-namespaces/sparkle'}
    records = []
    for item in tree.findall('.//item'):
        enclosure = item.find('enclosure')
        records.append(json.dumps({'version': item.findtext('sparkle:version', namespaces=namespace),
                                   'enclosure': None if enclosure is None else dict(enclosure.attrib)}, sort_keys=True))
    return Counter(records)

def require_preserved_enclosures(previous, generated):
    require(not (previous - generated), 'Appcast generation changed or removed a previous enclosure URL, length or signature.')

def fixture_paths(directory, manifest):
    directory = directory.resolve()
    private_parent = directory.parent in ((ROOT / '.build').resolve(), Path(tempfile.gettempdir()).resolve())
    valid_name = directory.name == 'updater-fixture' or directory.name.startswith(('updater-fixture-', 'velinshot-updater-fixture-'))
    require(private_parent and valid_name, 'Fixture operations are limited to the expected private fixture parent.')
    run = manifest.get('run')
    require(isinstance(run, str) and re.fullmatch('[0-9a-f]{32}', run), 'Unexpected fixture run identifier.')
    identifier = 'com.jacknelson.velinshot.update-fixture.' + run
    require(manifest.get('bundleIdentifier') == identifier, 'Unexpected fixture preference domain.')
    installed = Path(manifest['installed'])
    expected_install = directory / 'installed/VelinshotUpdaterFixture.app'
    require(installed == expected_install and installed.resolve().is_relative_to(directory), 'Fixture install path escapes its private directory.')
    record = Path(manifest['recordPath'])
    expected_name = 'VelinshotUpdaterFixture-' + run + '.jsonl'
    require(record.name == expected_name and record.parent.resolve() == Path(tempfile.gettempdir()).resolve() and not record.is_symlink(),
            'Fixture event log must be its own direct temporary file.')
    cache = Path.home() / 'Library/Caches' / identifier
    require(not cache.is_symlink(), 'Fixture cache must not be a symlink.')
    return installed, record, cache

def validate_release_item(item, info, architecture):
    namespace = {'sparkle': 'http://www.andymatuschak.org/xml-namespaces/sparkle'}
    require(item.findtext('sparkle:minimumSystemVersion', namespaces=namespace) == info['LSMinimumSystemVersion'],
            'Appcast minimum macOS version does not match the archived app.')
    if architecture == 'arm64':
        require(item.findtext('sparkle:hardwareRequirements', namespaces=namespace) == 'arm64',
                'An Apple Silicon-only archive must require arm64 in the appcast.')

def linkage(binary, bundle):
    lines = command('otool', '-L', binary).stdout.splitlines()
    dependencies = [line.strip().split(' (', 1)[0] for line in lines if line.startswith('\t')]
    for dependency in dependencies:
        system = dependency.startswith(('/System/Library/', '/usr/lib/'))
        swift = dependency.startswith('@rpath/libswift') and dependency.endswith('.dylib') and '/' not in dependency[len('@rpath/'):]
        require(system or swift or dependency == SPARKLE_INSTALL_NAME,
                f'Unexpected external runtime for {binary.name}: {dependency}')
    for runpath in rpaths(binary):
        if runpath.startswith(('/System/Library/', '/usr/lib/')):
            continue
        require(runpath.startswith(('@loader_path', '@executable_path')), f'Unexpected runpath: {runpath}')
        executable_directory = bundle / 'Contents/MacOS' if binary.name == 'Sparkle' else binary.parent
        resolved = runpath.replace('@loader_path', str(binary.parent)).replace('@executable_path', str(executable_directory))
        require(Path(resolved).resolve().is_relative_to(bundle.resolve()), f'Runpath escapes the app bundle: {runpath}')
    return dependencies

def verify_framework(bundle, require_developer_id=False):
    framework = bundle / 'Contents/Frameworks/Sparkle.framework'
    require(framework.is_dir(), 'Embedded Sparkle.framework is missing.')
    require((framework / 'Versions/Current').is_symlink() and (framework / 'Sparkle').is_symlink(), 'Sparkle framework symlinks were not preserved.')
    for entry in framework.rglob('*'):
        if entry.is_symlink():
            require(entry.resolve().is_relative_to(framework.resolve()), 'Sparkle symlink escapes its framework.')
    info = plistlib.loads((framework / 'Resources/Info.plist').read_bytes())
    require(info.get('CFBundleShortVersionString') == SPARKLE_VERSION, 'Embedded Sparkle version is not pinned.')
    binaries = [framework / 'Versions/B/Sparkle']
    outer_signature = command('codesign', '--display', '--verbose=4', bundle).stderr
    outer_team = next((line for line in outer_signature.splitlines() if line.startswith('TeamIdentifier=')), None)
    for target, _ in framework_targets(framework):
        require(target.exists(), f'Sparkle helper is missing: {target.name}')
        command('codesign', '--verify', '--deep', '--strict', target)
        details = command('codesign', '--display', '--verbose=4', target).stderr
        if 'Signature=adhoc' in outer_signature:
            require('Signature=adhoc' in details, f'Sparkle component does not match the ad-hoc app signature: {target.name}')
        if require_developer_id:
            require('Authority=Developer ID Application:' in details and '(runtime)' in details and 'Timestamp=' in details,
                    f'Sparkle component is not ready for Developer ID distribution: {target.name}')
            require(outer_team and outer_team in details.splitlines(), f'Sparkle component uses a different signing team: {target.name}')
        if target.suffix in ('.app', '.xpc'):
            helper_info = plistlib.loads((target / 'Contents/Info.plist').read_bytes())
            binaries.append(target / 'Contents/MacOS' / helper_info['CFBundleExecutable'])
        elif target.name == 'Autoupdate':
            binaries.append(target)
    for binary in binaries:
        linkage(binary, bundle)
    app_dependencies = linkage(bundle / 'Contents/MacOS/Velinshot', bundle)
    require(SPARKLE_INSTALL_NAME in app_dependencies, 'The app is not linked to embedded Sparkle.')
    require('@executable_path/../Frameworks' in rpaths(bundle / 'Contents/MacOS/Velinshot'), 'Embedded framework runpath is missing.')
    require((bundle / 'Contents/Resources/ThirdPartyNotices/Sparkle-LICENSE').is_file(), 'Sparkle license notices are missing.')

if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('action', choices=['embed', 'tools'])
    parser.add_argument('bundle', nargs='?', type=Path)
    parser.add_argument('--identity', default='')
    arguments = parser.parse_args()
    if arguments.action == 'tools':
        print(distribution()[1])
    else:
        require(arguments.bundle is not None, 'An app bundle is required.')
        embed(arguments.bundle.resolve(), arguments.identity)
