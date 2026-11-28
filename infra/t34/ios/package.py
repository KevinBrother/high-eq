#!/usr/bin/env python3
"""Build and verify one iOS Release candidate requested with --no-codesign.

Only ``Runner.app.zip`` and ``receipt.json`` are published, into a directory
created exclusively for this run. A build is accepted only when it produced a
fresh ``Runner.app`` and the bundle matches the repository configuration.
Verification requires externally supplied commit, version, build number and
archive SHA256; it never trusts those values from the receipt alone.

No signing, notarization, upload, product-service access or cloud command is
used.

Usage:
    python3 infra/t34/ios/package.py --output-dir <new-dir> \
        [--expect-commit <sha>]
    python3 infra/t34/ios/package.py --verify <dir> \
        --expect-commit <sha> --expect-version <version> \
        --expect-build <number> --expect-sha256 <sha256>
"""
import argparse
import contextlib
from datetime import datetime, timezone
import hashlib
import ipaddress
import json
import os
from pathlib import Path, PurePosixPath
import plistlib
import platform as host_platform
import re
import shutil
import stat
import struct
import subprocess
import sys
import tempfile
import threading
import urllib.parse
import zipfile

REPO = Path(__file__).resolve().parents[3]
EXPECTED_FLUTTER = '3.38.10'
EXPECTED_DART = '3.10.9'
EXPECTED_BUNDLE_ID = 'cn.higheq.highEq'
EXPECTED_EXTENSION_ID = 'cn.higheq.highEq.ReplyShare'
EXPECTED_SHARE_POINT = 'com.apple.share-services'
BUNDLE_NAME = 'Runner.app'
ARCHIVE_NAME = 'Runner.app.zip'
RECEIPT_NAME = 'receipt.json'
SCHEMA = 't34-ios-package/v2'
MACHO_THIN_ARM64 = b'\xcf\xfa\xed\xfe'
CPU_TYPE_ARM64 = 0x0100000C
MACHO_FAT = (b'\xca\xfe\xba\xbe', b'\xca\xfe\xba\xbf')
LC_BUILD_VERSION = 0x32
LC_VERSION_MIN_IPHONEOS = 0x25
PLATFORM_IOS = 2
MH_EXECUTE = 2
MH_DYLIB = 6
PLACEHOLDER_HOSTS = {
    'example.com', 'example.net', 'example.org', 'example.invalid',
    'localhost', '127.0.0.1', '0.0.0.0', '::1', '::',
}
PLACEHOLDER_SUFFIXES = (
    '.invalid', '.test', '.example', '.local',
    '.example.com', '.example.net', '.example.org',
)
REQUIRED_BINARIES = {
    'Runner': (MH_EXECUTE,),
    'Frameworks/App.framework/App': (MH_EXECUTE, MH_DYLIB),
    'Frameworks/Flutter.framework/Flutter': (MH_EXECUTE, MH_DYLIB),
    'PlugIns/ReplyShare.appex/ReplyShare': (MH_EXECUTE,),
}
AOT_MARKERS = (b'_kDartVmSnapshotData', b'_kDartIsolateSnapshotData')
DECLARED_ASSET = ('Frameworks/App.framework/flutter_assets/assets/'
                  'contract_examples.json')


class PackageError(RuntimeError):
    pass


def parse_pubspec_version(text):
    match = re.search(
        r'(?m)^version:\s*([0-9]+(?:\.[0-9]+)+)\+([0-9]+)\s*$', text)
    if not match:
        raise PackageError('app/pubspec.yaml has no numeric version+build')
    return match.group(1), match.group(2)


def resolve_endpoint(cli_value, environ):
    if cli_value is not None:
        return endpoint_record(cli_value, 'cli')
    if 'T34_IOS_APP_ENDPOINT' in environ:
        return endpoint_record(environ['T34_IOS_APP_ENDPOINT'], 'environment')
    return endpoint_record(None, 'default')


def endpoint_record(value, source='default'):
    raw = '' if value is None else value.strip()
    if value is None or raw.lower() == 'mock':
        return {
            'value': 'mock',
            'type': 'mock-sample',
            'source': source,
        }
    if not raw:
        raise PackageError('APP_ENDPOINT is empty; pass "mock" explicitly')
    if any(char.isspace() for char in raw):
        raise PackageError('APP_ENDPOINT contains whitespace')
    if '?' in raw or '#' in raw:
        raise PackageError('APP_ENDPOINT must not carry a query or fragment')
    try:
        parts = urllib.parse.urlsplit(raw)
        port = parts.port
    except ValueError as error:
        raise PackageError('APP_ENDPOINT is not a valid URL: %s' % error)
    if parts.scheme != 'https':
        raise PackageError('APP_ENDPOINT must be an https origin (or "mock")')
    if not parts.hostname or parts.username or parts.password:
        raise PackageError('APP_ENDPOINT must have a host and no credentials')
    if parts.path not in ('', '/') or parts.query or parts.fragment:
        raise PackageError(
            'APP_ENDPOINT must be an origin without path, query or fragment')
    if port is not None and not 1 <= port <= 65535:
        raise PackageError('APP_ENDPOINT port is out of range')
    host = parts.hostname.lower().rstrip('.')
    if not host:
        raise PackageError('APP_ENDPOINT has an empty host')
    if host in PLACEHOLDER_HOSTS or host.endswith(PLACEHOLDER_SUFFIXES):
        raise PackageError('APP_ENDPOINT points at a placeholder host')
    try:
        address = ipaddress.ip_address(host)
    except ValueError:
        address = None
    if address is not None and (address.is_loopback or address.is_unspecified
                                or address.is_link_local
                                or address.is_multicast or address.is_reserved):
        raise PackageError('APP_ENDPOINT points at a placeholder address')
    netloc = '[%s]' % host if ':' in host else host
    if port is not None:
        netloc = '%s:%d' % (netloc, port)
    return {
        'value': 'https://' + netloc,
        'type': 'https',
        'source': source,
    }


def _require(condition, message):
    if not condition:
        raise PackageError(message)


def _read_plist(path):
    try:
        with path.open('rb') as handle:
            return plistlib.load(handle)
    except (OSError, plistlib.InvalidFileException, ValueError) as error:
        raise PackageError('cannot read %s: %s' % (path, error))


def _macho_platforms(data):
    if len(data) < 32:
        raise PackageError('truncated Mach-O binary')
    magic = data[:4]
    if magic == MACHO_THIN_ARM64:
        return _thin_macho(data)
    if magic in MACHO_FAT:
        return _fat_macho(data, magic == b'\xca\xfe\xba\xbf')
    raise PackageError('not a Mach-O binary')


def _thin_macho(data):
    cputype = struct.unpack_from('<i', data, 4)[0]
    filetype = struct.unpack_from('<I', data, 12)[0]
    ncmds = struct.unpack_from('<I', data, 16)[0]
    sizeofcmds = struct.unpack_from('<I', data, 20)[0]
    if cputype != CPU_TYPE_ARM64:
        raise PackageError('Mach-O slice is not arm64')
    if 32 + sizeofcmds > len(data):
        raise PackageError('truncated Mach-O load commands')
    platforms = set()
    offset = 32
    for _ in range(ncmds):
        if offset + 8 > len(data):
            raise PackageError('truncated Mach-O command')
        command, size = struct.unpack_from('<II', data, offset)
        if size < 8 or offset + size > len(data):
            raise PackageError('invalid Mach-O command size')
        if command == LC_BUILD_VERSION and size >= 24:
            platforms.add(struct.unpack_from('<I', data, offset + 8)[0])
        elif command == LC_VERSION_MIN_IPHONEOS:
            platforms.add(PLATFORM_IOS)
        offset += size
    if not platforms:
        raise PackageError('Mach-O has no platform information')
    return filetype, platforms


def _fat_macho(data, is64):
    entry_size = 32 if is64 else 20
    count = struct.unpack_from('>I', data, 4)[0]
    for index in range(count):
        base = 8 + index * entry_size
        if base + entry_size > len(data):
            raise PackageError('truncated fat Mach-O')
        cputype = struct.unpack_from('>i', data, base)[0]
        if cputype != CPU_TYPE_ARM64:
            continue
        if is64:
            offset, size = struct.unpack_from('>QQ', data, base + 8)
        else:
            offset, size = struct.unpack_from('>II', data, base + 8)
        if offset + size > len(data):
            raise PackageError('truncated fat Mach-O slice')
        try:
            filetype, platforms = _thin_macho(data[offset:offset + size])
        except PackageError:
            continue
        if PLATFORM_IOS in platforms:
            return filetype, platforms
    raise PackageError('fat Mach-O has no arm64 iOS device slice')


def _require_binary(path, allowed_filetypes, aot=False):
    _require(path.is_file() and not path.is_symlink(),
             'missing executable %s' % path)
    _require(path.stat().st_mode & 0o111,
             '%s is not executable' % path)
    data = path.read_bytes()
    filetype, platforms = _macho_platforms(data)
    _require(filetype in allowed_filetypes,
             '%s has unexpected Mach-O file type %d' % (path, filetype))
    _require(PLATFORM_IOS in platforms,
             '%s is not an iOS device binary' % path)
    if aot:
        for marker in AOT_MARKERS:
            _require(marker in data,
                     '%s does not contain Dart AOT static marker %s'
                     % (path, marker.decode()))
    return filetype


def _check_symlink(source, root):
    target = os.readlink(source)
    _require(target and not os.path.isabs(target),
             'symlink %s has an absolute or empty target' % source)
    try:
        resolved = (source.parent / target).resolve()
        root = root.resolve()
    except (OSError, RuntimeError) as error:
        raise PackageError('cannot resolve symlink %s: %s' % (source, error))
    _require(resolved == root or root in resolved.parents,
             'symlink %s escapes the bundle' % source)
    _require(resolved.exists(), 'symlink %s is broken' % source)


def _iter_tree(path, base):
    root = base.resolve()
    for child in sorted(path.iterdir(), key=lambda item: item.name):
        relative = child.relative_to(base)
        if child.is_symlink():
            _check_symlink(child, root)
            yield 'link', relative, child
        elif child.is_dir():
            yield 'dir', relative, child
            for item in _iter_tree(child, base):
                yield item
        elif child.is_file():
            yield 'file', relative, child
        else:
            raise PackageError('unsupported file type: %s' % child)


def inspect_bundle(bundle, version, build_number):
    """Validate a Runner.app against the repository's fixed configuration.

    This is a static layout and marker check. It does not verify a code
    signature or prove that the bundle is signed for release.
    """
    bundle = Path(bundle)
    _require(bundle.is_dir() and not bundle.is_symlink(),
             'missing app bundle %s' % bundle)
    list(_iter_tree(bundle, bundle))
    for relative, filetypes in REQUIRED_BINARIES.items():
        _require_binary(bundle / relative, filetypes,
                        aot=relative == 'Frameworks/App.framework/App')
    asset = bundle / DECLARED_ASSET
    _require(asset.is_file() and asset.stat().st_size > 0,
             'missing or empty declared Flutter asset %s' % DECLARED_ASSET)
    runner = _read_plist(bundle / 'Info.plist')
    extension = _read_plist(
        bundle / 'PlugIns/ReplyShare.appex/Info.plist')
    _require(runner.get('CFBundleIdentifier') == EXPECTED_BUNDLE_ID,
             'unexpected Runner bundle identifier %r'
             % runner.get('CFBundleIdentifier'))
    _require(runner.get('CFBundleExecutable') == 'Runner',
             'unexpected Runner executable %r'
             % runner.get('CFBundleExecutable'))
    _require(runner.get('CFBundleShortVersionString') == version,
             'bundle version %r does not match %r'
             % (runner.get('CFBundleShortVersionString'), version))
    _require(runner.get('CFBundleVersion') == build_number,
             'bundle build %r does not match %r'
             % (runner.get('CFBundleVersion'), build_number))
    _require(runner.get('DTPlatformName') == 'iphoneos',
             'bundle is not a device build (DTPlatformName=%r)'
             % runner.get('DTPlatformName'))
    _require(extension.get('CFBundleIdentifier') == EXPECTED_EXTENSION_ID,
             'unexpected ReplyShare bundle identifier %r'
             % extension.get('CFBundleIdentifier'))
    _require(extension.get('CFBundleExecutable') == 'ReplyShare',
             'unexpected ReplyShare executable %r'
             % extension.get('CFBundleExecutable'))
    _require(extension.get('CFBundlePackageType') == 'XPC!',
             'ReplyShare.appex is not an app extension')
    nested = extension.get('NSExtension') or {}
    _require(nested.get('NSExtensionPointIdentifier') == EXPECTED_SHARE_POINT,
             'ReplyShare.appex is not a share extension')
    _require(extension.get('CFBundleShortVersionString') == version,
             'ReplyShare version does not match the app version')
    _require(extension.get('CFBundleVersion') == build_number,
             'ReplyShare build does not match the app build')
    _require(not (bundle / 'embedded.mobileprovision').exists(),
             'bundle carries a provisioning profile; '
             'a --no-codesign candidate cannot carry one')
    return {
        'bundle_id': runner['CFBundleIdentifier'],
        'extension_bundle_id': extension['CFBundleIdentifier'],
        'version': version,
        'build_number': build_number,
    }


def _zip_info(name, mode, compress):
    info = zipfile.ZipInfo(name, date_time=(1980, 1, 1, 0, 0, 0))
    info.create_system = 3
    info.external_attr = mode << 16
    if stat.S_ISDIR(mode):
        info.external_attr |= 0x10
    info.compress_type = compress
    return info


def build_archive(bundle, destination):
    bundle = Path(bundle)
    destination = Path(destination)
    destination.parent.mkdir(parents=True, exist_ok=True)
    entries = list(_iter_tree(bundle, bundle))
    with zipfile.ZipFile(destination, 'w') as archive:
        for kind, relative, source in entries:
            name = '%s/%s' % (BUNDLE_NAME, relative.as_posix())
            if kind == 'dir':
                archive.writestr(
                    _zip_info(name + '/', stat.S_IFDIR
                              | (source.stat().st_mode & 0o777),
                              zipfile.ZIP_STORED), b'')
            elif kind == 'link':
                archive.writestr(
                    _zip_info(name, stat.S_IFLNK | 0o777,
                              zipfile.ZIP_STORED),
                    os.readlink(source).encode())
            else:
                archive.writestr(
                    _zip_info(name, stat.S_IFREG
                              | (source.stat().st_mode & 0o777),
                              zipfile.ZIP_DEFLATED),
                    source.read_bytes())
    digest = hashlib.sha256()
    with destination.open('rb') as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b''):
            digest.update(chunk)
    return {'sha256': digest.hexdigest(),
            'bytes': destination.stat().st_size}


def _reject_unsafe_name(name):
    _require(name and not name.startswith('/') and '\\' not in name
             and '\0' not in name, 'unsafe archive entry name %r' % name)
    parts = PurePosixPath(name).parts
    _require(all(part not in ('', '.', '..') for part in parts),
             'unsafe archive entry name %r' % name)
    return parts


def extract_archive(archive, destination):
    """Restore a Runner.app.zip with modes and links into a new directory."""
    destination = Path(destination)
    _require(not destination.exists() and not destination.is_symlink(),
             'restore destination already exists: %s' % destination)
    destination.mkdir(parents=True)
    root = destination.resolve()
    links = []
    try:
        with zipfile.ZipFile(archive) as zipped:
            _require(zipped.testzip() is None, 'archive is corrupt')
            infos = zipped.infolist()
            names = [info.filename for info in infos]
            _require(len(names) == len(set(names)),
                     'archive contains duplicate entries')
            for info in infos:
                parts = _reject_unsafe_name(info.filename)
                target = destination.joinpath(*parts)
                resolved = target.resolve(strict=False)
                _require(resolved == root or root in resolved.parents,
                         'archive entry escapes the restore directory')
                mode = info.external_attr >> 16
                filetype = stat.S_IFMT(mode)
                if filetype == stat.S_IFDIR:
                    target.mkdir(parents=True, exist_ok=True)
                    target.chmod(stat.S_IMODE(mode))
                elif filetype == stat.S_IFLNK:
                    target.parent.mkdir(parents=True, exist_ok=True)
                    try:
                        link = zipped.read(info).decode('utf-8')
                    except UnicodeDecodeError:
                        raise PackageError('archive symlink target is not UTF-8')
                    _require(link and not os.path.isabs(link),
                             'archive symlink has an absolute or empty target')
                    if target.exists() or target.is_symlink():
                        target.unlink()
                    os.symlink(link, target)
                    links.append(target)
                elif filetype == stat.S_IFREG:
                    target.parent.mkdir(parents=True, exist_ok=True)
                    with zipped.open(info) as source, target.open('wb') as out:
                        shutil.copyfileobj(source, out)
                    target.chmod(stat.S_IMODE(mode))
                else:
                    raise PackageError(
                        'archive entry lacks supported Unix metadata: %r'
                        % info.filename)
        for link in links:
            resolved = link.resolve()
            _require(resolved == root or root in resolved.parents,
                     'archive symlink escapes the restore directory')
            _require(resolved.exists(), 'archive symlink is broken')
        return destination
    except BaseException:
        shutil.rmtree(destination, ignore_errors=True)
        raise


def _check_receipt_shape(receipt):
    _require(isinstance(receipt, dict), 'receipt is not an object')
    for key in ('schema', 'source', 'app', 'endpoint', 'environment',
                'artifact', 'limitations'):
        _require(key in receipt, 'receipt is missing %s' % key)
    _require(receipt['schema'] == SCHEMA, 'unexpected receipt schema')
    source = receipt['source']
    _require(isinstance(source, dict), 'receipt source is not an object')
    _require(source.get('clean') is True, 'receipt source tree is not clean')
    _require(isinstance(source.get('commit'), str)
             and re.fullmatch(r'[0-9a-f]{40}', source['commit']),
             'receipt source commit is not a full SHA')
    app = receipt['app']
    _require(isinstance(app, dict), 'receipt app is not an object')
    for key in ('version', 'build_number', 'bundle_id',
                'extension_bundle_id'):
        _require(isinstance(app.get(key), str) and app[key],
                 'receipt app.%s is missing' % key)
    endpoint = receipt['endpoint']
    _require(isinstance(endpoint, dict), 'receipt endpoint is not an object')
    _require(isinstance(endpoint.get('value'), str) and endpoint['value']
             and endpoint.get('type') in ('mock-sample', 'https'),
             'receipt endpoint is not classified')
    _require(endpoint.get('source') in ('default', 'cli', 'environment'),
             'receipt endpoint source is not classified')
    environment = receipt['environment']
    _require(isinstance(environment, dict),
             'receipt environment is not an object')
    for key in ('flutter', 'dart', 'xcode', 'macos', 'arch'):
        _require(isinstance(environment.get(key), str) and environment[key],
                 'receipt environment.%s is missing' % key)
    artifact = receipt['artifact']
    _require(isinstance(artifact, dict), 'receipt artifact is not an object')
    _require(artifact.get('name') == ARCHIVE_NAME,
             'receipt artifact name is not %s' % ARCHIVE_NAME)
    _require(artifact.get('bundle') == BUNDLE_NAME,
             'receipt artifact bundle is not %s' % BUNDLE_NAME)
    _require(isinstance(artifact.get('sha256'), str)
             and re.fullmatch(r'[0-9a-f]{64}', artifact['sha256']),
             'receipt artifact SHA256 is missing')
    _require(isinstance(artifact.get('bytes'), int) and artifact['bytes'] > 0,
             'receipt artifact size is missing')
    _require(isinstance(receipt['limitations'], list)
             and receipt['limitations'], 'receipt limitations are missing')


def write_receipt(path, receipt):
    Path(path).write_text(
        json.dumps(receipt, indent=2, sort_keys=True) + '\n', encoding='utf-8')


def validate_output_location(output_dir, app_dir):
    output_dir = Path(output_dir)
    resolved = output_dir.resolve(strict=False)
    app = Path(app_dir).resolve()
    _require(not resolved.exists(),
             'output directory already exists: %s' % output_dir)
    _require(resolved != resolved.parent,
             'output directory cannot be a filesystem root')
    _require(not (resolved == app or app in resolved.parents
                  or resolved in app.parents),
             'output directory must not overlap the app source tree')


def package_candidate(bundle, output_dir, version, build_number, source,
                      endpoint, environment, github_output=None):
    bundle = Path(bundle)
    output_dir = Path(output_dir)
    resolved = output_dir.resolve(strict=False)
    bundle_root = bundle.resolve()
    _require(not resolved.exists(),
             'output directory already exists: %s' % output_dir)
    _require(not (resolved == bundle_root
                  or bundle_root in resolved.parents
                  or resolved in bundle_root.parents),
             'output directory must not overlap the app bundle')
    output_dir.parent.mkdir(parents=True, exist_ok=True)
    try:
        os.mkdir(output_dir)
    except FileExistsError:
        raise PackageError('output directory already exists: %s' % output_dir)
    final_archive = output_dir / ARCHIVE_NAME
    final_receipt = output_dir / RECEIPT_NAME
    temporary_archive = output_dir / ('.tmp-' + ARCHIVE_NAME)
    temporary_receipt = output_dir / ('.tmp-' + RECEIPT_NAME)
    try:
        metadata = inspect_bundle(bundle, version, build_number)
        archive = build_archive(bundle, temporary_archive)
        receipt = {
            'schema': SCHEMA,
            'created_at': datetime.now(timezone.utc)
            .replace(microsecond=0).isoformat().replace('+00:00', 'Z'),
            'source': dict(source),
            'app': {
                'name': 'high_eq',
                'version': metadata['version'],
                'build_number': metadata['build_number'],
                'bundle_id': metadata['bundle_id'],
                'extension_bundle_id': metadata['extension_bundle_id'],
            },
            'endpoint': dict(endpoint),
            'environment': dict(environment),
            'artifact': {
                'name': ARCHIVE_NAME,
                'bundle': BUNDLE_NAME,
                'sha256': archive['sha256'],
                'bytes': archive['bytes'],
            },
            'limitations': [
                'built with --no-codesign; no signing was requested or verified',
                'Runner has no embedded.mobileprovision; SDK frameworks may '
                'keep vendor _CodeSignature material',
                'not notarized and not uploaded to any store',
                'hosted workflow execution and device installation are unproven',
            ],
        }
        _check_receipt_shape(receipt)
        write_receipt(temporary_receipt, receipt)
        _write_github_output(github_output, {
            'sha256': archive['sha256'],
            'commit': source['commit'],
            'version': version,
            'build_number': build_number,
            'endpoint_type': endpoint['type'],
        })
        os.replace(temporary_archive, final_archive)
        os.replace(temporary_receipt, final_receipt)
        return receipt
    except BaseException:
        shutil.rmtree(output_dir, ignore_errors=True)
        raise


def verify_package(directory, expect_commit, expect_version, expect_build,
                   expect_sha256):
    directory = Path(directory)
    _require(re.fullmatch(r'[0-9a-f]{40}', expect_commit or ''),
             'expected commit must be a full SHA')
    _require(re.fullmatch(r'[0-9]+(?:\.[0-9]+)+', expect_version or ''),
             'expected version must be numeric')
    _require(re.fullmatch(r'[0-9]+', expect_build or ''),
             'expected build number must be numeric')
    _require(re.fullmatch(r'[0-9a-f]{64}', expect_sha256 or ''),
             'expected SHA256 must be a full lowercase digest')
    receipt_path = directory / RECEIPT_NAME
    _require(receipt_path.is_file(), 'missing %s' % receipt_path)
    try:
        receipt = json.loads(receipt_path.read_text(encoding='utf-8'))
    except ValueError as error:
        raise PackageError('cannot read receipt: %s' % error)
    _check_receipt_shape(receipt)
    endpoint = receipt['endpoint']
    if endpoint['type'] == 'mock-sample':
        _require(endpoint['value'] == 'mock',
                 'mock-sample endpoint must carry the mock value')
    else:
        _require(endpoint['value'].startswith('https://'),
                 'https endpoint does not carry an https origin')
    _require(receipt['source']['commit'] == expect_commit,
             'receipt commit %s does not match expected %s'
             % (receipt['source']['commit'], expect_commit))
    _require(receipt['app']['version'] == expect_version,
             'receipt version %s does not match expected %s'
             % (receipt['app']['version'], expect_version))
    _require(receipt['app']['build_number'] == expect_build,
             'receipt build %s does not match expected %s'
             % (receipt['app']['build_number'], expect_build))
    _require(receipt['app']['bundle_id'] == EXPECTED_BUNDLE_ID,
             'receipt Runner bundle identifier mismatch')
    _require(receipt['app']['extension_bundle_id'] == EXPECTED_EXTENSION_ID,
             'receipt ReplyShare bundle identifier mismatch')
    archive_path = directory / receipt['artifact']['name']
    _require(archive_path.is_file(), 'missing %s' % archive_path)
    digest = hashlib.sha256()
    with archive_path.open('rb') as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b''):
            digest.update(chunk)
    actual = digest.hexdigest()
    _require(actual == expect_sha256,
             'archive SHA256 %s does not match expected %s'
             % (actual, expect_sha256))
    _require(receipt['artifact']['sha256'] == expect_sha256,
             'receipt SHA256 does not match the independent expectation')
    _require(archive_path.stat().st_size == receipt['artifact']['bytes'],
             'archive size does not match receipt')
    try:
        with zipfile.ZipFile(archive_path) as archive:
            names = archive.namelist()
    except zipfile.BadZipFile as error:
        raise PackageError('archive is not a zip file: %s' % error)
    _require(names, 'archive is empty')
    _require(all(name.startswith(BUNDLE_NAME + '/') for name in names),
             'archive contains paths outside %s' % BUNDLE_NAME)
    with tempfile.TemporaryDirectory(prefix='t34-ios-verify-') as tmp:
        restored = extract_archive(archive_path, Path(tmp) / 'restore')
        metadata = inspect_bundle(restored / BUNDLE_NAME, expect_version,
                                  expect_build)
    _require(metadata['bundle_id'] == EXPECTED_BUNDLE_ID,
             'restored bundle identifier mismatch')
    return {
        'archive': str(archive_path),
        'sha256': actual,
        'commit': expect_commit,
        'version': expect_version,
        'build_number': expect_build,
        'endpoint': receipt['endpoint'].get('value'),
        'endpoint_type': receipt['endpoint'].get('type'),
    }


_THREAD_LOCKS = {}
_THREAD_LOCKS_GUARD = threading.Lock()


@contextlib.contextmanager
def _build_lock(build_root):
    import fcntl
    key = str(Path(build_root).resolve())
    with _THREAD_LOCKS_GUARD:
        thread_lock = _THREAD_LOCKS.setdefault(key, threading.Lock())
    if not thread_lock.acquire(blocking=False):
        raise PackageError(
            'another packaging run holds the build lock for this checkout')
    handle = None
    try:
        handle = open(Path(build_root) / '.t34-ios-package.lock', 'a+')
        try:
            fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            raise PackageError(
                'another packaging run holds the build lock for this checkout')
        yield
    finally:
        if handle is not None:
            try:
                fcntl.flock(handle, fcntl.LOCK_UN)
            finally:
                handle.close()
        thread_lock.release()


def _restore_previous_bundle(default, previous):
    if default.is_symlink() or default.is_file():
        default.unlink()
    elif default.exists():
        shutil.rmtree(default, ignore_errors=True)
    if previous is not None and (previous.exists() or previous.is_symlink()):
        default.parent.mkdir(parents=True, exist_ok=True)
        os.replace(previous, default)


@contextlib.contextmanager
def build_fresh_bundle(app_dir, builder):
    """Run builder and yield a private, call-owned Runner.app.

    The shared default bundle is quarantined, the command must produce a fresh
    default bundle, and that bundle is moved into this call's own workspace
    before the build lock is released. Later builds can only touch the shared
    default path, so they cannot rewrite the input this call will package.
    The quarantined previous bundle is kept until collection finishes and is
    restored if the build or collection fails.
    """
    app_dir = Path(app_dir)
    build_root = app_dir / 'build'
    build_root.mkdir(parents=True, exist_ok=True)
    default = build_root / 'ios/iphoneos' / BUNDLE_NAME
    with _build_lock(build_root):
        workspace = Path(tempfile.mkdtemp(
            prefix='.t34-run-', dir=str(build_root)))
        previous = workspace / ('previous-' + BUNDLE_NAME)
        had_previous = default.exists() or default.is_symlink()
        if had_previous:
            os.replace(default, previous)
        built = False
        try:
            builder()
            _require(default.is_dir() and not default.is_symlink(),
                     'build reported success but produced no fresh %s'
                     % BUNDLE_NAME)
            owned = workspace / BUNDLE_NAME
            os.replace(default, owned)
            built = True
            try:
                yield owned
            except BaseException:
                _restore_previous_bundle(
                    default, previous if had_previous else None)
                raise
        except BaseException:
            if not built:
                _restore_previous_bundle(
                    default, previous if had_previous else None)
            raise
        finally:
            shutil.rmtree(workspace, ignore_errors=True)


def _run(command, cwd=None):
    try:
        result = subprocess.run(command, cwd=cwd, text=True,
                                stdout=subprocess.PIPE,
                                stderr=subprocess.PIPE)
    except OSError as error:
        raise PackageError('cannot run %s: %s' % (command[0], error))
    if result.returncode != 0:
        tail = (result.stderr or result.stdout or '').strip().splitlines()
        raise PackageError('command failed (%d): %s\n%s'
                           % (result.returncode, ' '.join(command),
                              '\n'.join(tail[-8:])))
    return result.stdout.strip()


def require_clean_source(repo, expect_commit=None):
    repo = Path(repo)
    commit = _run(['git', '-C', str(repo), 'rev-parse', 'HEAD'])
    if not re.fullmatch(r'[0-9a-f]{40}', commit):
        raise PackageError('git HEAD is not a full commit SHA: %r' % commit)
    if expect_commit and commit != expect_commit:
        raise PackageError('git HEAD %s does not match expected %s'
                           % (commit, expect_commit))
    dirty = _run(['git', '-C', str(repo), 'status', '--porcelain',
                  '--untracked-files=normal'])
    if dirty:
        raise PackageError('working tree is not clean; refusing to package')
    return {'commit': commit, 'clean': True}


def build_environment(flutter):
    output = _run([flutter, '--version', '--machine'])
    try:
        info = json.loads(output[output.index('{'):])
    except ValueError:
        info = {}
    framework = info.get('frameworkVersion') or info.get('flutterVersion')
    dart = info.get('dartSdkVersion')
    if framework != EXPECTED_FLUTTER or dart != EXPECTED_DART:
        raise PackageError(
            'project-locked Flutter %s / Dart %s required, got %s / %s'
            % (EXPECTED_FLUTTER, EXPECTED_DART, framework, dart))
    xcode = _run(['xcodebuild', '-version']).splitlines()
    version = _run(['sw_vers', '-productVersion'])
    return {
        'flutter': framework,
        'dart': dart,
        'xcode': xcode[0] if xcode else 'unknown',
        'xcode_build': xcode[1] if len(xcode) > 1 else 'unknown',
        'macos': version,
        'arch': host_platform.machine(),
        'mode': 'release',
        'signing_request': '--no-codesign',
        'target': 'lib/main.dart',
    }


def build_candidate(flutter, app_dir, endpoint):
    _run([flutter, 'pub', 'get', '--enforce-lockfile'], cwd=app_dir)
    _run([
        flutter, 'build', 'ios',
        '--release', '--no-codesign', '--no-pub',
        '--target=lib/main.dart',
        '--dart-define=APP_ENDPOINT=%s' % endpoint,
    ], cwd=app_dir)


def _write_github_output(path, values):
    if not path:
        return
    with open(path, 'a', encoding='utf-8') as handle:
        for key, value in values.items():
            handle.write('%s=%s\n' % (key, value))


def main(argv=None):
    parser = argparse.ArgumentParser(
        description='Package or verify one T34 iOS Release candidate built '
                    'with --no-codesign.')
    parser.add_argument('--repo', default=str(REPO))
    parser.add_argument('--flutter',
                        default=os.environ.get('FLUTTER', 'flutter'))
    parser.add_argument('--output-dir',
                        help='new, empty directory reserved for this run')
    parser.add_argument('--endpoint',
                        help='APP_ENDPOINT value: "mock" or an https origin')
    parser.add_argument('--expect-commit',
                        help='full SHA the checkout must match')
    parser.add_argument('--github-output',
                        help='append sha256/version/build/type to this file')
    parser.add_argument('--verify', metavar='DIR',
                        help='verify an existing package directory')
    parser.add_argument('--expect-version')
    parser.add_argument('--expect-build')
    parser.add_argument('--expect-sha256')
    args = parser.parse_args(argv)
    try:
        if args.verify:
            missing = [name for name, value in (
                ('--expect-commit', args.expect_commit),
                ('--expect-version', args.expect_version),
                ('--expect-build', args.expect_build),
                ('--expect-sha256', args.expect_sha256)) if not value]
            _require(not missing, 'verify requires %s' % ', '.join(missing))
            verify_package(
                args.verify, args.expect_commit, args.expect_version,
                args.expect_build, args.expect_sha256)
            return 0
        _require(args.output_dir, '--output-dir is required when packaging')
        repo = Path(args.repo).resolve()
        app_dir = repo / 'app'
        output_dir = Path(args.output_dir)
        version, build_number = parse_pubspec_version(
            (app_dir / 'pubspec.yaml').read_text(encoding='utf-8'))
        endpoint = resolve_endpoint(args.endpoint, os.environ)
        validate_output_location(output_dir, app_dir)
        source = require_clean_source(repo, args.expect_commit)
        environment = build_environment(args.flutter)
        with build_fresh_bundle(
                app_dir,
                lambda: build_candidate(
                    args.flutter, app_dir, endpoint['value'])) as bundle:
            package_candidate(
                bundle, output_dir, version, build_number, source, endpoint,
                environment, github_output=args.github_output)
        return 0
    except (PackageError, OSError, ValueError) as error:
        print('t34 ios package: %s' % error, file=sys.stderr)
        return 1


if __name__ == '__main__':
    sys.exit(main())
