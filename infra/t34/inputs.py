"""Materialize release build inputs from immutable Git objects only."""
import io
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import subprocess
import sys
import tarfile


CANDIDATE_PATHS = (
    'server',
    'admin',
    'infra/t34',
    '.github/workflows/t34-release.yml',
    '.github/workflows/t34-isolated-proof.yml',
)
PRIOR_PATHS = ('server', 'admin')


def _git(repo, *args):
    result = subprocess.run(
        ['git', '-C', str(repo), *args],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    if result.returncode:
        raise ValueError('git input resolution failed')
    return result.stdout.decode().strip()


def _empty_directory(path):
    path = Path(path)
    if path.exists():
        if not path.is_dir() or any(path.iterdir()):
            raise ValueError('staging directory must be empty')
    else:
        path.mkdir(parents=True, mode=0o700)
    return path


def _extract(blob, destination):
    """Extract a Git archive without trusting archive paths or link objects."""
    try:
        archive = tarfile.open(fileobj=io.BytesIO(blob), mode='r:')
    except tarfile.TarError as error:
        raise ValueError('candidate archive invalid') from error
    with archive:
        for member in archive.getmembers():
            relative = PurePosixPath(member.name)
            if relative.is_absolute() or '..' in relative.parts or not relative.parts:
                raise ValueError('candidate archive path invalid')
            target = destination.joinpath(*relative.parts)
            if member.isdir():
                target.mkdir(parents=True, exist_ok=True)
                continue
            if not member.isfile():
                raise ValueError('candidate archive links are forbidden')
            target.parent.mkdir(parents=True, exist_ok=True)
            source = archive.extractfile(member)
            if source is None:
                raise ValueError('candidate archive file missing')
            with source, target.open('wb') as output:
                shutil.copyfileobj(source, output)
            target.chmod(member.mode & 0o777)


def _archive(repo, object_id, paths, destination):
    blob = subprocess.run(
        ['git', '-C', str(repo), 'archive', '--format=tar', object_id, '--', *paths],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    if blob.returncode:
        raise ValueError('candidate archive failed')
    _extract(blob.stdout, destination)


def stage_inputs(repo, current, prior, tree=None, previous_commit=None):
    """Stage the whitelisted candidate tree and the explicit rollback commit."""
    repo = Path(repo).resolve()
    current = Path(current).resolve()
    prior = Path(prior).resolve()
    if current == prior:
        raise ValueError('candidate and prior staging directories must differ')
    if _git(repo, 'rev-parse', '--show-toplevel') != str(repo):
        raise ValueError('input repository root invalid')

    candidate = tree if tree is not None else os.environ.get('T34_CANDIDATE_TREE')
    if candidate is None:
        candidate = _git(repo, 'rev-parse', 'HEAD^{tree}')
    if not re.fullmatch(r'[0-9a-f]{40,64}', candidate):
        raise ValueError('candidate tree must be a full Git object ID')
    object_type = subprocess.run(
        ['git', '-C', str(repo), 'cat-file', '-t', candidate],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    if object_type.returncode:
        raise ValueError('candidate tree object missing')
    if object_type.stdout.decode().strip() != 'tree':
        raise ValueError('candidate input must be a tree object')

    if not re.fullmatch(r'[0-9a-f]{40}', previous_commit or ''):
        raise ValueError('previous rollback revision must be a full commit SHA')
    previous_type = subprocess.run(
        ['git', '-C', str(repo), 'cat-file', '-t', previous_commit],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    if previous_type.returncode:
        raise ValueError('previous rollback object missing')
    if previous_type.stdout.strip() != b'commit':
        raise ValueError('previous rollback input must be a commit object')

    _empty_directory(current)
    _empty_directory(prior)
    _archive(repo, candidate, CANDIDATE_PATHS, current)
    _archive(repo, previous_commit, PRIOR_PATHS, prior)

    candidate_infra = current / 'infra/t34'
    if not candidate_infra.is_dir():
        raise ValueError('candidate infra/t34 missing')
    prior_infra = prior / 'infra'
    prior_infra.mkdir(parents=True, exist_ok=True)
    shutil.copytree(candidate_infra, prior_infra / 't34', dirs_exist_ok=True)
    return candidate


def main(argv):
    if len(argv) != 5:
        raise ValueError('usage: inputs.py REPO CURRENT PRIOR PREVIOUS_COMMIT')
    repo, current, prior, previous = argv[1:]
    tree = stage_inputs(repo, current, prior, previous_commit=previous)
    print(tree)


if __name__ == '__main__':
    try:
        main(sys.argv)
    except (ValueError, OSError) as error:
        sys.exit(str(error))
