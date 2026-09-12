#!/usr/bin/env python3
"""Finite Fourth Civ pilot sender: at most 16 public messages over eight hours.

The installed CLI creates and submits each event in one command. Reserve each
attempt durably before invoking it once; never retry an uncertain result. Reuse
of an output directory is refused. Python 3.9+, standard library only.
"""
import argparse
import base64
import fcntl
import json
import os
from pathlib import Path
import re
import signal
import stat
import subprocess
import sys
import time

from pilot_collect import CLI, body, encode, private_file, stamp

COUNT = 16
INTERVAL = 30 * 60
DURATION = 8 * 60 * 60
GRACE = 90
NODE = 'http://127.0.0.1:49400'
MAX_FILE_BYTES = 64 * 1024


def safe_path(value):
    """Refuse symlinks, including existing directory components."""
    path = Path(os.path.abspath(os.path.expanduser(str(value))))
    for part in (*reversed(path.parents), path):
        if part.is_symlink():
            raise ValueError('Symlink paths are not allowed')
    return path


def output_folder(value):
    path = safe_path(value)
    path.mkdir(mode=0o700, parents=True, exist_ok=True)
    info = path.stat()
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid():
        raise ValueError('Output must be a directory owned by this user')
    path.chmod(0o700)
    return path


def write_json(path, value, exclusive=False):
    safe_path(path)
    data = encode(value)
    if len(data) > MAX_FILE_BYTES:
        raise ValueError('Metadata storage cap reached')
    temporary = path if exclusive else path.with_name(path.name + '.tmp')
    fd = private_file(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL)
    try:
        with os.fdopen(fd, 'wb') as stream:
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
        if not exclusive:
            os.replace(str(temporary), str(path))
        directory_fd = os.open(str(path.parent), os.O_RDONLY)
        try:
            os.fsync(directory_fd)
        finally:
            os.close(directory_fd)
    finally:
        if not exclusive:
            temporary.unlink(missing_ok=True)


def lock_output(output):
    stream = os.fdopen(private_file(output / 'sender.lock', os.O_RDWR | os.O_CREAT), 'w')
    try:
        fcntl.flock(stream, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        stream.close()
        raise ValueError('A sender already owns this output folder')
    return stream


def run_cli(arguments):
    """No raw CLI output/errors retained; private identity bytes never read here."""
    try:
        result = subprocess.run([CLI, *arguments, '--node', NODE], capture_output=True, timeout=20)
        if result.returncode:
            return None, {'kind': 'cliFailed', 'exitCode': result.returncode}
        if len(result.stdout) > 24 * 1024 * 1024:
            return None, {'kind': 'outputTooLarge'}
        return json.loads(result.stdout), None
    except subprocess.TimeoutExpired:
        return None, {'kind': 'cliTimedOut'}
    except OSError:
        return None, {'kind': 'cliUnavailable'}
    except (ValueError, UnicodeError):
        return None, {'kind': 'invalidJSON'}


def receipts(events, run, author, community):
    if not isinstance(events, list):
        raise ValueError('Invalid verified event list')
    expected = {body(run, sequence): sequence for sequence in range(1, COUNT + 1)}
    found = []
    for event in events:
        if (event.get('kind') == 'message' and event.get('author') == author
                and event.get('community') == community and event.get('body') in expected
                and re.fullmatch('[0-9a-f]{64}', event.get('id', ''))):
            found.append({'id': event['id'], 'sequence': expected[event['body']],
                          'createdAtMilliseconds': event['createdAt']})
    if len(found) > 64:
        raise ValueError('Unexpected test event count')
    return found


def reconcile(args, call=run_cli):
    value, error = call(['events'])
    if error:
        return {'verificationError': error, 'verifiedAt': stamp()}
    try:
        found = receipts(value, args.run, args.author, args.community)
        return {'verifiedTestEvents': found, 'signaturesVerifiedByInstalledCLI': True,
                'verifiedAt': stamp()}
    except (ValueError, TypeError, KeyError, AttributeError):
        return {'verificationError': {'kind': 'invalidEvents'}, 'verifiedAt': stamp()}


def attempt(args, output, sequence, scheduled, call=run_cli, now=time.time):
    """Reserve BEFORE signing/submission. This function never repeats a post."""
    path = output / 'slot-{:02d}.json'.format(sequence)
    state = {'sequence': sequence, 'scheduledAt': stamp(scheduled),
             'attemptedAt': stamp(now()), 'state': 'attemptReserved',
             'scope': 'If interrupted here, submission outcome is unknown. Never resend this slot.'}
    write_json(path, state, exclusive=True)
    value, error = call(['post', '--identity', args.identity, '--community', args.community,
                         '--body', body(args.run, sequence)])
    state['completedAt'] = stamp(now())
    if (not error and isinstance(value, dict)
            and re.fullmatch('[0-9a-f]{64}', value.get('id', ''))
            and value.get('result') in ('accepted', 'already-present')):
        state.update(state='acknowledgedLocally', id=value['id'], result=value['result'])
    else:
        state.update(state='unknown', error=error or {'kind': 'invalidAcknowledgement'})
    write_json(path, state)
    verification = reconcile(args, call)
    state.update(verification)
    state['verifiedTestEvents'] = [entry for entry in state.get('verifiedTestEvents', [])
                                   if entry['sequence'] == sequence]
    write_json(path, state)
    return state


def slot_action(started, index, now):
    scheduled = started + index * INTERVAL
    if now < scheduled:
        return 'wait'
    if now >= started + DURATION or now - scheduled > GRACE:
        return 'skip'
    return 'send'


def send(args):
    os.umask(0o077)
    output = output_folder(args.output)
    with lock_output(output):
        if any(output.glob('slot-*.json')) or (output / 'manifest.json').exists():
            raise ValueError('Use a new output folder; old runs cannot be resumed or replayed')
        if (output / 'STOP').exists():
            raise ValueError('Output contains a stop request')
        # Check local readiness and previous messages before creating this run.
        diagnostics, error = run_cli(['diagnostics'])
        node = diagnostics.get('node', {}) if isinstance(diagnostics, dict) else {}
        if error or not node.get('listening') or node.get('paused') or not node.get('internetEnabled'):
            raise ValueError('Local app must be listening, unpaused, and internet-enabled')
        baseline = reconcile(args)
        if 'verificationError' in baseline or baseline['verifiedTestEvents']:
            raise ValueError('Cannot verify a fresh run marker; no messages posted')
        started = time.time()
        write_json(output / 'manifest.json', {'schemaVersion': 1, 'run': args.run,
            'author': args.author, 'community': args.community, 'label': 'Mac-A',
            'pid': os.getpid(), 'startedAt': stamp(started), 'scheduledEndAt': stamp(started + DURATION),
            'maximumMessages': COUNT, 'intervalSeconds': INTERVAL, 'lateSlotGraceSeconds': GRACE,
            'keepsMacAwake': False, 'automaticRetries': False,
            'scope': 'Local acknowledgement is not receiver delivery. An uncertain submission is never retried.'}, exclusive=True)
        stopped = [False]
        for sig in (signal.SIGINT, signal.SIGTERM):
            signal.signal(sig, lambda *_: stopped.__setitem__(0, True))
        index = 0
        attempted = 0
        skipped = 0
        reason = 'durationComplete'
        previous = started
        while True:
            now = time.time()
            if now < previous - 2:
                reason = 'clockMovedBackward'; break
            previous = now
            if stopped[0] or (output / 'STOP').exists():
                reason = 'stopped'; break
            if index < COUNT:
                action = slot_action(started, index, now)
                scheduled = started + index * INTERVAL
                if action == 'send':
                    result = attempt(args, output, index + 1, scheduled)
                    attempted += 1
                    index += 1
                    write_json(output / 'status.json', {'state': 'running', 'pid': os.getpid(),
                        'attempted': attempted, 'skipped': skipped, 'updatedAt': stamp(),
                        'lastSlotState': result['state'], 'nextSequence': index + 1 if index < COUNT else None})
                    verified = result.get('verifiedTestEvents', [])
                    if len(verified) > 1:
                        reason = 'duplicateTestEvents'; break
                    if (result.get('signaturesVerifiedByInstalledCLI')
                            and result['state'] == 'acknowledgedLocally'
                            and not any(event['id'] == result['id'] for event in verified)):
                        reason = 'acknowledgedEventNotVerified'; break
                    continue
                if action == 'skip':
                    write_json(output / 'slot-{:02d}.json'.format(index + 1),
                        {'sequence': index + 1, 'state': 'skipped', 'scheduledAt': stamp(scheduled),
                         'observedAt': stamp(now), 'reason': 'slotMissedNoCatchUp'}, exclusive=True)
                    skipped += 1
                    index += 1
                    continue
            if now >= started + DURATION:
                break
            time.sleep(1)
        final = {'state': 'finished', 'reason': reason, 'pid': os.getpid(),
                 'attempted': attempted, 'skipped': skipped, 'finishedAt': stamp()}
        final.update(reconcile(args))
        write_json(output / 'status.json', final)


def status(value):
    output = safe_path(value)
    result = {'output': str(output), 'senderLockHeld': False}
    for name in ('manifest', 'status'):
        path = safe_path(output / (name + '.json'))
        if path.exists():
            with os.fdopen(private_file(path, os.O_RDONLY), 'rb') as stream:
                data = stream.read(MAX_FILE_BYTES + 1)
            if len(data) > MAX_FILE_BYTES:
                raise ValueError('Oversized metadata')
            result[name] = json.loads(data)
    path = safe_path(output / 'sender.lock')
    if path.exists():
        with os.fdopen(private_file(path, os.O_RDONLY), 'r') as stream:
            try:
                fcntl.flock(stream, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                result['senderLockHeld'] = True
    print(json.dumps(result, indent=2))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest='command', required=True)
    for name in ('send', 'start'):
        p = sub.add_parser(name)
        p.add_argument('--run', required=True)
        p.add_argument('--identity', required=True, help='Existing private Mac A identity, never recreated')
        p.add_argument('--author', required=True, help='Expected public signing key for that identity')
        p.add_argument('--community', required=True)
        p.add_argument('--output', required=True)
    for name in ('status', 'stop'):
        p = sub.add_parser(name)
        p.add_argument('--output', required=True)
    args = parser.parse_args()
    if args.command == 'status':
        return status(args.output)
    if args.command == 'stop':
        path = safe_path(Path(args.output).expanduser() / 'STOP')
        with os.fdopen(private_file(path, os.O_WRONLY | os.O_CREAT), 'w'):
            pass
        return
    if not re.fullmatch('[A-Za-z0-9-]{1,64}', args.run):
        parser.error('Run marker must be 1-64 letters, digits, or hyphens')
    if not re.fullmatch('[0-9a-f]{64}', args.community):
        parser.error('Community must be a 64-character lowercase hex ID')
    try:
        author = base64.b64decode(args.author, validate=True)
        if len(author) != 32 or base64.b64encode(author).decode() != args.author:
            raise ValueError()
    except ValueError:
        parser.error('Author must be the canonical base64 public signing key')
    identity = safe_path(args.identity)
    info = identity.stat()
    if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
        parser.error('Identity must be an existing private regular file owned by this user')
    args.identity = str(identity)
    if args.command == 'send':
        return send(args)
    os.umask(0o077)
    output = output_folder(args.output)
    if (output / 'manifest.json').exists() or any(output.glob('slot-*.json')):
        raise ValueError('Use a new output folder; old runs cannot be resumed or replayed')
    with os.fdopen(private_file(output / 'launcher.log', os.O_WRONLY | os.O_CREAT | os.O_EXCL), 'wb') as log:
        command = [sys.executable, str(Path(__file__).resolve()), 'send', '--run', args.run,
                   '--identity', args.identity, '--author', args.author, '--community', args.community,
                   '--output', str(output)]
        child = subprocess.Popen(command, stdin=subprocess.DEVNULL, stdout=log, stderr=log,
                                 start_new_session=True, close_fds=True)
    for _ in range(100):
        if child.poll() is not None or (output / 'status.json').exists():
            break
        time.sleep(0.5)
    if not (output / 'status.json').exists():
        raise ValueError('No initial sender result; inspect private launcher.log and slot files. Never resend an uncertain slot.')
    status(output)


if __name__ == '__main__':
    try:
        main()
    except (OSError, ValueError) as error:
        print('Sender stopped: {}'.format(error), file=sys.stderr)
        sys.exit(1)
