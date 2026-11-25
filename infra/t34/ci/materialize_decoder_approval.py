#!/usr/bin/env python3
"""Materialize a protected decoder approval as one private external file."""
from __future__ import annotations

import argparse
import os
from pathlib import Path
import stat
import sys

HERE = Path(__file__).resolve().parents[1]
if str(HERE) not in sys.path:
    sys.path.insert(0, str(HERE))
import release_approval

SECRET_ENV = 'T34_DECODER_APPROVALS_JSON'
MAX_BYTES = 64 * 1024


def _inside(path: Path, root: Path) -> bool:
    try:
        path.relative_to(root)
        return True
    except ValueError:
        return False


def validate_destination(destination: Path, checkout: Path) -> Path:
    if not destination.is_absolute():
        raise ValueError('decoder approval destination must be absolute')
    checkout = checkout.resolve(strict=True)
    if destination.is_symlink():
        raise ValueError('decoder approval destination must not be a symlink')
    if _inside(destination.resolve(), checkout):
        raise ValueError('decoder approval destination must be outside the checkout')
    if destination.exists():
        info = destination.lstat()
        if not stat.S_ISREG(info.st_mode):
            raise ValueError('decoder approval destination must be a regular file')
        if stat.S_IMODE(info.st_mode) & 0o022:
            raise ValueError('existing decoder approval destination has unsafe permissions')
        raise ValueError('decoder approval destination already exists')
    parent = destination.parent
    if parent.is_symlink():
        raise ValueError('decoder approval destination parent must not be a symlink')
    try:
        resolved_parent = parent.resolve(strict=True)
    except OSError as error:
        raise ValueError('decoder approval destination parent missing') from error
    if not resolved_parent.is_dir() or resolved_parent.is_symlink():
        raise ValueError('decoder approval destination parent invalid')
    info = resolved_parent.stat()
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.geteuid():
        raise ValueError('decoder approval destination parent owner invalid')
    if stat.S_IMODE(info.st_mode) & 0o022:
        raise ValueError('decoder approval destination parent has unsafe permissions')
    return resolved_parent / destination.name


def materialize(raw: str, destination: Path, checkout: Path) -> tuple[Path, str]:
    if not isinstance(raw, str) or not raw.strip():
        raise ValueError(f'{SECRET_ENV} is empty')
    try:
        encoded = raw.encode('utf-8')
    except UnicodeEncodeError as error:
        raise ValueError(f'{SECRET_ENV} is not valid UTF-8') from error
    if len(encoded) > MAX_BYTES:
        raise ValueError(f'{SECRET_ENV} exceeds {MAX_BYTES} bytes')
    target = validate_destination(Path(destination), Path(checkout))
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
    if hasattr(os, 'O_NOFOLLOW'):
        flags |= os.O_NOFOLLOW
    descriptor = None
    try:
        descriptor = os.open(target, flags, 0o600)
        os.fchmod(descriptor, 0o600)
        with os.fdopen(descriptor, 'wb') as output:
            descriptor = None
            output.write(encoded)
            output.flush()
            os.fsync(output.fileno())
        document, document_sha256 = release_approval.load_document(target, (checkout,))
        if not document:
            raise ValueError('external decoder approval missing')
        if stat.S_IMODE(target.stat().st_mode) != 0o600:
            raise ValueError('decoder approval file permissions changed')
    except BaseException:
        target.unlink(missing_ok=True)
        raise
    finally:
        if descriptor is not None:
            os.close(descriptor)
    return target, document_sha256


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('checkout', type=Path)
    parser.add_argument('destination', type=Path)
    args = parser.parse_args(argv)
    os.umask(0o077)
    try:
        target, digest = materialize(
            os.environ.get(SECRET_ENV, ''), args.destination, args.checkout,
        )
    except (OSError, ValueError) as error:
        print(f'decoder approval not materialized: {error}', file=sys.stderr)
        return 1
    print(f'decoder approval materialized: {target}')
    print(f'decoder approval document sha256: {digest}')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
