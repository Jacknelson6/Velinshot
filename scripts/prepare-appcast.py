#!/usr/bin/env python3
"""Prepare a signed feed and versioned archive locally; never publish or create keys."""
import argparse
import hashlib
import json
from pathlib import Path, PurePosixPath
import plistlib
import re
import shutil
import subprocess
import tempfile
from urllib.parse import quote
import xml.etree.ElementTree as ET
import zipfile
from sparkle_support import KEYCHAIN_ACCOUNT, PRODUCTION_FEED, ROOT, command, distribution, require, update_configuration, validate_release_item, require_fresh_output, enclosure_snapshot, require_preserved_enclosures

parser = argparse.ArgumentParser()
parser.add_argument('archive', type=Path)
parser.add_argument('release_tag')
parser.add_argument('--output', type=Path, default=ROOT / 'build/appcast')
parser.add_argument('--previous-feed', type=Path)
args = parser.parse_args()
require(re.fullmatch(r'v[0-9][A-Za-z0-9.\-]*', args.release_tag), 'Use a version-specific release tag.')
require(args.archive.is_file() and args.archive.suffix == '.zip', 'A final packaged ZIP is required.')
output = args.output.resolve()
require_fresh_output(output)
_, tools = distribution()
namespace = {'sparkle': 'http://www.andymatuschak.org/xml-namespaces/sparkle'}

def digest(file):
    return hashlib.sha256(file.read_bytes()).hexdigest()

with tempfile.TemporaryDirectory(prefix='velinshot-appcast-') as temporary:
    scratch = Path(temporary)
    with zipfile.ZipFile(args.archive) as zipped:
        for member in zipped.infolist():
            parts = PurePosixPath(member.filename).parts
            require(parts and not member.filename.startswith('/') and '..' not in parts, 'Archive contains an unsafe path.')
            require(parts[0] in ('Velinshot.app', '__MACOSX'), 'Archive contains unexpected top-level content.')
            if (member.external_attr >> 16) & 0o170000 == 0o120000:
                target = PurePosixPath(zipped.read(member).decode())
                require(not target.is_absolute() and '..' not in target.parts, 'Archive contains an unsafe symlink.')
    command('ditto', '-x', '-k', args.archive.resolve(), scratch)
    bundle = scratch / 'Velinshot.app'
    command('python3', ROOT / 'scripts/verify-bundle.py', bundle, '--require-updater')
    info = plistlib.loads((bundle / 'Contents/Info.plist').read_bytes())
    update_configuration(info)
    build = json.loads((bundle / 'Contents/Resources/BuildInfo.json').read_text())
    revision = command('git', '-C', ROOT, 'rev-parse', 'HEAD').stdout.strip()
    require(not command('git', '-C', ROOT, 'status', '--porcelain', '--untracked-files=normal').stdout.strip(), 'Release source must be clean.')
    require(build.get('sourceRevision') == revision and build.get('sourceDirty') is False, 'Archive does not match the clean release source.')
    version = info['CFBundleVersion']
    require(version.isdigit(), 'The updater release build number must be an increasing integer.')
    # Official lookup/signing stays in this machine's app-specific Keychain item.
    # This command never generates, rotates, exports or prints the private key.
    public_key = command(tools / 'generate_keys', '-p', '--account', KEYCHAIN_ACCOUNT).stdout.strip()
    require(public_key == info['SUPublicEDKey'], 'The app public key does not match the authorized signing account.')
    feed = output / 'appcast.xml'
    previous_enclosures = enclosure_snapshot(ET.Element('rss'))
    if args.previous_feed:
        command(tools / 'sign_update', '--account', KEYCHAIN_ACCOUNT, '--verify', args.previous_feed.resolve())
        existing = ET.parse(args.previous_feed).findall('.//sparkle:version', namespace)
        require(all(item.text and item.text.isdigit() and int(item.text) < int(version) for item in existing), 'Feed build numbers must increase.')
        previous_enclosures = enclosure_snapshot(ET.parse(args.previous_feed))
        shutil.copy2(args.previous_feed, feed)
    else:
        require(not feed.exists(), 'Provide --previous-feed to preserve an existing signed appcast.')
    architecture = command('lipo', '-archs', bundle / 'Contents/MacOS/Velinshot').stdout.strip().replace(' ', '_')
    archive_name = f'Velinshot-{version}-{architecture}.zip'
    versioned_archive = output / archive_name
    require(not versioned_archive.exists(), 'Use a fresh appcast output directory; never overwrite a signed update archive.')
    shutil.copy2(args.archive, versioned_archive)
    download_prefix = f'https://github.com/Jacknelson6/Velinshot/releases/download/{quote(args.release_tag, safe="")}/'
    generated = subprocess.run([str(tools / 'generate_appcast'), '--account', KEYCHAIN_ACCOUNT,
                                '--download-url-prefix', download_prefix, '--maximum-deltas', '0', '--maximum-versions', '0', '-o', str(feed), str(output)],
                               capture_output=True, text=True, timeout=300)
    (output / 'generation.log').write_text(generated.stdout + generated.stderr)
    require(generated.returncode == 0, 'Sparkle appcast generation failed; inspect the local generation.log.')
    command(tools / 'sign_update', '--account', KEYCHAIN_ACCOUNT, '--verify', feed)
    tree = ET.parse(feed)
    require_preserved_enclosures(previous_enclosures, enclosure_snapshot(tree))
    items = [item for item in tree.findall('.//item') if item.findtext('sparkle:version', namespaces=namespace) == version]
    require(len(items) == 1, 'Generated feed does not contain exactly one matching build.')
    validate_release_item(items[0], info, architecture)
    enclosure = items[0].find('enclosure')
    require(enclosure is not None, 'The generated update has no archive enclosure.')
    require(enclosure.get('url') == download_prefix + quote(archive_name), 'Unexpected update archive URL.')
    require(enclosure.get('length') == str(versioned_archive.stat().st_size), 'Update archive length changed.')
    signature = enclosure.get('{'+namespace['sparkle']+'}edSignature')
    require(signature, 'The update archive has no Ed25519 signature.')
    command(tools / 'sign_update', '--account', KEYCHAIN_ACCOUNT, '--verify', versioned_archive, signature)
    metadata = {'sourceRevision': revision, 'build': version, 'feedURL': PRODUCTION_FEED,
                'publicKeySHA256': hashlib.sha256(public_key.encode()).hexdigest(),
                'archiveName': archive_name, 'archiveURL': enclosure.get('url'),
                'archiveSHA256': digest(versioned_archive), 'archiveSignature': signature,
                'feedSHA256': digest(feed), 'keychainAccount': KEYCHAIN_ACCOUNT}
    (output / 'UPDATER-INFO.json').write_text(json.dumps(metadata, indent=2, sort_keys=True) + '\n')
    print('Signed updater artifacts prepared locally:', output)
    print('Upload the versioned ZIP, download and verify it, then publish the unchanged signed appcast last.')
