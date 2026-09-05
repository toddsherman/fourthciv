#!/usr/bin/env python3
"""Render the deliberately small changelog format as safe release notes."""
import argparse
import html
import pathlib
import re

ROOT = pathlib.Path(__file__).resolve().parents[1]
HEADING = re.compile(r'^## \[([^\]]+)\](?: - (\d{4}-\d{2}-\d{2}))?$')


def entries(text):
    result = []
    current = None
    for line in text.splitlines():
        match = HEADING.fullmatch(line)
        if match:
            current = dict(version=match[1], date=match[2], lines=[])
            if any(item['version'] == current['version'] for item in result):
                raise ValueError('Duplicate changelog version: ' + current['version'])
            result.append(current)
        elif current is not None:
            current['lines'].append(line)
    return result


def notes(version, text=None):
    text = text if text is not None else (ROOT / 'CHANGELOG.md').read_text()
    for entry in entries(text):
        if entry['version'] == version:
            if not entry['date'] or not any(line.startswith('- ') for line in entry['lines']):
                raise ValueError('A release needs a date and change notes')
            return entry
    raise ValueError('Missing changelog entry: ' + version)


def render(lines):
    output = []
    in_list = False
    for line in lines:
        if not line.strip():
            continue
        if not line.startswith('- ') and in_list:
            output.append('</ul>')
            in_list = False
        if line.startswith('### '):
            output.append('<h3>' + html.escape(line[4:]) + '</h3>')
        elif line.startswith('- '):
            if not in_list:
                output.append('<ul>')
                in_list = True
            output.append('<li>' + html.escape(line[2:]) + '</li>')
        else:
            output.append('<p>' + html.escape(line) + '</p>')
    if in_list:
        output.append('</ul>')
    return '\n'.join(output)


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('version', nargs='?')
    parser.add_argument('--format', choices=['html', 'markdown'], default='html')
    parser.add_argument('--page-content', action='store_true')
    args = parser.parse_args()
    if args.page_content:
        for entry in entries((ROOT / 'CHANGELOG.md').read_text()):
            if entry['version'] == 'Unreleased':
                continue
            entry = notes(entry['version'])
            version = html.escape(entry['version'])
            date = html.escape(entry['date'])
            print(f'<article class="release-entry" id="v{version}"><p class="eyebrow"><time datetime="{date}">{date}</time></p><h2>Version {version}</h2>')
            print(render(entry['lines']))
            print('</article>')
        raise SystemExit(0)
    if not args.version:
        parser.error('Provide a version or --page-content')
    entry = notes(args.version)
    print(render(entry['lines']) if args.format == 'html' else '\n'.join(entry['lines']).strip())
