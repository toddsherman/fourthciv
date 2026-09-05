import copy
import hashlib
import json
import pathlib
import plistlib
import subprocess
import tempfile
import unittest
from prepare_update import ROOT, validate_manifest
from release_notes import entries, notes, render
from publish_update import validate_history


class ReleaseSafetyTests(unittest.TestCase):
    def test_release_notes_cannot_inject_html(self):
        rendered = render(['### Fixed <script>alert(1)</script>', '- <img src=x onerror=alert(1)>', 'Read & verify'])
        self.assertNotIn('<script>', rendered)
        self.assertNotIn('<img', rendered)
        self.assertIn('&lt;img', rendered)
        self.assertIn('Read &amp; verify', rendered)

    def test_missing_undated_and_duplicate_release_notes_are_rejected(self):
        with self.assertRaises(ValueError): notes('9.0', '## [8.0] - 2026-09-05\n- Example')
        with self.assertRaises(ValueError): notes('9.0', '## [9.0]\n- Example')
        with self.assertRaises(ValueError): entries('## [9.0] - 2026-09-05\n- One\n## [9.0] - 2026-09-05\n- Two')

    def test_unsigned_tampered_and_misidentified_installers_are_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            archive = pathlib.Path(directory)/'FourthCiv.dmg'
            archive.write_bytes(b'installer fixture')
            config = json.loads((ROOT/'release.json').read_text())
            manifest = dict(config, file=archive.name, notarized=True, sha256=hashlib.sha256(archive.read_bytes()).hexdigest())
            validate_manifest(archive, manifest)
            for field, value in [('notarized',False),('file','another.dmg'),('build',0),('sha256','0'*64)]:
                modified = copy.deepcopy(manifest); modified[field] = value
                with self.assertRaises(ValueError): validate_manifest(archive, modified)
            archive.write_bytes(b'tampered installer')
            with self.assertRaises(ValueError): validate_manifest(archive, manifest)

    def test_signed_feed_rejects_modified_content(self):
        verifier = ['swift',str(ROOT/'scripts/verify-update-signature.swift'),str(ROOT/'Resources/Info.plist')]
        feed = ROOT/'website/public/updates/appcast.xml'
        subprocess.run([*verifier,str(feed)],check=True,capture_output=True)
        with tempfile.TemporaryDirectory() as directory:
            altered = pathlib.Path(directory)/'appcast.xml'
            altered.write_bytes(feed.read_bytes().replace(b'Fourth Civ',b'Fourth Bad',1))
            result = subprocess.run([*verifier,str(altered)],capture_output=True)
            self.assertNotEqual(result.returncode,0)

    def test_release_config_and_updater_policy(self):
        config = json.loads((ROOT/'release.json').read_text())
        with (ROOT/'Resources/Info.plist').open('rb') as f: info = plistlib.load(f)
        notes(config['version'])
        self.assertEqual(info['CFBundleVersion'],str(config['build']))
        self.assertEqual(info['FourthCivReleaseVersion'],config['version'])
        self.assertTrue(info['SURequireSignedFeed'])
        self.assertTrue(info['SUVerifyUpdateBeforeExtraction'])
        self.assertFalse(info['SUAutomaticallyUpdate'])
        self.assertFalse(info['SUEnableSystemProfiling'])

    def test_feed_publication_preserves_history_and_requires_newer_builds(self):
        def feed(entries):
            return '<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel>' + ''.join(
                f'<item><sparkle:version>{build}</sparkle:version><enclosure url="{url}"/></item>'
                for build,url in entries) + '</channel></rss>'
        with tempfile.TemporaryDirectory() as directory:
            old = pathlib.Path(directory)/'old.xml'; new = pathlib.Path(directory)/'new.xml'
            old.write_text(feed([(3,'https://example.org/3.dmg')]))
            new.write_text(feed([(4,'https://example.org/4.dmg'),(3,'https://example.org/3.dmg')]))
            validate_history(old,new)
            for entries in [[(4,'https://example.org/4.dmg')],[(3,'https://example.org/changed.dmg')],
                            [(3,'https://example.org/3.dmg')],[(3,'a'),(3,'b')]]:
                new.write_text(feed(entries))
                with self.assertRaises(ValueError): validate_history(old,new)


if __name__ == '__main__': unittest.main()
