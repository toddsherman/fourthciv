#!/usr/bin/env python3
"""Prepare signed feed + notes from a verified installer; never publishes them."""
import argparse
import hashlib
import json
import os
import pathlib
import plistlib
import shutil
import subprocess
import urllib.parse
import xml.etree.ElementTree as ET
from release_notes import ROOT, notes, render

SPARKLE = '{http://www.andymatuschak.org/xml-namespaces/sparkle}'


def validate_manifest(archive, manifest):
    if manifest.get('notarized') is not True:
        raise ValueError('Only a verified notarized installer can become an update')
    if manifest.get('file') != archive.name or manifest.get('sha256') != hashlib.sha256(archive.read_bytes()).hexdigest():
        raise ValueError('Installer does not match its manifest')
    if type(manifest.get('build')) is not int or manifest['build'] < 1:
        raise ValueError('Missing positive build number')
    notes(manifest['version'])


def validate_feed(feed, manifest, download_url):
    entries = ET.parse(feed).getroot().findall('channel/item')
    matches = [entry for entry in entries if entry.findtext(SPARKLE+'version') == str(manifest['build'])]
    if len(matches) != 1:
        raise ValueError('Feed must contain exactly one entry for this build')
    item = matches[0]
    enclosure = item.find('enclosure')
    if enclosure is None or enclosure.get('url') != download_url or not enclosure.get(SPARKLE+'edSignature'):
        raise ValueError('Missing signed archive or unexpected download URL')
    if item.findtext(SPARKLE+'shortVersionString') != manifest['version']:
        raise ValueError('Feed display version does not match the release')
    if not item.findtext('description'):
        raise ValueError('Missing embedded release notes')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('archive', type=pathlib.Path)
    parser.add_argument('--output', type=pathlib.Path, required=True)
    parser.add_argument('--download-url')
    args = parser.parse_args()
    archive = args.archive.resolve()
    manifest = json.loads(archive.with_suffix('.json').read_text())
    validate_manifest(archive, manifest)
    version = manifest['version']
    url = args.download_url or f'https://github.com/toddsherman/fourthciv/releases/download/v{version}/{archive.name}'
    parsed = urllib.parse.urlsplit(url)
    if parsed.scheme != 'https' or not parsed.hostname or parsed.username or parsed.password or parsed.query or parsed.fragment or urllib.parse.unquote(parsed.path.rsplit('/',1)[-1]) != archive.name:
        raise ValueError('An HTTPS URL ending in the installer filename is required')
    existing = ROOT / 'website/public/updates/appcast.xml'
    for item in ET.parse(existing).getroot().findall('channel/item'):
        if int(item.findtext(SPARKLE+'version')) >= manifest['build']:
            raise ValueError('Build number must exceed every already-published feed entry')
    subprocess.run(['spctl','--assess','--type','open','--context','context:primary-signature',str(archive)],check=True)
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    shutil.copy2(archive, output/archive.name)
    shutil.copy2(archive.with_suffix('.json'), output/archive.with_suffix('.json').name)
    shutil.copy2(archive.with_suffix('.sha256'), output/archive.with_suffix('.sha256').name)
    shutil.copy2(existing, output/'appcast.xml')
    (output/archive.with_suffix('.html').name).write_text(render(notes(version)['lines'])+'\n')
    tools = ROOT / '.build/artifacts/sparkle/Sparkle/bin'
    if not (tools/'generate_appcast').exists():
        subprocess.run(['swift','package','resolve'],cwd=ROOT,check=True)
    private_key = os.environ.get('FOURTHCIV_SPARKLE_PRIVATE_KEY')
    key_args = ['--ed-key-file','-'] if private_key else ['--account','fourthciv']
    if not private_key:
        public_key = subprocess.check_output([str(tools/'generate_keys'),'--account','fourthciv','-p'],text=True).strip()
        with (ROOT/'Resources/Info.plist').open('rb') as file: info = plistlib.load(file)
        if public_key != info['SUPublicEDKey']:
            raise ValueError('Update signing key does not match the app')
    subprocess.run([str(tools/'generate_appcast'),*key_args,'--download-url-prefix',url.rsplit('/',1)[0]+'/',
                    '--embed-release-notes','--full-release-notes-url','https://fourthciv.ai/changelog',
                    '--link','https://fourthciv.ai/','--maximum-deltas','0','--maximum-versions','0',str(output)],
                   input=private_key,text=True,check=True)
    # Use the full pilot version in the dialog; CFBundleShortVersionString stays numeric.
    feed = output/'appcast.xml'
    tree = ET.parse(feed)
    for item in tree.getroot().findall('channel/item'):
        if item.findtext(SPARKLE+'version') == str(manifest['build']):
            item.find(SPARKLE+'shortVersionString').text = version
    ET.register_namespace('sparkle', SPARKLE[1:-1])
    tree.write(feed, encoding='utf-8', xml_declaration=True)
    subprocess.run([str(tools/'sign_update'),*key_args,str(feed)],input=private_key,text=True,check=True)
    subprocess.run([str(tools/'sign_update'),*key_args,'--verify',str(feed)],input=private_key,text=True,check=True)
    validate_feed(feed, manifest, url)
    enclosure = next(item for item in ET.parse(feed).getroot().findall('channel/item') if item.findtext(SPARKLE+'version') == str(manifest['build'])).find('enclosure')
    subprocess.run([str(tools/'sign_update'),*key_args,'--verify',str(output/archive.name),enclosure.get(SPARKLE+'edSignature')],input=private_key,text=True,check=True)
    if int(enclosure.get('length')) != archive.stat().st_size:
        raise ValueError('Feed enclosure length does not match archive')
    verifier = ['swift',str(ROOT/'scripts/verify-update-signature.swift'),str(ROOT/'Resources/Info.plist')]
    subprocess.run([*verifier,str(feed)],check=True)
    subprocess.run([*verifier,str(output/archive.name),enclosure.get(SPARKLE+'edSignature')],check=True)
    print('Prepared and verified signed update:', output)
    print('Publish the immutable installer first. Publish appcast.xml only after its download URL is live and verified.')


if __name__ == '__main__':
    main()
