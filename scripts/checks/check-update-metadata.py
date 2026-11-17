#!/usr/bin/env python3
"""Release-contract checks: keep incompatible archives out of the signed feed."""
from pathlib import Path
import base64
import copy
import sys
import tempfile
import uuid
import xml.etree.ElementTree as ET
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from sparkle_support import validate_release_item, update_configuration, PRODUCTION_FEED, verify_production_binary, require_fresh_output, enclosure_snapshot, require_preserved_enclosures, fixture_paths

namespace = 'http://www.andymatuschak.org/xml-namespaces/sparkle'
info = {'LSMinimumSystemVersion': '14.0'}

def item(minimum='14.0', hardware='arm64'):
    result = ET.Element('item')
    if minimum is not None: ET.SubElement(result, '{'+namespace+'}minimumSystemVersion').text = minimum
    if hardware is not None: ET.SubElement(result, '{'+namespace+'}hardwareRequirements').text = hardware
    return result

validate_release_item(item(), info, 'arm64')
validate_release_item(item(hardware=None), info, 'arm64_x86_64')
count = 2
for candidate in [item(hardware=None), item(hardware='x86_64'), item(minimum=None), item(minimum='12.0')]:
    try:
        validate_release_item(candidate, info, 'arm64')
    except SystemExit:
        count += 1
    else:
        raise SystemExit('Incompatible or unspecified update metadata was accepted.')
def rejected(action):
    global count
    try:
        action()
    except SystemExit:
        count += 1
    else:
        raise SystemExit('An unsafe updater configuration or release operation was accepted.')

configuration = {'SUFeedURL': PRODUCTION_FEED, 'SUPublicEDKey': base64.b64encode(bytes(range(1,33))).decode(),
                 'SURequireSignedFeed': True, 'SUVerifyUpdateBeforeExtraction': True,
                 'SUSignedFeedFailureExpirationInterval': 0, 'SUEnableSystemProfiling': False,
                 'SUAutomaticallyUpdate': False, 'SUAllowsAutomaticUpdates': False,
                 'SUEnableAutomaticChecks': False, 'SUEnableJavaScript': False, 'SUShowReleaseNotes': False}
update_configuration(configuration); count += 1
rejected(lambda: update_configuration({**configuration, 'SUPublicEDKey': '11qYAYKxCrfVS/7TyWQHOg7hcvPapiMlrwIaaPcHURo='}))
for expiry in [False, 0.0, '0']:
    rejected(lambda expiry=expiry: update_configuration({**configuration, 'SUSignedFeedFailureExpirationInterval': expiry}))
for flag in ['SUEnableAutomaticChecks', 'SUEnableJavaScript', 'SUShowReleaseNotes']:
    rejected(lambda flag=flag: update_configuration({**configuration, flag: True}))
    rejected(lambda flag=flag: update_configuration({key:value for key,value in configuration.items() if key != flag}))

with tempfile.TemporaryDirectory(prefix='velinshot-updater-fixture-metadata-') as temporary:
    directory = Path(temporary).resolve()
    binary = directory / 'binary'
    binary.write_bytes(b'production executable marker fixture'); verify_production_binary(binary); count += 1
    for marker in [b'com.jacknelson.velinshot.update-fixture.', b'VelinshotFixtureRunID', b'onFixtureEvent']:
        binary.write_bytes(b'prefix'+marker+b'suffix'); rejected(lambda: verify_production_binary(binary))
    output = directory / 'fresh'; require_fresh_output(output); count += 1
    (output/'stale.zip').write_bytes(b'stale'); rejected(lambda: require_fresh_output(output))
    run = uuid.uuid4().hex
    record = Path(tempfile.gettempdir()) / ('VelinshotUpdaterFixture-'+run+'.jsonl')
    manifest = {'run':run, 'bundleIdentifier':'com.jacknelson.velinshot.update-fixture.'+run,
                'installed':str(directory/'installed/VelinshotUpdaterFixture.app'), 'recordPath':str(record)}
    fixture_paths(directory,manifest); count += 1
    rejected(lambda: fixture_paths(directory,{**manifest,'installed':str(directory.parent/'Velinshot.app')}))
    rejected(lambda: fixture_paths(directory,{**manifest,'recordPath':str(directory/'unrelated.jsonl')}))
    rejected(lambda: fixture_paths(directory,{**manifest,'bundleIdentifier':'com.jacknelson.velinshot'}))
    rejected(lambda: fixture_paths(directory.parent/'unrelated',manifest))
    target = directory/'preserved.txt'; target.write_text('keep')
    record.symlink_to(target)
    try:
        rejected(lambda: fixture_paths(directory,manifest))
        if target.read_text() != 'keep': raise SystemExit('Fixture path validation changed unrelated data.')
    finally:
        record.unlink()

rss = ET.Element('rss'); channel = ET.SubElement(rss,'channel'); old = ET.SubElement(channel,'item')
ET.SubElement(old,'{'+namespace+'}version').text = '1'
ET.SubElement(old,'enclosure',{'url':'https://example.com/old.zip','length':'123','{'+namespace+'}edSignature':'old-signature'})
previous = enclosure_snapshot(rss)
require_preserved_enclosures(previous,enclosure_snapshot(copy.deepcopy(rss))); count += 1
for attribute in ['url','length','{'+namespace+'}edSignature']:
    changed = copy.deepcopy(rss); changed.find('.//enclosure').set(attribute,'changed')
    rejected(lambda changed=changed: require_preserved_enclosures(previous,enclosure_snapshot(changed)))
rejected(lambda: require_preserved_enclosures(previous,enclosure_snapshot(ET.Element('rss'))))
print(f'Update release security/metadata checks passed: {count}. Sparkle performs client version/architecture compatibility.')
