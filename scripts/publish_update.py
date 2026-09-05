#!/usr/bin/env python3
"""Verify a staged update's public download before copying its signed feed into the website."""
import argparse
import hashlib
import json
import pathlib
import shutil
import subprocess
import tempfile
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ET
from prepare_update import ROOT, SPARKLE, validate_feed, validate_manifest


def validate_history(current, proposed):
    def items(path):
        result = {}
        for item in ET.parse(path).getroot().findall('channel/item'):
            build = int(item.findtext(SPARKLE+'version'))
            enclosure = item.find('enclosure')
            if build in result or enclosure is None:
                raise ValueError('Invalid or duplicate feed entry')
            result[build] = dict(enclosure.attrib)
        return result
    old, new = items(current), items(proposed)
    if any(new.get(build) != enclosure for build, enclosure in old.items()):
        raise ValueError('The staged feed would remove or change a published installer; regenerate it from current main')
    if not new or max(new) <= max(old, default=0):
        raise ValueError('The staged feed must add a newer build')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('directory',type=pathlib.Path)
    parser.add_argument('--check-only',action='store_true')
    args = parser.parse_args()
    directory = args.directory.resolve()
    manifests = list(directory.glob('FourthCiv-*.json'))
    if len(manifests) != 1: raise ValueError('Expected one staged release manifest')
    manifest = json.loads(manifests[0].read_text())
    filename = manifest['file']
    if pathlib.Path(filename).name != filename: raise ValueError('Invalid installer filename')
    archive = directory/filename
    validate_manifest(archive, manifest)
    feed = directory/'appcast.xml'
    current = ROOT/'website/public/updates/appcast.xml'
    verifier = ['swift',str(ROOT/'scripts/verify-update-signature.swift'),str(ROOT/'Resources/Info.plist')]
    subprocess.run([*verifier,str(feed)],check=True)
    validate_history(current,feed)
    item = next(item for item in ET.parse(feed).getroot().findall('channel/item')
                if item.findtext(SPARKLE+'version') == str(manifest['build']))
    enclosure = item.find('enclosure')
    url = enclosure.get('url')
    parsed = urllib.parse.urlsplit(url)
    if parsed.scheme != 'https' or not parsed.hostname or parsed.username or parsed.password:
        raise ValueError('A public HTTPS download is required')
    validate_feed(feed,manifest,url)
    if int(enclosure.get('length')) != archive.stat().st_size:
        raise ValueError('Feed archive length mismatch')
    with tempfile.TemporaryDirectory(prefix='fourthciv-publish-') as temporary:
        downloaded = pathlib.Path(temporary)/filename
        digest = hashlib.sha256()
        size = 0
        request = urllib.request.Request(url,headers={'User-Agent':'FourthCiv-release-verification'})
        with urllib.request.urlopen(request,timeout=60) as response, downloaded.open('wb') as output:
            if urllib.parse.urlsplit(response.url).scheme != 'https':
                raise ValueError('Installer redirect must remain HTTPS')
            while chunk := response.read(1024*1024):
                size += len(chunk)
                if size > archive.stat().st_size: raise ValueError('Public installer is larger than the signed release')
                digest.update(chunk); output.write(chunk)
        if digest.hexdigest() != manifest['sha256']:
            raise ValueError('Public download does not match the notarized installer')
        subprocess.run([*verifier,str(downloaded),enclosure.get(SPARKLE+'edSignature')],check=True)
    if not args.check_only:
        shutil.copyfile(feed,current)
        print('Verified public installer and copied signed feed. Commit and deploy the website to offer this update.')
    else: print('Public installer and signed feed verified; ready for website publication.')


if __name__ == '__main__': main()
