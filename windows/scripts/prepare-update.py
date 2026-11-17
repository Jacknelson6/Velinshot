#!/usr/bin/env python3
"""Prepare authenticated Windows feeds locally with official Sparkle Keychain tools.

Production mode only looks up an existing Windows key. It never generates or exports one.
The CI fixture uses public RFC8032 material in a disposable CI-only Keychain.
"""
import argparse
import base64
from contextlib import contextmanager
import hashlib
import json
from pathlib import Path
import re
import shlex
import subprocess
import tempfile
import os
import xml.etree.ElementTree as ET

SPARKLE = 'http://www.andymatuschak.org/xml-namespaces/sparkle'
VELINSHOT = 'https://github.com/Jacknelson6/Velinshot/updates'
PUBLIC_FIXTURE_KEY = '11qYAYKxCrfVS/7TyWQHOg7hcvPapiMlrwIaaPcHURo='
WINDOWS_ACCOUNT = 'com.jacknelson.velinshot.windows.ed25519'
ET.register_namespace('sparkle', SPARKLE)
ET.register_namespace('velinshot', VELINSHOT)

def command(args):
    result = subprocess.run([str(arg) for arg in args], check=True, capture_output=True, text=True, timeout=60)
    return result.stdout.strip()

def sign(tools, account, path):
    original = path.read_bytes()
    # Sparkle embeds its own signature into .xml feeds. NetSparkle needs a detached
    # signature over unchanged XML bytes, so use an identical non-XML temporary input.
    with tempfile.TemporaryDirectory(prefix='velinshot-detached-signature-') as folder:
        target = path
        if path.suffix.lower() == '.xml':
            target = Path(folder) / 'detached-feed-bytes.bin'
            target.write_bytes(original)
        output = command([tools / 'sign_update', '--account', account, target])
        if target.read_bytes() != original or path.read_bytes() != original:
            raise ValueError('Signing changed the artifact bytes; refusing the signature.')
    match = re.search(r'sparkle:edSignature="([A-Za-z0-9+/=]+)"', output)
    if not match or len(base64.b64decode(match[1], validate=True)) != 64:
        raise ValueError('Official sign_update did not return a valid signature.')
    return match[1]

def feed_filename(runtime, fixture=False, older=False):
    if fixture: return 'old-appcast.xml' if older else 'appcast.xml'
    if runtime == 'win-x64': return 'appcast.xml'
    if runtime == 'win-arm64': return 'appcast-arm64.xml'
    raise ValueError('Unsupported Windows feed architecture.')

def read_release(path, fixture):
    metadata = json.loads(path.read_text(encoding='utf-8-sig'))
    build = metadata['build']
    expected_source = command(['git', '-C', Path(__file__).resolve().parents[2], 'rev-parse', 'HEAD'])
    if (metadata.get('schemaVersion') != 1 or metadata.get('product') != 'Velinshot.Windows' or
        metadata.get('sourceClean') is not True or metadata['sourceCommit'] != expected_source or not re.fullmatch(r'[0-9a-f]{40}', metadata['sourceCommit']) or
        metadata.get('fixtureBuild') is not fixture or metadata.get('minimumWindowsBuild') != 19041 or
        metadata.get('version') != f'1.0.0.{build}' or metadata.get('displayVersion') != f'1.0.0-preview.{build}' or
        metadata.get('runtime') not in ('win-x64', 'win-arm64') or
        (metadata.get('updatePublicKey') == PUBLIC_FIXTURE_KEY) is not fixture):
        raise ValueError('Release provenance, build, architecture or signing mode is invalid.')
    filename = f"Velinshot-{metadata['displayVersion']}-{metadata['runtime']}-setup.exe"
    installer = path.parent / filename
    if (installer.stat().st_size != metadata['installerLength'] or
        hashlib.sha256(installer.read_bytes()).hexdigest() != metadata['installerSha256']):
        raise ValueError('Installer bytes do not match their immutable build metadata.')
    return metadata, installer

def feed(metadata, installer, signature, fixture, **overrides):
    root = ET.Element('rss', {'version': '2.0'})
    channel = ET.SubElement(root, 'channel')
    ET.SubElement(channel, 'title').text = 'Velinshot for Windows'
    ET.SubElement(channel, 'link').text = 'https://github.com/Jacknelson6/Velinshot'
    item = ET.SubElement(channel, 'item')
    ET.SubElement(item, 'title').text = 'Velinshot ' + metadata['displayVersion']
    url = (f'http://127.0.0.1:18763/{installer.name}' if fixture else
           f"https://github.com/Jacknelson6/Velinshot/releases/download/v{metadata['displayVersion']}/{installer.name}")
    attributes = {'url': url, 'length': str(installer.stat().st_size), 'type': 'application/octet-stream',
        f'{{{SPARKLE}}}version': metadata['version'], f'{{{SPARKLE}}}shortVersionString': metadata['displayVersion'],
        f'{{{SPARKLE}}}os': 'windows', f'{{{SPARKLE}}}signature': signature,
        f'{{{VELINSHOT}}}sourceCommit': metadata['sourceCommit'], f'{{{VELINSHOT}}}build': str(metadata['build']),
        f'{{{VELINSHOT}}}runtime': metadata['runtime'], f'{{{VELINSHOT}}}minimumWindowsBuild': '19041'}
    attributes.update(overrides)
    ET.SubElement(item, 'enclosure', attributes)
    ET.indent(root)
    return ET.tostring(root, encoding='utf-8', xml_declaration=True) + b'\n'

@contextmanager
def fixture_keychain(tools):
    if os.environ.get('GITHUB_ACTIONS') != 'true' or os.environ.get('RUNNER_OS') != 'macOS':
        raise ValueError('The public-key fixture may only provision a disposable Keychain on an ephemeral macOS CI runner.')
    previous = command(['security', 'default-keychain', '-d', 'user']).strip('"')
    listed = shlex.split(command(['security', 'list-keychains', '-d', 'user']))
    account = WINDOWS_ACCOUNT + '.rfc8032.fixture'
    with tempfile.TemporaryDirectory(prefix='velinshot-public-rfc-fixture-') as folder:
        keychain = Path(folder) / 'fixture.keychain-db'
        # This is an intentionally public test password and RFC8032 seed, never a release credential.
        password = 'public-RFC8032-test-fixture-only'
        command(['security', 'create-keychain', '-p', password, keychain])
        try:
            command(['security', 'unlock-keychain', '-p', password, keychain])
            command(['security', 'list-keychains', '-d', 'user', '-s', keychain])
            command(['security', 'default-keychain', '-d', 'user', '-s', keychain])
            seed = bytes.fromhex('9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60')
            seed_path = Path(folder) / 'PUBLIC-NONSECRET-RFC8032-SEED.txt'
            seed_path.write_text(base64.b64encode(seed).decode())
            command([tools / 'generate_keys', '--account', account, '-f', seed_path])
            if command([tools / 'generate_keys', '--account', account, '-p']) != PUBLIC_FIXTURE_KEY:
                raise ValueError('Official Keychain import did not yield the RFC8032 public key.')
            yield account
        finally:
            command(['security', 'default-keychain', '-d', 'user', '-s', previous])
            command(['security', 'list-keychains', '-d', 'user', '-s', *listed])
            command(['security', 'delete-keychain', keychain])

def prepare(args, account):
    args.output.mkdir(parents=True, exist_ok=False)
    for metadata_path in args.metadata:
        metadata, installer = read_release(metadata_path, args.fixture_ci)
        key = command([args.tools / 'generate_keys', '--account', account, '-p'])
        if key != metadata['updatePublicKey']:
            raise ValueError('The existing Keychain key does not match the embedded Windows public key.')
        signature = sign(args.tools, account, installer)
        older = metadata['build'] < max(json.loads(p.read_text(encoding='utf-8-sig'))['build'] for p in args.metadata)
        target_name = feed_filename(metadata['runtime'], args.fixture_ci, older)
        target = args.output / target_name
        target.write_bytes(feed(metadata, installer, signature, args.fixture_ci))
        target.with_name(target.name + '.signature').write_text(sign(args.tools, account, target) + '\n')
        if args.fixture_ci and target_name == 'appcast.xml':
            for name, overrides in [('wrong-arch.xml', {f'{{{VELINSHOT}}}runtime': 'win-arm64'}),
                                     ('future-os.xml', {f'{{{VELINSHOT}}}minimumWindowsBuild': '2147483647'})]:
                altered = args.output / name
                altered.write_bytes(feed(metadata, installer, signature, True, **overrides))
                altered.with_name(name + '.signature').write_text(sign(args.tools, account, altered) + '\n')
    if args.fixture_ci:
        payload = args.output / 'interop-payload.bin'
        payload.write_bytes(b'Velinshot Windows: official Sparkle Keychain signer interoperability fixture.\n')
        (args.output / 'interop-payload.bin.signature').write_text(sign(args.tools, account, payload) + '\n')
    print('Prepared authenticated Windows feed files. No release was published.')

if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--tools', type=Path, help='Official pinned Sparkle bin directory')
    parser.add_argument('--metadata', type=Path, nargs='+')
    parser.add_argument('--output', type=Path)
    parser.add_argument('--fixture-ci', action='store_true')
    parser.add_argument('--self-check', action='store_true')
    args = parser.parse_args()
    if args.self_check:
        assert feed_filename('win-x64') == 'appcast.xml'
        assert feed_filename('win-arm64') == 'appcast-arm64.xml'
        assert feed_filename('win-x64', True, True) == 'old-appcast.xml'
        assert feed_filename('win-x64', True, False) == 'appcast.xml'
        try: feed_filename('win-x86')
        except ValueError: pass
        else: raise AssertionError('Unsupported feed architecture was accepted.')
        print('PASS production x64/ARM64 and fixture feed routing; unsupported architecture refused.')
        raise SystemExit(0)
    if not args.tools or not args.metadata or not args.output:
        parser.error('--tools, --metadata and --output are required for signing')
    if args.fixture_ci:
        with fixture_keychain(args.tools) as account: prepare(args, account)
    else:
        if len(args.metadata) != 1: raise SystemExit('Production mode accepts exactly one immutable installer.')
        prepare(args, WINDOWS_ACCOUNT)
