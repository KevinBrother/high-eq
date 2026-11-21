"""Check that a release is an append-only extension of the published SQL migrations."""
import argparse
from pathlib import PurePosixPath
import re
import subprocess
import sys

DIR = 'server/migrations'
NAME = re.compile(r'(\d{14})_([a-z][a-z0-9]*(?:_[a-z0-9]+)*)\.(up|down)\.sql', re.ASCII)


def versions(files):
    result = {}
    for filename in files:
        match = NAME.fullmatch(filename)
        if not match:
            raise ValueError(f'invalid migration filename: {filename}')
        version, name, direction = match.groups()
        other, directions = result.setdefault(version, (name, set()))
        if other != name:
            raise ValueError(f'duplicate version {version}: {name} and {other}')
        directions.add(direction)
    for version, (name, directions) in result.items():
        if directions != {'up', 'down'}:
            raise ValueError(f'missing up/down counterpart: {version}_{name}')
    return set(result)


def check_history(base, tip):
    for name, digest in base.items():
        if tip.get(name) != digest:
            raise ValueError(f'published migration removed or edited: {name}; add a new migration instead')
    old, new = versions(base), versions(tip)
    if old:
        highest = max(old)
        for version in new - old:
            if version <= highest:
                raise ValueError(f'{version} would be skipped after published version {highest}; renumber the unpublished pair')


def snapshot(rev):
    if rev == '0' * 40:  # First-ever main push, no published predecessor.
        return {}
    git_args = ['ls-files', '-s', '-z'] if rev == ':index' else ['ls-tree', '-rz', '--full-tree', rev]
    raw = subprocess.check_output(['git', *git_args, '--', DIR])
    files = {}
    for row in raw.split(b'\0'):
        if not row:
            continue
        metadata, path = row.decode('utf-8').split('\t', 1)
        if path.endswith('.sql'):
            mode, middle, last = metadata.split()
            if mode not in ('100644', '100755') or (rev == ':index' and last != '0'):
                raise ValueError(f'non-regular or unmerged SQL file: {path}')
            files[str(PurePosixPath(path).relative_to(DIR))] = middle if rev == ':index' else last
    return files


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('published', help='base commit SHA or origin/main')
    parser.add_argument('candidate', nargs='?', default='HEAD', help='tip commit or :index for staged files')
    args = parser.parse_args()
    try:
        check_history(snapshot(args.published), snapshot(args.candidate))
    except ValueError as err:
        sys.exit(str(err))
    print('OK: published migrations unchanged; new versions strictly follow the published release')
