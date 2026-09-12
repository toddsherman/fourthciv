#!/usr/bin/env python3
"""Scan tracked working files; optionally include non-ignored additions and Git history.

This deliberately reads no ignored/untracked credential files by default. Findings
contain locations and detector categories only, never matched text. A clean result
is not proof that the repository has no secrets: unknown formats, binary/oversized
files, ignored files, and unreachable Git objects are outside this pattern scan.
"""

import argparse
import json
import pathlib
import re
import subprocess
import sys


MAX_BYTES = 2_000_000
RULES = {
    'private-key-block': rb'-----BEGIN (?:RSA |EC |OPENSSH |DSA |ENCRYPTED )?PRIVATE KEY-----',
    'github-token': rb'\b(?:gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{30,})\b',
    'aws-access-key': rb'\b(?:AKIA|ASIA)[A-Z0-9]{16}\b',
    'slack-token': rb'\bxox[baprs]-[A-Za-z0-9-]{20,}\b',
    'openai-key': rb'\bsk-(?:proj-|svcacct-)?[A-Za-z0-9_-]{32,}\b',
    'credentialed-database-url': (
        rb'\b(?:postgres(?:ql)?|mysql|mongodb(?:\+srv)?):\/\/'
        rb'[^\s\x22\x27<>:$]+:[^\s\x22\x27<>@$]+@[^\s\x22\x27<>]+'
    ),
    'literal-agent-private-key': (
        rb'[\x22\x27]privateKey[\x22\x27]\s*:\s*'
        rb'[\x22\x27][A-Za-z0-9+/]{40,}={0,2}[\x22\x27]'
    ),
    'literal-sensitive-assignment': (
        rb'(?im)^\s*(?:export\s+)?[\x22\x27]?'
        rb'(?:DATABASE_URL|FOURTHCIV_SPARKLE_PRIVATE_KEY|FOURTHCIV_REQUEST_KEY|'
        rb'GITHUB_TOKEN|GH_TOKEN|OPENAI_API_KEY|ANTHROPIC_API_KEY)'
        rb'[\x22\x27]?\s*[:=]\s*[\x22\x27]?[A-Za-z0-9+/_=-]{28,}'
    ),
}
DETECTORS = {name: re.compile(pattern) for name, pattern in RULES.items()}


def detect(data, path):
    """Return only redacted locations; callers decide size/binary exclusions."""
    findings = []
    for category, pattern in DETECTORS.items():
        for match in pattern.finditer(data):
            findings.append({'path': path, 'line': data.count(b'\n', 0, match.start()) + 1,
                             'category': category})
    return findings


def git(repo, *args, input_data=None):
    # Do not relay subprocess stderr, which could contain content from Git helpers.
    return subprocess.run(['git', '-C', str(repo), *args], input=input_data,
                          stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=True).stdout


def counters():
    return {'text_scanned': 0, 'binary_skipped': 0, 'oversized_skipped': 0,
            'symlink_or_external_skipped': 0, 'missing_skipped': 0}


def check_data(data, path, counts, findings):
    if len(data) > MAX_BYTES:
        counts['oversized_skipped'] += 1
    elif b'\0' in data:
        counts['binary_skipped'] += 1
    else:
        counts['text_scanned'] += 1
        findings.extend(detect(data, path))


def scan_current(repo, include_untracked=False):
    names = set(git(repo, 'ls-files', '-z').split(b'\0'))
    if include_untracked:
        names.update(git(repo, 'ls-files', '--others', '--exclude-standard', '-z').split(b'\0'))
    counts, findings, errors = counters(), [], []
    for raw_name in sorted(names - {b''}):
        name = raw_name.decode('utf-8', errors='surrogateescape')
        path = repo / name
        try:
            if path.is_symlink() or not path.resolve().is_relative_to(repo):
                counts['symlink_or_external_skipped'] += 1
                continue
            if not path.exists():
                counts['missing_skipped'] += 1
                continue
            if not path.is_file():
                errors.append({'path': name, 'category': 'not-a-regular-file'})
                continue
            if path.stat().st_size > MAX_BYTES:
                counts['oversized_skipped'] += 1
                continue
            # Keep buffering bounded if a file grows after the stat check.
            with path.open('rb') as source:
                check_data(source.read(MAX_BYTES + 1), name, counts, findings)
        except OSError:
            errors.append({'path': name, 'category': 'unreadable-file'})
    return counts, findings, errors


def scan_history(repo):
    paths = {}
    for line in git(repo, 'rev-list', '--objects', '--all').splitlines():
        oid, _, path = line.partition(b' ')
        if re.fullmatch(rb'[a-f0-9]{40,64}', oid):
            paths.setdefault(oid, path.decode('utf-8', errors='surrogateescape') or '<unnamed Git object>')
    counts, findings = counters(), []
    counts['reachable_blobs'] = 0
    if not paths:
        return counts, findings
    metadata = git(repo, 'cat-file', '--batch-check=%(objectname) %(objecttype) %(objectsize)',
                   input_data=b'\n'.join(paths) + b'\n')
    for line in metadata.splitlines():
        oid, kind, size = line.split()
        if kind != b'blob':
            continue
        counts['reachable_blobs'] += 1
        if int(size) > MAX_BYTES:
            counts['oversized_skipped'] += 1
            continue
        data = git(repo, 'cat-file', 'blob', oid.decode('ascii'))
        check_data(data, 'history:' + paths[oid], counts, findings)
    # The same location can occur in multiple revisions. Keep output compact/redacted.
    unique = {json.dumps(finding, sort_keys=True): finding for finding in findings}
    return counts, list(unique.values())


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--repo', type=pathlib.Path, default=pathlib.Path.cwd(), help='Repository or directory inside it')
    parser.add_argument('--include-untracked', action='store_true', help='Also scan non-ignored new working files')
    parser.add_argument('--history', action='store_true', help='Also scan blobs reachable from local Git refs')
    args = parser.parse_args(argv)
    try:
        repo = pathlib.Path(git(args.repo, 'rev-parse', '--show-toplevel').decode().strip()).resolve()
        current, findings, errors = scan_current(repo, args.include_untracked)
        result = {'current': current, 'findings': findings, 'errors': errors}
        if args.history:
            history, historical_findings = scan_history(repo)
            result['history'] = history
            findings.extend(historical_findings)
        print(json.dumps(result, indent=2, ensure_ascii=True))
        return 2 if errors else 1 if findings else 0
    except (OSError, subprocess.CalledProcessError, ValueError):
        print(json.dumps({'errors': [{'category': 'repository-scan-failed'}]}))
        return 2


if __name__ == '__main__':
    sys.exit(main())
