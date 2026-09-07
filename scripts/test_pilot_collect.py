import json
import os
from pathlib import Path
import tempfile
import unittest
from pilot_collect import (AUTHOR, COMMUNITY, Sampler, append_bounded, atomic_json,
                           body, diagnostic, matching_events, private_file)


def report():
    return {'schemaVersion': 1, 'appVersion': '0.2.0-alpha.5', 'build': '6',
            'privatePath': 'PRIVATE-SENTINEL', 'node': {'session': 'test-session', 'eventCount': 23,
            'relays': [{'index': 1, 'hostname': 'PRIVATE-SENTINEL',
                        'lastFailure': {'kind': 'http', 'httpStatus': 503, 'description': 'PRIVATE-SENTINEL'}}],
            'recentActivity': [{'at': '2026-09-07T04:30:00Z', 'session': 'test-session',
                                'action': 'syncFailed', 'failure': {'kind': 'http', 'httpStatus': 503,
                                'description': 'PRIVATE-SENTINEL'}}]}}


class PilotCollectorTests(unittest.TestCase):
    def test_only_planned_sender_community_and_body_are_retained(self):
        event = {'id': 'a' * 64, 'kind': 'message', 'author': AUTHOR, 'community': COMMUNITY,
                 'body': body('run-1', 1), 'createdAt': 1}
        variants = [event, dict(event, author='another key'), dict(event, community='another community'),
                    dict(event, body='PRIVATE-SENTINEL'), dict(event, body=body('another-run', 1))]
        found = matching_events(variants, 'run-1')
        self.assertEqual(found, [{'id': 'a' * 64, 'sequence': 1, 'createdAtMilliseconds': 1}])
        self.assertNotIn(AUTHOR, json.dumps(found))
        self.assertNotIn('PRIVATE-SENTINEL', json.dumps(found))

    def test_history_dedup_preserves_failures_and_identifies_sampling_gaps(self):
        data = report()
        sampler = Sampler('run-1', 60)
        def read(command):
            return (data if command == 'diagnostics' else []), None
        first = sampler.sample(read, lambda: {}, now=100)
        second = sampler.sample(read, lambda: {}, now=160)
        data['node']['recentActivity'].append({'at': '2026-09-07T04:31:00Z', 'session': 'test-session', 'action': 'syncSucceeded'})
        third = sampler.sample(read, lambda: {}, now=600)
        self.assertEqual(len(first['newActivity']), 1)
        self.assertEqual(first['newActivity'][0]['failure']['httpStatus'], 503)
        self.assertEqual(second['newActivity'], [])
        self.assertEqual(second['activityOverlap'], 1)
        self.assertEqual(len(third['newActivity']), 1)
        self.assertIn('samplingGap', third)
        self.assertNotIn('PRIVATE-SENTINEL', json.dumps([first, second, third]))

    def test_failed_signature_verification_never_reports_receipt(self):
        sample = Sampler('run-1', 60).sample(lambda _: (None, {'kind': 'cliFailed', 'exitCode': 1}), lambda: {})
        self.assertIn('eventsError', sample)
        self.assertNotIn('verifiedTestEvents', sample)

    def test_duplicate_occurrences_and_multiple_ids_for_one_sequence_remain_visible(self):
        event = {'id': 'a' * 64, 'kind': 'message', 'author': AUTHOR, 'community': COMMUNITY,
                 'body': body('run-1', 1), 'createdAt': 1}
        def read(command):
            return (report() if command == 'diagnostics' else [event, event, dict(event, id='b' * 64)]), None
        entries = Sampler('run-1', 60).sample(read, lambda: {})['verifiedTestEvents']
        self.assertEqual([e['occurrences'] for e in entries], [2, 1])
        self.assertEqual([e['sequence'] for e in entries], [1, 1])

    def test_disk_budget_permissions_and_symlink_refusal(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'samples.jsonl'
            with os.fdopen(private_file(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL), 'wb') as stream:
                self.assertTrue(append_bounded(stream, {'one': 1}, maximum=20))
                before = stream.tell()
                self.assertFalse(append_bounded(stream, {'too': 'x' * 40}, maximum=20))
                self.assertEqual(stream.tell(), before)
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)
            metadata = Path(directory) / 'status.json'
            atomic_json(metadata, {'state': 'running'})
            atomic_json(metadata, {'state': 'finished'})
            self.assertEqual(json.loads(metadata.read_text())['state'], 'finished')
            self.assertEqual(metadata.stat().st_mode & 0o777, 0o600)
            link = Path(directory) / 'link'; link.symlink_to(path)
            with self.assertRaises(OSError):
                private_file(link, os.O_WRONLY)

    def test_unknown_schema_is_rejected(self):
        with self.assertRaises(ValueError):
            diagnostic({'schemaVersion': 2, 'node': {}})


if __name__ == '__main__':
    unittest.main()
