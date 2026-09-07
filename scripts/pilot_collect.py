#!/usr/bin/env python3
"""Finite, read-only overnight collector for the installed Fourth Civ alpha.5 app.

Uses only `diagnostics` and signature-verifying `events` against loopback. Never
posts, reads identity files, changes settings, or prevents sleep. Python 3.9+.
"""
import argparse
from collections import Counter, deque
from datetime import datetime, timezone
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import sys
import time

CLI = '/Applications/Fourth Civ.app/Contents/MacOS/fourthciv-cli'
APP = '/Applications/Fourth Civ.app/Contents/MacOS/FourthCiv'
AUTHOR = 'fFEGa6MU/UbZBD4f3o1lEXtehcMnVJN+zmXq5Qn82Ec='
COMMUNITY = 'c5ec1139aad0da1f8d3a080cf32833e94045a01f80ba4347adb06d712afbf2d4'
MAX_BYTES = 12 * 1024 * 1024
TOP = 'schemaVersion capturedAt appVersion build buildConfiguration osVersion architecture'.split()
NODE = ('session configuration status listening paused internetEnabled lanEnabled syncing '
        'syncSeconds localPeerCount eventCount storageBytes storageLimitBytes syncBytesToday '
        'dailySyncLimitBytes historySaved recoveredUnreadableHistory').split()
RELAY = ('index isPilot lastAttempt lastSuccess nextAttempt consecutiveFailures '
         'acknowledgedEvents pendingEvents').split()
ENTRY = 'at session configuration action received sent'.split()


def stamp(value=None):
    return datetime.fromtimestamp(time.time() if value is None else value, timezone.utc).isoformat()


def encode(value):
    return (json.dumps(value, sort_keys=True, separators=(',', ':')) + '\n').encode()


def fields(value, keys):
    return {k: value[k] for k in keys if k in value}


def failure(value):
    return fields(value, ['kind', 'httpStatus', 'networkCode'])


def diagnostic(value):
    if value.get('schemaVersion') != 1 or not isinstance(value.get('node'), dict):
        raise ValueError('unsupported diagnostics')
    result = fields(value, TOP)
    node = value['node']
    result['node'] = fields(node, NODE)
    result['node']['relays'] = []
    for relay in node.get('relays', [])[:8]:
        entry = fields(relay, RELAY)
        if relay.get('lastFailure'):
            entry['lastFailure'] = failure(relay['lastFailure'])
        result['node']['relays'].append(entry)
    activity = []
    for item in node.get('recentActivity', [])[-100:]:
        entry = fields(item, ENTRY)
        if item.get('failure'):
            entry['failure'] = failure(item['failure'])
        if item.get('target'):
            entry['target'] = fields(item['target'], ['kind', 'index'])
        activity.append(entry)
    return result, activity


def body(run, sequence):
    return 'Fourth Civ overnight pilot {}: message {:02d}/16. Automated test traffic from Mac A.'.format(run, sequence)


def matching_events(events, run):
    """Only retain IDs/sequence/timestamps for the exact planned signed fixtures."""
    if not isinstance(events, list):
        raise ValueError('invalid events')
    expected = {body(run, i): i for i in range(1, 17)}
    result = []
    for event in events:
        if (event.get('kind') == 'message' and event.get('community') == COMMUNITY
                and event.get('author') == AUTHOR and event.get('body') in expected
                and re.fullmatch('[0-9a-f]{64}', event.get('id', ''))):
            result.append({'id': event['id'], 'sequence': expected[event['body']],
                           'createdAtMilliseconds': event['createdAt']})
    return result


def read_cli(command):
    # Keep commands fixed: no caller-provided endpoints or publishing commands.
    try:
        completed = subprocess.run([CLI, command, '--node', 'http://127.0.0.1:49400'],
                                   capture_output=True, timeout=20)
        if completed.returncode:
            return None, {'kind': 'cliFailed', 'exitCode': completed.returncode}
        if len(completed.stdout) > 24 * 1024 * 1024:
            return None, {'kind': 'outputTooLarge'}
        return json.loads(completed.stdout), None
    except subprocess.TimeoutExpired:
        return None, {'kind': 'cliTimedOut'}
    except OSError:
        return None, {'kind': 'cliUnavailable'}
    except (ValueError, UnicodeError):
        return None, {'kind': 'invalidJSON'}


def process_metrics():
    try:
        output = subprocess.run(['/bin/ps', '-ww', '-axo', 'pid=,pcpu=,rss=,time=,comm='],
                                capture_output=True, text=True, timeout=5, check=True).stdout
        result = []
        for line in output.splitlines():
            parts = line.split(None, 4)
            if len(parts) == 5 and parts[4] == APP:
                result.append({'pid': int(parts[0]), 'cpuPercentPs': float(parts[1]),
                               'residentKiB': int(parts[2]), 'cpuTimePs': parts[3]})
        return {'processes': result}
    except (OSError, ValueError, subprocess.SubprocessError):
        return {'error': 'processMetricsUnavailable'}


class Sampler:
    def __init__(self, run, interval):
        self.run = run
        self.interval = interval
        self.previous = None
        self.seen_activity = set()
        self.activity_order = deque()
        self.receipts = {}

    def sample(self, read=read_cli, metrics=process_metrics, now=None):
        now = time.time() if now is None else now
        result = {'observedAt': stamp(now), 'processMetrics': metrics()}
        if self.previous is not None:
            gap = now - self.previous
            result['secondsSincePreviousSample'] = round(gap, 3)
            if gap > self.interval * 1.5 or gap < 0:
                result['samplingGap'] = 'Cause unknown; do not infer sleep, crash, or network failure.'
        self.previous = now
        value, error = read('diagnostics')
        if error:
            result['diagnosticsError'] = error
        else:
            try:
                snapshot, activity = diagnostic(value)
                new = []
                overlap = 0
                for item in activity:
                    key = hashlib.sha256(encode(item)).hexdigest()
                    if key in self.seen_activity:
                        overlap += 1
                        continue
                    new.append(item)
                    self.seen_activity.add(key)
                    self.activity_order.append(key)
                while len(self.activity_order) > 4096:
                    self.seen_activity.discard(self.activity_order.popleft())
                result.update(diagnostics=snapshot, newActivity=new, activityOverlap=overlap)
            except (ValueError, TypeError, KeyError, AttributeError):
                result['diagnosticsError'] = {'kind': 'unsupportedDiagnostics'}
        value, error = read('events')
        if error:
            result['eventsError'] = error
        else:
            try:
                events = matching_events(value, self.run)
                counts = Counter(e['id'] for e in events)
                result['verifiedTestEvents'] = []
                for entry in {e['id']: e for e in events}.values():
                    event_id = entry['id']
                    # Limit even correctly signed unexpected test traffic.
                    if event_id not in self.receipts and len(self.receipts) < 64:
                        self.receipts[event_id] = stamp()
                    result['verifiedTestEvents'].append(dict(entry, occurrences=counts[event_id],
                        firstObservedAt=self.receipts.get(event_id), signaturesVerifiedByInstalledCLI=True))
                result['verifiedTestEvents'] = result['verifiedTestEvents'][:64]
                result['testEventCount'] = len(events)
            except (ValueError, TypeError, KeyError, AttributeError):
                result['eventsError'] = {'kind': 'invalidEvents'}
        result['completedAt'] = stamp()
        return result


def private_file(path, flags):
    return os.open(str(path), flags | os.O_NOFOLLOW, 0o600)


def atomic_json(path, value):
    temporary = path.with_name(path.name + '.tmp')
    fd = private_file(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL)
    try:
        with os.fdopen(fd, 'wb') as stream:
            stream.write(encode(value)); stream.flush(); os.fsync(stream.fileno())
        os.replace(str(temporary), str(path))
    finally:
        temporary.unlink(missing_ok=True)


def append_bounded(stream, value, maximum=MAX_BYTES):
    data = encode(value)
    if stream.tell() + len(data) > maximum:
        return False
    stream.write(data); stream.flush(); os.fsync(stream.fileno())
    return True


def collect(args):
    os.umask(0o077)
    output = Path(args.output).expanduser().resolve()
    output.mkdir(mode=0o700, parents=True, exist_ok=True)
    output.chmod(0o700)
    lock = os.fdopen(private_file(output / 'collector.lock', os.O_RDWR | os.O_CREAT), 'w')
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        raise ValueError('A collector already owns this output folder')
    # Refuse reuse rather than silently reset the baseline/first-observed times.
    if (output / 'manifest.json').exists() or (output / 'samples.jsonl').exists():
        raise ValueError('Use a new output folder for each collector run')
    started = time.time()
    deadline = started + args.hours * 3600
    state = {'schemaVersion': 1, 'run': args.run, 'label': args.label, 'startedAt': stamp(started),
             'scheduledEndAt': stamp(deadline), 'intervalSeconds': args.interval,
             'maximumSampleBytes': MAX_BYTES, 'pid': os.getpid(), 'readOnly': True,
             'keepsMacAwake': False, 'signatureVerification': 'Installed CLI events command',
             'scope': 'First observed receipt is a sampling bound, not exact delivery time. Sampling gaps have unknown causes. CPU percent is ps sampling; RSS is resident memory, not total footprint.'}
    atomic_json(output / 'manifest.json', state)
    stopped = [False]
    for sig in (signal.SIGTERM, signal.SIGINT):
        signal.signal(sig, lambda *_: stopped.__setitem__(0, True))
    sampler = Sampler(args.run, args.interval)
    reason = 'durationComplete'
    count = 0
    with os.fdopen(private_file(output / 'samples.jsonl', os.O_WRONLY | os.O_CREAT | os.O_EXCL), 'wb') as stream:
        while True:
            tick = time.time()
            if stopped[0] or (output / 'STOP').exists():
                reason = 'stopped'; break
            sample = sampler.sample()
            sample['sample'] = count + 1
            sample['afterScheduledEnd'] = tick >= deadline
            if not append_bounded(stream, sample):
                reason = 'storageCap'; break
            count += 1
            atomic_json(output / 'status.json', {'state': 'running', 'samples': count,
                'lastSampleAt': sample['completedAt'], 'sampleBytes': stream.tell(),
                'diagnosticsOK': 'diagnosticsError' not in sample,
                'eventsOK': 'eventsError' not in sample, 'testEventCount': sample.get('testEventCount'),
                'pid': os.getpid()})
            if args.samples and count >= args.samples:
                reason = 'sampleLimit'; break
            if tick >= deadline:
                break
            # One-second wakeups permit stop requests without preventing system sleep.
            next_tick = min(tick + args.interval, deadline)
            while time.time() < next_tick and not stopped[0] and not (output / 'STOP').exists():
                time.sleep(min(1, max(0, next_tick - time.time())))
    atomic_json(output / 'status.json', {'state': 'finished', 'reason': reason,
        'samples': count, 'finishedAt': stamp(), 'sampleBytes': (output / 'samples.jsonl').stat().st_size,
        'testEventsObserved': len(sampler.receipts), 'pid': os.getpid()})
    lock.close()


def status(output):
    output = Path(output).expanduser()
    result = {'output': str(output)}
    for name in ('manifest', 'status'):
        path = output / (name + '.json')
        if path.exists():
            result[name] = json.loads(path.read_text())
    lock_path = output / 'collector.lock'
    result['collectorLockHeld'] = False
    if lock_path.exists():
        with os.fdopen(private_file(lock_path, os.O_RDONLY), 'r') as stream:
            try:
                fcntl.flock(stream, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                result['collectorLockHeld'] = True
    print(json.dumps(result, indent=2))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest='command', required=True)
    for name in ('collect', 'start'):
        p = sub.add_parser(name)
        p.add_argument('--run', required=True)
        p.add_argument('--label', required=True, choices=['Mac-A', 'Mac-C', 'Mac-D'])
        p.add_argument('--output', required=True)
        p.add_argument('--hours', type=float, default=12)
        p.add_argument('--interval', type=int, default=60)
        p.add_argument('--samples', type=int, default=0, help='Optional smaller sample count for verification')
    for name in ('status', 'stop'):
        p = sub.add_parser(name); p.add_argument('--output', required=True)
    args = parser.parse_args()
    if args.command == 'status':
        return status(args.output)
    if args.command == 'stop':
        path = Path(args.output).expanduser() / 'STOP'
        with os.fdopen(private_file(path, os.O_WRONLY | os.O_CREAT), 'w'):
            pass
        return
    if not re.fullmatch('[A-Za-z0-9-]{1,64}', args.run):
        parser.error('Run marker must be 1-64 letters, digits, or hyphens')
    if not (0 < args.hours <= 12 and 30 <= args.interval <= 300 and 0 <= args.samples <= 1441):
        parser.error('Use at most 12 hours, 30-300 second intervals, and at most 1441 samples')
    if args.command == 'collect':
        return collect(args)
    os.umask(0o077)
    output = Path(args.output).expanduser().resolve()
    output.mkdir(mode=0o700, parents=True, exist_ok=True)
    with os.fdopen(private_file(output / 'launcher.log', os.O_WRONLY | os.O_CREAT | os.O_EXCL), 'wb') as log:
        command = [sys.executable, str(Path(__file__).resolve()), 'collect', '--run', args.run,
                   '--label', args.label, '--output', str(output), '--hours', str(args.hours),
                   '--interval', str(args.interval), '--samples', str(args.samples)]
        child = subprocess.Popen(command, stdin=subprocess.DEVNULL, stdout=log, stderr=log,
                                 start_new_session=True, close_fds=True)
    # Return only after a real sample exists or bounded startup has failed.
    for _ in range(100):
        if child.poll() is not None or (output / 'status.json').exists():
            break
        time.sleep(0.5)
    if not (output / 'status.json').exists():
        raise ValueError('No initial sample; inspect the private launcher.log')
    status(str(output))


if __name__ == '__main__':
    try:
        main()
    except (OSError, ValueError) as error:
        print('Collector stopped: {}'.format(error), file=sys.stderr)
        sys.exit(1)
