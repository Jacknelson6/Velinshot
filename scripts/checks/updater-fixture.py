#!/usr/bin/env python3
"""Prepare and inspect a private Sparkle fixture. Preparation never launches or publishes."""
import argparse
import base64
import hashlib
import json
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile
from urllib.parse import urlparse
import uuid
import xml.etree.ElementTree as ET

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from sparkle_support import PRODUCTION_FEED, ROOT, command, distribution, embed, require, validate_release_item, fixture_paths

parser = argparse.ArgumentParser()
parser.add_argument('action', choices=['prepare', 'install', 'assert', 'cleanup'])
parser.add_argument('directory', type=Path)
parser.add_argument('--feed-base-url')
parser.add_argument('--download-url-prefix')
parser.add_argument('--scenario', choices=['valid', 'bad-feed', 'bad-archive', 'no-update', 'offline'], default='valid')
parser.add_argument('--version', choices=['1', '2'])
parser.add_argument('--require-event')
parser.add_argument('--require-error', action='store_true')
args = parser.parse_args()
directory = args.directory.resolve()
manifest_path = directory / 'fixture.json'
namespace = {'sparkle': 'http://www.andymatuschak.org/xml-namespaces/sparkle'}
scenarios = {'valid': 'appcast.xml', 'bad-feed': 'appcast-bad-feed.xml', 'bad-archive': 'appcast-bad-archive.xml', 'no-update': 'appcast-no-update.xml', 'offline': 'missing-appcast.xml'}

def digest(file):
    return hashlib.sha256(file.read_bytes()).hexdigest()

def tool_run(*arguments, expected=0):
    result = subprocess.run(list(map(str, arguments)), capture_output=True, text=True, timeout=300)
    if expected == 0:
        require(result.returncode == 0, result.stdout[-1000:] + result.stderr[-1000:])
    else:
        require(result.returncode != 0, 'A deliberately corrupted signature was accepted.')
    return result

def stopped(manifest):
    record = Path(manifest['recordPath'])
    if record.exists():
        for line in record.read_text().splitlines():
            event = json.loads(line)
            if event.get('event') != 'launch':
                continue
            process = subprocess.run(['ps', '-p', str(event['pid']), '-o', 'args='], capture_output=True, text=True).stdout.strip()
            require(not process or str(directory) not in process, 'Quit the synthetic fixture before replacing or cleaning it.')

if args.action == 'prepare':
    require(args.feed_base_url and args.download_url_prefix, 'Provide HTTPS fixture feed and archive staging prefixes.')
    for value in (args.feed_base_url, args.download_url_prefix):
        parsed = urlparse(value)
        require(parsed.scheme == 'https' and parsed.hostname in ('raw.githubusercontent.com', 'github.com'), 'Fixture URLs must use trusted GitHub HTTPS.')
        staging = parsed.path.startswith('/Jacknelson6/Velinshot/updater-fixture-') or parsed.path.startswith('/Jacknelson6/Velinshot/releases/download/updater-fixture-')
        require(staging and not parsed.username and not parsed.password and not parsed.query and not parsed.fragment, 'Use the Velinshot synthetic staging namespace, never the production feed.')
    require(not directory.exists(), 'Prepare a fresh private fixture directory.')
    directory.mkdir(parents=True, mode=0o700)
    run = uuid.uuid4().hex
    framework, tools = distribution()
    # Public RFC 8032 test vector, never a production credential or Keychain item.
    seed = bytes.fromhex('9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60')
    public = base64.b64encode(bytes.fromhex('d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a')).decode()
    key_file = directory / 'TEST-ONLY-KEY.txt'; key_file.write_text(base64.b64encode(seed).decode() + '\n'); key_file.chmod(0o600)
    assets = directory / 'assets'; assets.mkdir()
    fixture_main = directory / 'main.swift'
    shutil.copy2(ROOT / 'scripts/checks/UpdaterFixture.swift', fixture_main)
    hashes = {}
    for version in ['1', '2']:
        bundle = directory / ('version-' + version) / 'VelinshotUpdaterFixture.app'
        (bundle / 'Contents/MacOS').mkdir(parents=True)
        info = {'CFBundleName': 'VelinshotUpdaterFixture', 'CFBundleDisplayName': 'Velinshot Update Fixture',
                'CFBundleIdentifier': 'com.jacknelson.velinshot.update-fixture.' + run, 'CFBundleExecutable': 'Velinshot',
                'CFBundlePackageType': 'APPL', 'CFBundleVersion': version, 'CFBundleShortVersionString': version + '.0',
                'LSMinimumSystemVersion': '14.0', 'NSPrincipalClass': 'NSApplication', 'VelinshotFixtureRunID': run,
                'SUFeedURL': args.feed_base_url.rstrip('/') + '/appcast.xml', 'SUPublicEDKey': public,
                'SURequireSignedFeed': True, 'SUVerifyUpdateBeforeExtraction': True,
                'SUSignedFeedFailureExpirationInterval': 0, 'SUEnableAutomaticChecks': False,
                'SUEnableSystemProfiling': False, 'SUAutomaticallyUpdate': False, 'SUAllowsAutomaticUpdates': False,
                'SUShowReleaseNotes': False, 'SUEnableJavaScript': False}
        (bundle / 'Contents/Info.plist').write_bytes(plistlib.dumps(info))
        binary = bundle / 'Contents/MacOS/Velinshot'
        compiler = ['swiftc', '-swift-version', '5', '-O', '-D', 'VELINSHOT_UPDATER_FIXTURE', '-framework', 'AppKit', '-framework', 'Sparkle', '-F', str(framework.parent),
                    '-Xlinker', '-rpath', '-Xlinker', '@executable_path/../Frameworks']
        if version == '2': compiler += ['-D', 'VELINSHOT_UPDATER_FIXTURE_NEW']
        tool_run(*compiler, ROOT / 'Sources/Velinshot/UpdaterController.swift', fixture_main, '-o', binary)
        embed(bundle, '')
        command('codesign', '--force', '--sign', '-', bundle)
        command('codesign', '--verify', '--deep', '--strict', bundle)
        hashes[version] = digest(binary)
        command('ditto', '-c', '-k', '--sequesterRsrc', '--keepParent', bundle, assets / ('VelinshotUpdaterFixture-' + version + '.zip'))
    feed = assets / 'appcast.xml'
    tool_run(tools / 'generate_appcast', '--ed-key-file', key_file, '--download-url-prefix', args.download_url_prefix.rstrip('/') + '/', '--maximum-deltas', '0', '-o', feed, assets)
    tool_run(tools / 'sign_update', '--ed-key-file', key_file, '--verify', feed)
    architecture = command('lipo', '-archs', directory / 'version-2/VelinshotUpdaterFixture.app/Contents/MacOS/Velinshot').stdout.strip().replace(' ', '_')
    for generated_item in ET.parse(feed).findall('.//item'):
        validate_release_item(generated_item, info, architecture)
    corrupt_feed = assets / 'appcast-bad-feed.xml'; corrupt_feed.write_bytes(feed.read_bytes().replace(b'<title>', b'<title>Altered ', 1))
    tool_run(tools / 'sign_update', '--ed-key-file', key_file, '--verify', corrupt_feed, expected=1)
    update = assets / 'VelinshotUpdaterFixture-2.zip'
    corrupt = bytearray(update.read_bytes()); corrupt[len(corrupt)//2] ^= 1
    corrupt_archive = assets / 'VelinshotUpdaterFixture-2-tampered.zip'; corrupt_archive.write_bytes(corrupt)
    enclosure = next(item.find('enclosure') for item in ET.parse(feed).findall('.//item') if item.findtext('sparkle:version', namespaces=namespace) == '2')
    signature = enclosure.get('{'+namespace['sparkle']+'}edSignature')
    tool_run(tools / 'sign_update', '--ed-key-file', key_file, '--verify', corrupt_archive, signature, expected=1)
    bad_archive_feed = assets / 'appcast-bad-archive.xml'
    bad_archive_feed.write_bytes(feed.read_bytes().replace(b'VelinshotUpdaterFixture-2.zip', b'VelinshotUpdaterFixture-2-tampered.zip'))
    tool_run(tools / 'sign_update', '--ed-key-file', key_file, bad_archive_feed)
    tool_run(tools / 'sign_update', '--ed-key-file', key_file, '--verify', bad_archive_feed)
    no_update = directory / 'no-update'; no_update.mkdir(); shutil.copy2(assets / 'VelinshotUpdaterFixture-1.zip', no_update)
    tool_run(tools / 'generate_appcast', '--ed-key-file', key_file, '--download-url-prefix', args.download_url_prefix.rstrip('/') + '/', '--maximum-deltas', '0', '-o', no_update / 'appcast.xml', no_update)
    shutil.copy2(no_update / 'appcast.xml', assets / 'appcast-no-update.xml')
    manifest = {'fixture': True, 'run': run, 'bundleIdentifier': info['CFBundleIdentifier'], 'hashes': hashes,
                'feedBaseURL': args.feed_base_url.rstrip('/'), 'installed': str(directory / 'installed/VelinshotUpdaterFixture.app'),
                'recordPath': str(Path(tempfile.gettempdir()) / ('VelinshotUpdaterFixture-' + run + '.jsonl')),
                'assets': {file.name: digest(file) for file in assets.iterdir() if file.is_file()}}
    manifest_path.write_text(json.dumps(manifest, indent=2) + '\n')
    print('Prepared signed synthetic fixture; no launch or public write:', directory)
else:
    manifest = json.loads(manifest_path.read_text()); require(manifest.get('fixture') is True, 'Not a recognized fixture directory.')
    installed, record, fixture_cache = fixture_paths(directory, manifest)
    if args.action == 'install':
        stopped(manifest)
        source_bundle = directory / 'version-1/VelinshotUpdaterFixture.app'
        require(digest(source_bundle / 'Contents/MacOS/Velinshot') == manifest['hashes']['1'], 'The prepared version 1 executable changed before installation.')
        if installed.exists(): shutil.rmtree(installed)
        installed.parent.mkdir(parents=True, exist_ok=True)
        command('ditto', source_bundle, installed)
        info = plistlib.loads((installed / 'Contents/Info.plist').read_bytes()); info['SUFeedURL'] = manifest['feedBaseURL'] + '/' + scenarios[args.scenario]
        (installed / 'Contents/Info.plist').write_bytes(plistlib.dumps(info))
        command('codesign', '--force', '--sign', '-', installed)
        command('codesign', '--verify', '--deep', '--strict', installed)
        # Re-signing each scenario's feed URL changes the executable's embedded signature.
        # Freeze the baseline before the SDK runs; successful updates still require the golden version 2 hash.
        manifest['installedBaseline'] = {'scenario': args.scenario, 'version': '1',
                                         'binarySHA256': digest(installed / 'Contents/MacOS/Velinshot')}
        manifest_path.write_text(json.dumps(manifest, indent=2) + '\n')
        Path(manifest['recordPath']).write_text(json.dumps({'event': 'scenarioInstalled', 'scenario': args.scenario}) + '\n')
        print('Private fixture installed, not launched:', installed)
    elif args.action == 'assert':
        require(args.version is not None, 'Provide --version 1 or --version 2.')
        info = plistlib.loads((installed / 'Contents/Info.plist').read_bytes())
        require(info['CFBundleVersion'] == args.version and info['CFBundleIdentifier'] == manifest['bundleIdentifier'], 'Fixture version or identity did not match.')
        expected = manifest['hashes'][args.version]
        if args.version == '1':
            baseline = manifest.get('installedBaseline', {})
            require(baseline.get('version') == '1' and baseline.get('scenario') in scenarios, 'Install a verified scenario baseline before asserting version 1.')
            expected = baseline.get('binarySHA256')
        require(digest(installed / 'Contents/MacOS/Velinshot') == expected, 'Installed executable is not the expected fixture version.')
        events = [json.loads(line) for line in Path(manifest['recordPath']).read_text().splitlines()]
        if args.version == '2':
            require(any(event.get('event') == 'launch' and event.get('compiledVersion') == '2' and event.get('bundleVersion') == '2' and event.get('path') == str(installed) for event in events), 'Version 2 did not actually relaunch from the private installed path.')
        if args.require_event:
            require(any(event.get('event') == args.require_event for event in events), 'Required real updater event was not observed.')
        if args.require_error:
            require(any(event.get('event') == 'cycleFinished' and event.get('error') != 'none' for event in events), 'The SDK did not report the expected update error.')
        print('Actual installed fixture version/hash verified:', args.version)
    else:
        stopped(manifest)
        if record.exists(): record.unlink()
        fixture_identifier = manifest['bundleIdentifier']
        subprocess.run(['defaults', 'delete', fixture_identifier], capture_output=True)
        if fixture_cache.is_dir(): shutil.rmtree(fixture_cache)
        shutil.rmtree(directory)
        print('Removed private fixture and its event log.')
