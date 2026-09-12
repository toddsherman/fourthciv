import json
import pathlib
import subprocess
import sys
import tempfile
import unittest

from check_secrets import MAX_BYTES, detect, scan_current


SCANNER = pathlib.Path(__file__).with_name('check_secrets.py').resolve()


class SecretDetectorTests(unittest.TestCase):
    def expect_category(self, content, category):
        findings = detect(content.encode(), 'synthetic.txt')
        self.assertIn(category, {finding['category'] for finding in findings})
        self.assertTrue(all(set(finding) == {'path', 'line', 'category'} for finding in findings))
        self.assertNotIn(content, json.dumps(findings))

    def test_private_key_blocks(self):
        for algorithm in ['', 'RSA ', 'EC ', 'OPENSSH ', 'DSA ', 'ENCRYPTED ']:
            self.expect_category('-----BEGIN ' + algorithm + 'PRIVATE KEY-----', 'private-key-block')

    def test_common_token_formats(self):
        cases = [('ghp_' + 'a' * 36, 'github-token'),
                 ('github_pat_' + 'a' * 60, 'github-token'),
                 ('AKIA' + 'A' * 16, 'aws-access-key'),
                 ('xoxb-' + '1234567890-' * 3, 'slack-token'),
                 ('sk-proj-' + 'a' * 48, 'openai-key')]
        for content, category in cases:
            self.expect_category(content, category)

    def test_credential_urls_and_private_identity(self):
        for scheme in ['postgres', 'postgresql', 'mysql', 'mongodb', 'mongodb+srv']:
            self.expect_category(scheme + '://person:synthetic-password@db.example/db', 'credentialed-database-url')
        self.expect_category(json.dumps({'privateKey': 'A' * 43 + '='}), 'literal-agent-private-key')
        self.expect_category('FOURTHCIV_REQUEST_KEY=' + 'b' * 64, 'literal-sensitive-assignment')

    def test_public_keys_environment_references_and_explicit_placeholders_are_safe(self):
        examples = ['-----BEGIN ' + 'PUBLIC KEY-----\n' + 'A' * 44,
                    json.dumps({'publicKey': 'A' * 43 + '='}),
                    '<key>SUPublicEDKey</key><string>' + 'A' * 43 + '=</string>',
                    'FOURTHCIV_SPARKLE_PRIVATE_KEY: ${{ secrets.FOURTHCIV_SPARKLE_PRIVATE_KEY }}',
                    'DATABASE_URL=${DATABASE_URL}\nFOURTHCIV_REQUEST_KEY=\n',
                    'OPENAI_API_KEY=<YOUR_API_KEY>',
                    'postgresql://<USER>:<PASSWORD>@HOST/DATABASE',
                    'postgresql://${USER}:${PASSWORD}@db.example/db']
        for example in examples:
            self.assertEqual(detect(example.encode(), 'example.txt'), [])

    def test_findings_include_line_but_never_matched_value(self):
        fake = 'ghp_' + 'x' * 36
        findings = detect(('public\n' + fake + '\n').encode(), 'file.txt')
        self.assertEqual(findings, [{'path': 'file.txt', 'line': 2, 'category': 'github-token'}])
        self.assertNotIn(fake, json.dumps(findings))


class RepositoryScannerTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='fourthciv-secret-test-')
        self.addCleanup(self.temporary.cleanup)
        self.repo = pathlib.Path(self.temporary.name).resolve()
        self.git('init', '-q')

    def git(self, *args):
        return subprocess.run(['git', '-C', str(self.repo), *args], check=True,
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE)

    def run_scanner(self, *args):
        result = subprocess.run([sys.executable, str(SCANNER), '--repo', str(self.repo), *args],
                                capture_output=True, text=True)
        return result.returncode, json.loads(result.stdout), result.stdout

    def test_current_working_copy_is_checked_and_ignored_credentials_are_not_read(self):
        (self.repo / 'source.txt').write_text('safe')
        (self.repo / '.gitignore').write_text('.env\n')
        self.git('add', 'source.txt', '.gitignore')
        fake = 'ghp_' + 'z' * 36
        (self.repo / '.env').write_text(fake)
        self.assertEqual(self.run_scanner()[0], 0)
        (self.repo / 'source.txt').write_text(fake)
        code, result, output = self.run_scanner()
        self.assertEqual(code, 1)
        self.assertEqual({finding['path'] for finding in result['findings']}, {'source.txt'})
        self.assertNotIn(fake, output)

    def test_optional_new_files_and_skip_counts(self):
        (self.repo / 'source.txt').write_text('safe')
        self.git('add', 'source.txt')
        (self.repo / 'new.txt').write_text('ghp_' + 'q' * 36)
        self.assertEqual(self.run_scanner()[0], 0)
        self.assertEqual(self.run_scanner('--include-untracked')[0], 1)
        (self.repo / 'binary.dat').write_bytes(b'\0binary')
        (self.repo / 'large.txt').write_bytes(b'a' * (MAX_BYTES + 1))
        (self.repo / 'link.txt').symlink_to(self.repo / 'new.txt')
        self.git('add', 'binary.dat', 'large.txt', 'link.txt')
        counts, findings, errors = scan_current(self.repo)
        self.assertEqual(counts['binary_skipped'], 1)
        self.assertEqual(counts['oversized_skipped'], 1)
        self.assertEqual(counts['symlink_or_external_skipped'], 1)
        self.assertEqual(findings, [])
        self.assertEqual(errors, [])

    def test_history_finds_removed_synthetic_secret_without_printing_it(self):
        fake = 'ghp_' + 'h' * 36
        (self.repo / 'old.txt').write_text(fake)
        self.git('add', 'old.txt')
        self.git('-c', 'user.name=Scanner Test', '-c', 'user.email=scanner@example.invalid',
                 'commit', '-qm', 'Synthetic historical fixture')
        (self.repo / 'old.txt').write_text('safe now')
        self.assertEqual(self.run_scanner()[0], 0)
        code, result, output = self.run_scanner('--history')
        self.assertEqual(code, 1)
        self.assertEqual(result['history']['text_scanned'], 1)
        self.assertEqual(result['findings'][0]['path'], 'history:old.txt')
        self.assertNotIn(fake, output)


if __name__ == '__main__':
    unittest.main()
