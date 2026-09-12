import json
import os
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

from pilot_collect import AUTHOR, COMMUNITY, body
from pilot_send import (COUNT, DURATION, GRACE, INTERVAL, attempt, lock_output,
                        output_folder, receipts, safe_path, send, slot_action, write_json)


class PilotSenderTests(unittest.TestCase):
    def args(self, output):
        return SimpleNamespace(run='test-run', identity='/private/test.identity.json',
                               author=AUTHOR, community=COMMUNITY, output=str(output))

    def event(self, sequence=1, **changes):
        event = {'id': 'a' * 64, 'author': AUTHOR, 'community': COMMUNITY,
                 'kind': 'message', 'body': body('test-run', sequence), 'createdAt': 1000}
        event.update(changes)
        return event

    def test_schedule_is_finite_and_skips_sleep_without_catch_up(self):
        start = 10000
        self.assertEqual(slot_action(start, 0, start), 'send')
        self.assertEqual(slot_action(start, 1, start), 'wait')
        self.assertEqual(slot_action(start, 0, start + GRACE + 1), 'skip')
        awake = start + 3 * INTERVAL + 20
        actions = [slot_action(start, i, awake) for i in range(COUNT)]
        self.assertEqual(actions[:5], ['skip', 'skip', 'skip', 'send', 'wait'])
        self.assertEqual([slot_action(start, i, start + DURATION) for i in range(COUNT)], ['skip'] * COUNT)

    def test_unknown_post_is_reserved_before_call_and_never_repeated(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory).resolve()
            calls = []
            def call(arguments):
                calls.append(arguments[0])
                if arguments[0] == 'post':
                    persisted = json.loads((output / 'slot-01.json').read_text())
                    self.assertEqual(persisted['state'], 'attemptReserved')
                    return None, {'kind': 'cliTimedOut'}
                return [self.event()], None
            result = attempt(self.args(output), output, 1, 100, call=call, now=lambda: 100)
            self.assertEqual(result['state'], 'unknown')
            self.assertEqual(result['verifiedTestEvents'][0]['id'], 'a' * 64)
            self.assertEqual(calls, ['post', 'events'])
            with self.assertRaises(FileExistsError):
                attempt(self.args(output), output, 1, 100, call=call)
            self.assertEqual(calls, ['post', 'events'])

    def test_abrupt_interruption_leaves_reservation_and_prevents_replay(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory).resolve()
            def interrupted(_):
                raise RuntimeError('Simulated interruption during CLI call')
            with self.assertRaises(RuntimeError):
                attempt(self.args(output), output, 1, 100, call=interrupted)
            self.assertEqual(json.loads((output / 'slot-01.json').read_text())['state'], 'attemptReserved')
            with patch('pilot_send.run_cli') as call:
                with self.assertRaises(ValueError):
                    send(self.args(output))
                call.assert_not_called()

    def test_post_acknowledgement_is_separate_from_signature_verification(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory).resolve()
            def call(arguments):
                if arguments[0] == 'post':
                    return {'id': 'b' * 64, 'result': 'accepted', 'private': 'SENTINEL'}, None
                return None, {'kind': 'cliFailed', 'exitCode': 1}
            result = attempt(self.args(output), output, 1, 100, call=call)
            self.assertEqual(result['state'], 'acknowledgedLocally')
            self.assertEqual(result['id'], 'b' * 64)
            self.assertIn('verificationError', result)
            self.assertNotIn('SENTINEL', json.dumps(result))

    def test_receipts_filter_scope_and_preserve_duplicate_occurrences(self):
        events = [self.event(), self.event(), self.event(author='different'),
                  self.event(community='0' * 64), self.event(body='SENTINEL'),
                  self.event(id='b' * 64)]
        result = receipts(events, 'test-run', AUTHOR, COMMUNITY)
        self.assertEqual([r['id'] for r in result], ['a' * 64, 'a' * 64, 'b' * 64])
        self.assertNotIn('SENTINEL', json.dumps(result))

    def test_private_permissions_symlink_refusal_and_lock(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            output = output_folder(root / 'sender')
            self.assertEqual(output.stat().st_mode & 0o777, 0o700)
            metadata = output / 'status.json'
            write_json(metadata, {'state': 'running'})
            self.assertEqual(metadata.stat().st_mode & 0o777, 0o600)
            with lock_output(output):
                with self.assertRaises(ValueError):
                    lock_output(output)
            link = root / 'linked'; link.symlink_to(output, target_is_directory=True)
            with self.assertRaises(ValueError):
                output_folder(link / 'child')
            target = output / 'target.json'; target.symlink_to(metadata)
            with self.assertRaises(ValueError):
                write_json(target, {'unexpected': 'write'})
            self.assertEqual(json.loads(metadata.read_text()), {'state': 'running'})
            with self.assertRaises(ValueError):
                write_json(output / 'large.json', {'value': 'x' * 65536})

    def test_existing_marker_in_verified_events_blocks_all_posts(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory).resolve()
            def call(arguments):
                if arguments == ['diagnostics']:
                    return {'node': {'listening': True, 'paused': False, 'internetEnabled': True}}, None
                self.assertEqual(arguments, ['events'])
                return [self.event()], None
            with patch('pilot_send.run_cli', side_effect=call), patch('pilot_send.reconcile', return_value={'verifiedTestEvents': [self.event()]}):
                with self.assertRaises(ValueError):
                    send(self.args(output))
            self.assertFalse((output / 'manifest.json').exists())

    def test_full_virtual_run_attempts_sixteen_slots_and_finishes_at_eight_hours(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory).resolve()
            clock = [10000]
            attempts = []
            def advance(seconds):
                clock[0] += seconds
            def post(args, target, sequence, scheduled):
                attempts.append((sequence, clock[0], scheduled))
                return {'state': 'acknowledgedLocally'}
            diagnostics = ({'node': {'listening': True, 'paused': False, 'internetEnabled': True}}, None)
            with patch('pilot_send.time.time', side_effect=lambda: clock[0]), \
                 patch('pilot_send.time.sleep', side_effect=advance), \
                 patch('pilot_send.signal.signal'), \
                 patch('pilot_send.run_cli', return_value=diagnostics), \
                 patch('pilot_send.reconcile', return_value={'verifiedTestEvents': []}), \
                 patch('pilot_send.attempt', side_effect=post):
                send(self.args(output))
            self.assertEqual(len(attempts), 16)
            self.assertEqual([row[0] for row in attempts], list(range(1, 17)))
            self.assertEqual([row[1] for row in attempts], [10000 + INTERVAL * i for i in range(16)])
            self.assertEqual(clock[0], 10000 + DURATION)
            final = json.loads((output / 'status.json').read_text())
            self.assertEqual((final['state'], final['reason'], final['attempted']), ('finished', 'durationComplete', 16))

    def test_virtual_sleep_skips_expired_slots_and_stop_prevents_next_post(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory).resolve()
            clock = [10000]
            attempts = []
            def advance(_):
                clock[0] = 10000 + 3 * INTERVAL + 20
            def post(args, target, sequence, scheduled):
                attempts.append(sequence)
                if len(attempts) == 2:
                    (output / 'STOP').touch()
                return {'state': 'unknown'}
            diagnostics = ({'node': {'listening': True, 'paused': False, 'internetEnabled': True}}, None)
            with patch('pilot_send.time.time', side_effect=lambda: clock[0]), \
                 patch('pilot_send.time.sleep', side_effect=advance), \
                 patch('pilot_send.signal.signal'), \
                 patch('pilot_send.run_cli', return_value=diagnostics), \
                 patch('pilot_send.reconcile', return_value={'verifiedTestEvents': []}), \
                 patch('pilot_send.attempt', side_effect=post):
                send(self.args(output))
            self.assertEqual(attempts, [1, 4])
            self.assertEqual(json.loads((output / 'slot-02.json').read_text())['state'], 'skipped')
            self.assertEqual(json.loads((output / 'slot-03.json').read_text())['state'], 'skipped')
            final = json.loads((output / 'status.json').read_text())
            self.assertEqual((final['reason'], final['attempted'], final['skipped']), ('stopped', 2, 2))

    def test_acknowledgement_outside_expected_signed_scope_stops_further_posts(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory).resolve()
            diagnostics = ({'node': {'listening': True, 'paused': False, 'internetEnabled': True}}, None)
            wrong_scope = {'state': 'acknowledgedLocally', 'id': 'b' * 64,
                           'signaturesVerifiedByInstalledCLI': True, 'verifiedTestEvents': []}
            with patch('pilot_send.signal.signal'), \
                 patch('pilot_send.run_cli', return_value=diagnostics), \
                 patch('pilot_send.reconcile', return_value={'verifiedTestEvents': []}), \
                 patch('pilot_send.attempt', return_value=wrong_scope) as post:
                send(self.args(output))
            post.assert_called_once()
            final = json.loads((output / 'status.json').read_text())
            self.assertEqual(final['reason'], 'acknowledgedEventNotVerified')


if __name__ == '__main__':
    unittest.main()
