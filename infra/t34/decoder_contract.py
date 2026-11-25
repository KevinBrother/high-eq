"""Content-addressed identity for the restored-score decoder and release artifact."""
import hashlib
import json
import os
from pathlib import Path
import re
import stat
import sys


CONTRACT_VERSION = 1
ARTIFACT_ROOTS = ('server', 'admin', 'infra/t34')
DECODER_PACKAGES = ('training', 'fieldcrypt', 'privacy', 'scoring', 'reviews', 'events')
DECODER_SUPPORT_FILES = ('server/go.mod', 'server/go.sum')
INTERNAL_IMPORT_PREFIX = 'high-eq/server/internal/'

_INTERNAL_IMPORT = re.compile(r'"(high-eq/server/internal/[^"\n]+)"')


def _inside(path, root):
    try:
        path.relative_to(root)
        return True
    except ValueError:
        return False


def _walk_regular(root, base):
    root = root.resolve()
    base = base.resolve()
    if not base.is_dir() or not _inside(base, root):
        raise ValueError('release artifact path missing: ' + str(base.relative_to(root)))
    for current, directories, files in os.walk(base, followlinks=False):
        current_path = Path(current)
        for name in directories:
            path = current_path / name
            if path.is_symlink():
                raise ValueError('release artifact links are forbidden')
        for name in files:
            path = current_path / name
            if path.is_symlink() or not stat.S_ISREG(path.stat().st_mode):
                raise ValueError('release artifact files must be regular')
            yield path


def artifact_sha256(source):
    """Hash the actual staged API/Web/ops release inputs, including file modes."""
    source = Path(source).resolve()
    digest = hashlib.sha256(b't34-release-artifact-v1\0')
    count = 0
    for rel_root in ARTIFACT_ROOTS:
        for path in sorted(_walk_regular(source, source / rel_root)):
            relative = path.relative_to(source).as_posix().encode()
            mode = b'100755' if path.stat().st_mode & 0o111 else b'100644'
            data = path.read_bytes()
            digest.update(relative + b'\0' + mode + b'\0' + str(len(data)).encode() + b'\0')
            digest.update(data)
            count += 1
    return digest.hexdigest(), count


def _package_files(source, package):
    package_root = source / 'server/internal' / package
    if not package_root.is_dir() or package_root.is_symlink():
        raise ValueError('recovery decoder package missing: ' + package)
    files = sorted(_walk_regular(source, package_root))
    go_files = [path for path in files if path.suffix == '.go' and not path.name.endswith('_test.go')]
    if not go_files:
        raise ValueError('recovery decoder package empty: ' + package)
    return package_root, files, go_files


def _dependency_closure(source):
    pending = list(DECODER_PACKAGES)
    packages = set()
    while pending:
        package = pending.pop()
        if package in packages:
            continue
        _, _, go_files = _package_files(source, package)
        packages.add(package)
        for path in go_files:
            for match in _INTERNAL_IMPORT.finditer(path.read_text(encoding='utf-8')):
                imported = match.group(1)[len(INTERNAL_IMPORT_PREFIX):]
                if imported and imported not in packages:
                    pending.append(imported)
    return sorted(packages)


def _update_file_digest(digest, kind, relative, path):
    """Frame kind, path, mode, length and bytes so file boundaries are unambiguous."""
    data = path.read_bytes()
    mode = b'100755' if path.stat().st_mode & 0o111 else b'100644'
    digest.update(kind + b'\0' + relative.encode() + b'\0' + mode + b'\0')
    digest.update(str(len(data)).encode() + b'\0' + data)


def decoder_sha256(source):
    """Hash the raw in-repository decoder package and resource closure.

    Go comments and line layout are deliberately covered. Newlines participate
    in automatic semicolon insertion, and directives such as //go:embed alter
    runtime behavior, so a lexical-only normalization would fail open.
    """
    source = Path(source).resolve()
    digest = hashlib.sha256(b't34-recovery-decoder-v3\0')
    files = []
    packages = _dependency_closure(source)
    for package in packages:
        package_root, package_files, go_files = _package_files(source, package)
        for path in go_files:
            relative = path.relative_to(source).as_posix()
            _update_file_digest(digest, b'go', relative, path)
            files.append(relative)
        for path in package_files:
            if path.suffix == '.go' or path.name == '.gitkeep':
                continue
            relative = path.relative_to(source).as_posix()
            _update_file_digest(digest, b'resource', relative, path)
            files.append(relative)
    for relative in DECODER_SUPPORT_FILES:
        path = source / relative
        if path.is_symlink() or not path.is_file():
            raise ValueError('recovery decoder support file missing: ' + relative)
        _update_file_digest(digest, b'support', relative, path)
        files.append(relative)
    return digest.hexdigest(), sorted(files)


def inspect_release(source):
    """Return the exact values that a detached release approval must bind."""
    packages = _dependency_closure(Path(source).resolve())
    artifact, artifact_files = artifact_sha256(source)
    decoder, decoder_files = decoder_sha256(source)
    return {
        'version': CONTRACT_VERSION,
        'artifact_sha256': artifact,
        'artifact_file_count': artifact_files,
        'decoder_sha256': decoder,
        'decoder_packages': list(DECODER_PACKAGES),
        'decoder_dependency_packages': packages,
        'decoder_files': decoder_files,
    }


def main(argv):
    if len(argv) != 2:
        raise ValueError('usage: decoder_contract.py RELEASE_SOURCE')
    print(json.dumps(inspect_release(Path(argv[1])), sort_keys=True))


if __name__ == '__main__':
    try:
        main(sys.argv)
    except (OSError, ValueError, UnicodeError) as error:
        sys.exit(str(error))
