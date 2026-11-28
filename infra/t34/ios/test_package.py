"""Offline checks for the T34 iOS packaging entry.

Only synthetic ordinary files, plists, Mach-O headers and temporary
directories are used. No Flutter, Xcode, network, signing or cloud command is
invoked. The module is imported, never its build subprocesses.
"""
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import stat
import struct
import subprocess
import sys
import tempfile
import unittest
import zipfile

sys.path.insert(0, str(Path(__file__).resolve().parent))

import package  # noqa: E402

ROOT = Path(__file__).resolve().parents[3]
WORKFLOW = ROOT / '.github/workflows/t34-ios-package.yml'
COMMIT = 'a' * 40
SOURCE = {'commit': COMMIT, 'clean': True}
ENVIRONMENT = {
    'flutter': '3.38.10', 'dart': '3.10.9',
    'xcode': 'Xcode 27.2', 'macos': '26.2', 'arch': 'arm64',
}
BINARY_PATHS = (
    'Runner',
    'Frameworks/App.framework/App',
    'Frameworks/Flutter.framework/Flutter',
    'PlugIns/ReplyShare.appex/ReplyShare',
)


def macho(platform=2, filetype=2, aot=False):
    """Synthetic thin arm64 Mach-O with LC_BUILD_VERSION."""
    command = struct.pack('<IIIIII', 0x32, 24, platform, 0x000F0000,
                          0x00110000, 0)
    header = struct.pack('<IiiIIIII', 0xFEEDFACF, 0x0100000C, 0, filetype, 1,
                         len(command), 0, 0)
    payload = b''
    if aot:
        payload = b'_kDartVmSnapshotData\0_kDartIsolateSnapshotData\0'
    return header + command + payload


def write_bundle(tmp, version='0.1.0', build='1', platform=2, aot=True):
    bundle = Path(tmp) / 'Runner.app'
    blobs = {
        'Runner': macho(filetype=2),
        'Frameworks/App.framework/App': macho(filetype=6, aot=aot),
        'Frameworks/Flutter.framework/Flutter': macho(filetype=6),
        'PlugIns/ReplyShare.appex/ReplyShare': macho(filetype=2),
        'Frameworks/App.framework/flutter_assets/assets/'
        'contract_examples.json': b'{"sample": true}',
        'Frameworks/App.framework/flutter_assets/AssetManifest.bin': b'assets',
    }
    for name, data in blobs.items():
        target = bundle / name
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(data)
        if name in BINARY_PATHS:
            target.chmod(0o755)
    assets = bundle / 'Frameworks/App.framework/flutter_assets'
    os.symlink('assets/contract_examples.json', assets / 'linked.json')
    main_plist = {
        'CFBundleIdentifier': 'cn.higheq.highEq',
        'CFBundleShortVersionString': version,
        'CFBundleVersion': build,
        'CFBundleExecutable': 'Runner',
        'DTPlatformName': 'iphoneos',
    }
    (bundle / 'Info.plist').write_bytes(plistlib.dumps(main_plist))
    extension_plist = {
        'CFBundleIdentifier': 'cn.higheq.highEq.ReplyShare',
        'CFBundleShortVersionString': version,
        'CFBundleVersion': build,
        'CFBundleExecutable': 'ReplyShare',
        'CFBundlePackageType': 'XPC!',
        'NSExtension': {
            'NSExtensionPointIdentifier': 'com.apple.share-services',
        },
    }
    (bundle / 'PlugIns/ReplyShare.appex/Info.plist').write_bytes(
        plistlib.dumps(extension_plist))
    return bundle


def pack(tmp, bundle=None, **kwargs):
    target = Path(tmp) / 'out'
    receipt = package.package_candidate(
        bundle or write_bundle(tmp), target, '0.1.0', '1', SOURCE,
        package.endpoint_record(None), ENVIRONMENT, **kwargs)
    return receipt, target


class BundleInspection(unittest.TestCase):
    def test_valid_device_bundle_is_accepted(self):
        with tempfile.TemporaryDirectory() as tmp:
            meta = package.inspect_bundle(write_bundle(tmp), '0.1.0', '1')
        self.assertEqual(meta['bundle_id'], 'cn.higheq.highEq')
        self.assertEqual(meta['extension_bundle_id'],
                         'cn.higheq.highEq.ReplyShare')

    def test_missing_runner_is_rejected(self):
        with tempfile.TemporaryDirectory() as tmp:
            bundle = write_bundle(tmp)
            (bundle / 'Runner').unlink()
            with self.assertRaises(package.PackageError):
                package.inspect_bundle(bundle, '0.1.0', '1')

    def test_non_executable_runner_is_rejected(self):
        with tempfile.TemporaryDirectory() as tmp:
            bundle = write_bundle(tmp)
            (bundle / 'Runner').chmod(0o644)
            with self.assertRaises(package.PackageError):
                package.inspect_bundle(bundle, '0.1.0', '1')

    def test_placeholder_binary_is_rejected(self):
        with tempfile.TemporaryDirectory() as tmp:
            bundle = write_bundle(tmp)
            (bundle / 'Runner').write_bytes(b'not a mach-o binary')
            (bundle / 'Runner').chmod(0o755)
            with self.assertRaises(package.PackageError):
                package.inspect_bundle(bundle, '0.1.0', '1')

    def test_simulator_slice_is_rejected(self):
        with tempfile.TemporaryDirectory() as tmp:
            bundle = write_bundle(tmp)
            (bundle / 'Runner').write_bytes(macho(platform=7))
            with self.assertRaises(package.PackageError):
                package.inspect_bundle(bundle, '0.1.0', '1')

    def test_missing_flutter_engine_is_rejected(self):
        with tempfile.TemporaryDirectory() as tmp:
            bundle = write_bundle(tmp)
            (bundle / 'Frameworks/Flutter.framework/Flutter').unlink()
            with self.assertRaises(package.PackageError):
                package.inspect_bundle(bundle, '0.1.0', '1')

    def test_missing_aot_snapshot_symbols_are_rejected(self):
        with tempfile.TemporaryDirectory() as tmp:
            bundle = write_bundle(tmp, aot=False)
            with self.assertRaises(package.PackageError):
                package.inspect_bundle(bundle, '0.1.0', '1')

    def test_wrong_bundle_identifier_is_rejected(self):
        with tempfile.TemporaryDirectory() as tmp:
            bundle = write_bundle(tmp)
            info = plistlib.loads((bundle / 'Info.plist').read_bytes())
            info['CFBundleIdentifier'] = 'com.other.app'
            (bundle / 'Info.plist').write_bytes(plistlib.dumps(info))
            with self.assertRaises(package.PackageError):
                package.inspect_bundle(bundle, '0.1.0', '1')

    def test_wrong_runner_executable_name_is_rejected(self):
        with tempfile.TemporaryDirectory() as tmp:
            bundle = write_bundle(tmp)
            info = plistlib.loads((bundle / 'Info.plist').read_bytes())
            info['CFBundleExecutable'] = 'Other'
            (bundle / 'Info.plist').write_bytes(plistlib.dumps(info))
            with self.assertRaises(package.PackageError):
                package.inspect_bundle(bundle, '0.1.0', '1')

    def test_wrong_share_extension_point_is_rejected(self):
        with tempfile.TemporaryDirectory() as tmp:
            bundle = write_bundle(tmp)
            path = bundle / 'PlugIns/ReplyShare.appex/Info.plist'
            info = plistlib.loads(path.read_bytes())
            info['NSExtension']['NSExtensionPointIdentifier'] = 'com.other'
            path.write_bytes(plistlib.dumps(info))
            with self.assertRaises(package.PackageError):
                package.inspect_bundle(bundle, '0.1.0', '1')

    def test_missing_declared_flutter_asset_is_rejected(self):
        with tempfile.TemporaryDirectory() as tmp:
            bundle = write_bundle(tmp)
            (bundle / 'Frameworks/App.framework/flutter_assets/assets/'
                      'contract_examples.json').unlink()
            with self.assertRaises(package.PackageError):
                package.inspect_bundle(bundle, '0.1.0', '1')

    def test_version_mismatch_is_rejected(self):
        with tempfile.TemporaryDirectory() as tmp:
            bundle = write_bundle(tmp, version='9.9.9', build='99')
            with self.assertRaises(package.PackageError):
                package.inspect_bundle(bundle, '0.1.0', '1')

    def test_escaping_symlink_is_rejected(self):
        with tempfile.TemporaryDirectory() as tmp:
            bundle = write_bundle(tmp)
            os.symlink('../../outside', bundle / 'escape')
            with self.assertRaises(package.PackageError):
                package.inspect_bundle(bundle, '0.1.0', '1')

    def test_broken_symlink_is_rejected(self):
        with tempfile.TemporaryDirectory() as tmp:
            bundle = write_bundle(tmp)
            os.symlink('missing', bundle / 'broken')
            with self.assertRaises(package.PackageError):
                package.inspect_bundle(bundle, '0.1.0', '1')

    def test_provisioned_bundle_is_rejected(self):
        with tempfile.TemporaryDirectory() as tmp:
            bundle = write_bundle(tmp)
            (bundle / 'embedded.mobileprovision').write_bytes(b'profile')
            with self.assertRaises(package.PackageError):
                package.inspect_bundle(bundle, '0.1.0', '1')


class Endpoints(unittest.TestCase):
    def test_default_is_labelled_mock_sample(self):
        record = package.endpoint_record(None)
        self.assertEqual(record['value'], 'mock')
        self.assertEqual(record['type'], 'mock-sample')
        self.assertEqual(record['source'], 'default')

    def test_source_is_preserved(self):
        self.assertEqual(package.endpoint_record('mock', 'cli')['source'],
                         'cli')
        self.assertEqual(package.resolve_endpoint(
            None, {'T34_IOS_APP_ENDPOINT': 'mock'})['source'], 'environment')

    def test_root_https_origin_is_accepted(self):
        for value in ('https://api.vendor.cn',
                      'https://api.vendor.cn:8443/',
                      'https://api.vendor.cn/'):
            with self.subTest(value=value):
                record = package.endpoint_record(value)
                self.assertEqual(record['value'], 'https://api.vendor.cn'
                                 if ':8443' not in value
                                 else 'https://api.vendor.cn:8443')
                self.assertEqual(record['type'], 'https')

    def test_non_root_path_query_and_fragment_are_rejected(self):
        for value in ('https://api.vendor.cn/base',
                      'https://api.vendor.cn/?q=1',
                      'https://api.vendor.cn/#fragment'):
            with self.subTest(value=value):
                with self.assertRaises(package.PackageError):
                    package.endpoint_record(value)

    def test_credentials_are_rejected(self):
        for value in ('https://user:pass@api.vendor.cn',
                      'https://token@api.vendor.cn'):
            with self.subTest(value=value):
                with self.assertRaises(package.PackageError):
                    package.endpoint_record(value)

    def test_plain_http_relative_and_bad_port_are_rejected(self):
        for value in ('http://api.vendor.cn', 'api.vendor.cn',
                      'ftp://api.vendor.cn', 'https://api.vendor.cn:99999'):
            with self.subTest(value=value):
                with self.assertRaises(package.PackageError):
                    package.endpoint_record(value)

    def test_placeholder_hosts_are_rejected(self):
        for value in ('https://api.example.org', 'https://localhost',
                      'https://127.0.0.1', 'https://[::1]',
                      'https://api.example.invalid'):
            with self.subTest(value=value):
                with self.assertRaises(package.PackageError):
                    package.endpoint_record(value)


class OutputLocation(unittest.TestCase):
    def test_existing_output_directory_is_rejected_untouched(self):
        with tempfile.TemporaryDirectory() as tmp:
            app = Path(tmp) / 'app'
            app.mkdir()
            out = Path(tmp) / 'out'
            out.mkdir()
            sentinel = out / 'keep.txt'
            sentinel.write_text('keep')
            with self.assertRaises(package.PackageError):
                package.validate_output_location(out, app)
            self.assertEqual(sentinel.read_text(), 'keep')
            self.assertEqual(sorted(p.name for p in out.iterdir()),
                             ['keep.txt'])

    def test_output_inside_source_tree_is_rejected(self):
        with tempfile.TemporaryDirectory() as tmp:
            app = Path(tmp) / 'app'
            app.mkdir()
            with self.assertRaises(package.PackageError):
                package.validate_output_location(app / 'build' / 'out', app)

    def test_packaging_failure_removes_the_new_output_directory(self):
        with tempfile.TemporaryDirectory() as tmp:
            bundle = write_bundle(tmp)
            (bundle / 'Runner').unlink()
            out = Path(tmp) / 'fresh-out'
            with self.assertRaises(package.PackageError):
                package.package_candidate(
                    bundle, out, '0.1.0', '1', SOURCE,
                    package.endpoint_record(None), ENVIRONMENT)
            self.assertFalse(out.exists())


class FreshBuild(unittest.TestCase):
    def make_app(self, tmp):
        app = Path(tmp) / 'app'
        bundle = app / 'build/ios/iphoneos/Runner.app'
        bundle.mkdir(parents=True)
        (bundle / 'marker').write_text('old')
        return app, bundle

    @staticmethod
    def build(bundle, marker):
        bundle.mkdir(parents=True)
        (bundle / 'marker').write_text(marker)

    def test_success_without_a_new_bundle_is_rejected_and_old_restored(self):
        with tempfile.TemporaryDirectory() as tmp:
            app, bundle = self.make_app(tmp)
            with self.assertRaises(package.PackageError):
                with package.build_fresh_bundle(app, lambda: None):
                    pass
            self.assertEqual((bundle / 'marker').read_text(), 'old')

    def test_concurrent_build_is_rejected_and_private_copy_remains(self):
        with tempfile.TemporaryDirectory() as tmp:
            app, bundle = self.make_app(tmp)
            with package.build_fresh_bundle(
                    app, lambda: self.build(bundle, 'A')) as first:
                self.assertEqual((first / 'marker').read_text(), 'A')
                with self.assertRaises(package.PackageError):
                    with package.build_fresh_bundle(
                            app, lambda: self.build(bundle, 'B')):
                        pass
                self.assertEqual((first / 'marker').read_text(), 'A')
            self.assertFalse(first.exists())
            with package.build_fresh_bundle(
                    app, lambda: self.build(bundle, 'B')) as second:
                self.assertEqual((second / 'marker').read_text(), 'B')

    def test_validation_failure_restores_the_previous_bundle(self):
        with tempfile.TemporaryDirectory() as tmp:
            app, bundle = self.make_app(tmp)
            with self.assertRaises(RuntimeError):
                with package.build_fresh_bundle(
                        app, lambda: self.build(bundle, 'new')) as fresh:
                    self.assertEqual((fresh / 'marker').read_text(), 'new')
                    raise RuntimeError('validation failed')
            self.assertEqual((bundle / 'marker').read_text(), 'old')

    def test_failed_builder_restores_the_old_bundle(self):
        with tempfile.TemporaryDirectory() as tmp:
            app, bundle = self.make_app(tmp)

            def builder():
                raise RuntimeError('build failed')

            with self.assertRaises(RuntimeError):
                with package.build_fresh_bundle(app, builder):
                    pass
            self.assertEqual((bundle / 'marker').read_text(), 'old')


class Packaging(unittest.TestCase):
    def test_success_writes_exactly_archive_and_receipt(self):
        with tempfile.TemporaryDirectory() as tmp:
            receipt, out = pack(tmp)
            self.assertEqual(sorted(p.name for p in out.iterdir()),
                             ['Runner.app.zip', 'receipt.json'])
            archive = out / 'Runner.app.zip'
            digest = hashlib.sha256(archive.read_bytes()).hexdigest()
            self.assertEqual(receipt['artifact']['sha256'], digest)
            self.assertEqual(receipt['artifact']['bytes'],
                             archive.stat().st_size)
            self.assertEqual(receipt['endpoint']['value'], 'mock')
            self.assertEqual(receipt['endpoint']['type'], 'mock-sample')
            names = zipfile.ZipFile(archive).namelist()
            for required in (
                    'Runner.app/Runner',
                    'Runner.app/Info.plist',
                    'Runner.app/Frameworks/App.framework/App',
                    'Runner.app/Frameworks/Flutter.framework/Flutter',
                    'Runner.app/Frameworks/App.framework/flutter_assets/',
                    'Runner.app/PlugIns/ReplyShare.appex/ReplyShare'):
                self.assertIn(required, names)
            self.assertTrue(all(n.startswith('Runner.app/') for n in names))
            with zipfile.ZipFile(archive) as zipped:
                runner = zipped.getinfo('Runner.app/Runner')
                self.assertTrue(stat.S_IMODE(runner.external_attr >> 16)
                                & 0o111)
                link = zipped.getinfo(
                    'Runner.app/Frameworks/App.framework/flutter_assets/'
                    'linked.json')
                self.assertTrue(stat.S_ISLNK(link.external_attr >> 16))

    def test_receipt_carries_environment_and_limitations(self):
        with tempfile.TemporaryDirectory() as tmp:
            receipt, out = pack(tmp)
            self.assertEqual(receipt['environment'], ENVIRONMENT)
            self.assertEqual(receipt['source'], SOURCE)
            self.assertTrue(receipt['limitations'])

    def test_identical_bundles_archive_to_the_same_digest(self):
        with tempfile.TemporaryDirectory() as tmp:
            bundle = write_bundle(tmp)
            first = package.build_archive(bundle, Path(tmp) / 'first.zip')
            second = package.build_archive(bundle, Path(tmp) / 'second.zip')
            self.assertEqual(first['sha256'], second['sha256'])
            self.assertEqual((Path(tmp) / 'first.zip').read_bytes(),
                             (Path(tmp) / 'second.zip').read_bytes())

    def test_github_output_is_written_with_the_package_state(self):
        with tempfile.TemporaryDirectory() as tmp:
            output = Path(tmp) / 'github-output'
            receipt, _ = pack(tmp, github_output=str(output))
            text = output.read_text()
            self.assertIn('sha256=%s' % receipt['artifact']['sha256'], text)
            self.assertIn('commit=%s' % COMMIT, text)
            self.assertIn('version=0.1.0', text)
            self.assertIn('build_number=1', text)
            self.assertIn('endpoint_type=mock-sample', text)

    def test_github_output_failure_leaves_no_final_artifacts(self):
        with tempfile.TemporaryDirectory() as tmp:
            bundle = write_bundle(tmp)
            out = Path(tmp) / 'out'
            with self.assertRaises(OSError):
                package.package_candidate(
                    bundle, out, '0.1.0', '1', SOURCE,
                    package.endpoint_record(None), ENVIRONMENT,
                    github_output=str(Path(tmp) / 'missing' / 'output'))
            self.assertFalse(out.exists())


class Extraction(unittest.TestCase):
    def test_extract_restores_modes_and_symlinks(self):
        with tempfile.TemporaryDirectory() as tmp:
            _, out = pack(tmp)
            restore = Path(tmp) / 'restore'
            package.extract_archive(out / 'Runner.app.zip', restore)
            bundle = restore / 'Runner.app'
            self.assertTrue((bundle / 'Runner').stat().st_mode & 0o111)
            link = (bundle / 'Frameworks/App.framework/flutter_assets/'
                    'linked.json')
            self.assertTrue(link.is_symlink())
            self.assertEqual(os.readlink(link), 'assets/contract_examples.json')
            package.inspect_bundle(bundle, '0.1.0', '1')

    def test_extract_rejects_parent_traversal(self):
        with tempfile.TemporaryDirectory() as tmp:
            archive = Path(tmp) / 'bad.zip'
            with zipfile.ZipFile(archive, 'w') as zipped:
                info = zipfile.ZipInfo('../escape', (1980, 1, 1, 0, 0, 0))
                info.create_system = 3
                info.external_attr = 0o100644 << 16
                zipped.writestr(info, b'escape')
            with self.assertRaises(package.PackageError):
                package.extract_archive(archive, Path(tmp) / 'restore')
            self.assertFalse((Path(tmp) / 'escape').exists())

    def test_extract_rejects_absolute_symlink(self):
        with tempfile.TemporaryDirectory() as tmp:
            archive = Path(tmp) / 'bad.zip'
            with zipfile.ZipFile(archive, 'w') as zipped:
                info = zipfile.ZipInfo('Runner.app/link',
                                       (1980, 1, 1, 0, 0, 0))
                info.create_system = 3
                info.external_attr = 0o120777 << 16
                zipped.writestr(info, b'/etc/passwd')
            with self.assertRaises(package.PackageError):
                package.extract_archive(archive, Path(tmp) / 'restore')

    def test_extract_rejects_entries_without_unix_metadata(self):
        with tempfile.TemporaryDirectory() as tmp:
            archive = Path(tmp) / 'bad.zip'
            with zipfile.ZipFile(archive, 'w') as zipped:
                zipped.writestr('Runner.app/Runner', b'data')
            with self.assertRaises(package.PackageError):
                package.extract_archive(archive, Path(tmp) / 'restore')


class Verification(unittest.TestCase):
    def verify(self, out, receipt, **overrides):
        expected = {
            'expect_commit': COMMIT,
            'expect_version': '0.1.0',
            'expect_build': '1',
            'expect_sha256': receipt['artifact']['sha256'],
        }
        expected.update(overrides)
        return package.verify_package(out, **expected)

    def test_verify_accepts_fresh_package_with_external_expectations(self):
        with tempfile.TemporaryDirectory() as tmp:
            receipt, out = pack(tmp)
            summary = self.verify(out, receipt)
            self.assertEqual(summary['sha256'],
                             hashlib.sha256((out / 'Runner.app.zip')
                                            .read_bytes()).hexdigest())
            self.assertEqual(summary['commit'], COMMIT)

    def test_wrong_expected_commit_is_rejected(self):
        with tempfile.TemporaryDirectory() as tmp:
            receipt, out = pack(tmp)
            with self.assertRaises(package.PackageError):
                self.verify(out, receipt, expect_commit='b' * 40)

    def test_wrong_expected_version_or_build_is_rejected(self):
        for field, value in (('expect_version', '9.9.9'),
                             ('expect_build', '99')):
            with tempfile.TemporaryDirectory() as tmp:
                receipt, out = pack(tmp)
                with self.subTest(field=field):
                    with self.assertRaises(package.PackageError):
                        self.verify(out, receipt, **{field: value})

    def test_wrong_expected_sha256_is_rejected(self):
        with tempfile.TemporaryDirectory() as tmp:
            receipt, out = pack(tmp)
            with self.assertRaises(package.PackageError):
                self.verify(out, receipt, expect_sha256='0' * 64)

    def test_forged_receipt_commit_is_rejected(self):
        with tempfile.TemporaryDirectory() as tmp:
            receipt, out = pack(tmp)
            receipt['source']['commit'] = 'b' * 40
            (out / 'receipt.json').write_text(json.dumps(receipt))
            with self.assertRaises(package.PackageError):
                self.verify(out, receipt)

    def test_tampered_archive_is_rejected(self):
        with tempfile.TemporaryDirectory() as tmp:
            receipt, out = pack(tmp)
            with (out / 'Runner.app.zip').open('ab') as handle:
                handle.write(b'tamper')
            with self.assertRaises(package.PackageError):
                self.verify(out, receipt)


class FinalOutput(unittest.TestCase):
    def run_child(self, script, mode):
        command = [sys.executable, '-I', '-B', '-c', script]
        if mode == 'broken':
            read_fd, write_fd = os.pipe()
            os.close(read_fd)
            result = subprocess.run(command, stdout=write_fd,
                                    stderr=subprocess.PIPE)
            os.close(write_fd)
            return result
        if mode == 'closed-start':
            def close_stdout():
                os.close(1)

            return subprocess.run(command, preexec_fn=close_stdout,
                                  stderr=subprocess.PIPE)
        return subprocess.run(command, stdout=subprocess.PIPE,
                              stderr=subprocess.PIPE)

    def make_checkout(self, tmp):
        repo = Path(tmp) / 'repo'
        app = repo / 'app'
        app.mkdir(parents=True)
        (app / 'pubspec.yaml').write_text('version: 0.1.0+1\n')
        old = app / 'build/ios/iphoneos/Runner.app'
        old.mkdir(parents=True)
        (old / 'old-marker').write_text('old')
        return repo, old, write_bundle(tmp)

    def packaging_script(self, repo, bundle, output, github_output,
                         counters, close_after):
        lines = [
            'import json, os, shutil, sys',
            'from pathlib import Path',
            'sys.path.insert(0, '
            + repr(str(Path(__file__).resolve().parent)) + ')',
            'import package',
            'package.require_clean_source = lambda repo, expect=None: '
            + repr({'commit': COMMIT, 'clean': True}),
            'package.build_environment = lambda flutter: '
            + repr(ENVIRONMENT),
            'source_bundle = Path(' + repr(str(bundle)) + ')',
            "counts = {'build': 0, 'archive': 0}",
            'real_archive = package.build_archive',
            'def counted_archive(bundle_path, destination):',
            "    counts['archive'] += 1",
            '    return real_archive(bundle_path, destination)',
            'package.build_archive = counted_archive',
            'def fake_build(flutter, app_dir, endpoint):',
            "    counts['build'] += 1",
            "    shutil.copytree(source_bundle, "
            "app_dir / 'build/ios/iphoneos/Runner.app')",
            'package.build_candidate = fake_build',
        ]
        if close_after:
            lines += [
                'real_candidate = package.package_candidate',
                'def close_after_candidate(*args, **kwargs):',
                '    result = real_candidate(*args, **kwargs)',
                '    os.close(1)',
                '    return result',
                'package.package_candidate = close_after_candidate',
            ]
        lines += [
            'code = package.main(["--repo", '
            + repr(str(repo)) + ', "--output-dir", '
            + repr(str(output)) + ', "--github-output", '
            + repr(str(github_output)) + '])',
            'Path(' + repr(str(counters)) + ").write_text(json.dumps(counts))",
            'sys.exit(code)',
        ]
        return '\n'.join(lines)

    def assert_package(self, tmp, mode, close_after=False):
        repo, old, bundle = self.make_checkout(tmp)
        output = Path(tmp) / 'out'
        github_output = Path(tmp) / 'github-output'
        counters = Path(tmp) / 'counters.json'
        script = self.packaging_script(
            repo, bundle, output, github_output, counters, close_after)
        result = self.run_child(script, mode)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(output.exists(), True)
        self.assertEqual(sorted(p.name for p in output.iterdir()),
                         ['Runner.app.zip', 'receipt.json'])
        self.assertEqual(json.loads(counters.read_text()),
                         {'build': 1, 'archive': 1})
        self.assertIn('endpoint_type=mock-sample', github_output.read_text())
        self.assertFalse(old.exists())
        receipt = json.loads((output / 'receipt.json').read_text())
        package.verify_package(output, COMMIT, '0.1.0', '1',
                               receipt['artifact']['sha256'])
        if mode in ('normal', 'closed-after'):
            self.assertEqual(result.stdout, b'')

    def test_package_normal_stdout(self):
        with tempfile.TemporaryDirectory() as tmp:
            self.assert_package(tmp, 'normal')

    def test_package_broken_read_end(self):
        with tempfile.TemporaryDirectory() as tmp:
            self.assert_package(tmp, 'broken')

    def test_package_stdout_closed_at_start(self):
        with tempfile.TemporaryDirectory() as tmp:
            self.assert_package(tmp, 'closed-start')

    def test_package_stdout_closed_after_collection(self):
        with tempfile.TemporaryDirectory() as tmp:
            self.assert_package(tmp, 'closed-after', close_after=True)

    def verify_script(self, output, close_after):
        receipt = json.loads((output / 'receipt.json').read_text())
        lines = [
            'import os, sys',
            'from pathlib import Path',
            'sys.path.insert(0, '
            + repr(str(Path(__file__).resolve().parent)) + ')',
            'import package',
        ]
        if close_after:
            lines += [
                'real_verify = package.verify_package',
                'def close_after_verify(*args, **kwargs):',
                '    result = real_verify(*args, **kwargs)',
                '    os.close(1)',
                '    return result',
                'package.verify_package = close_after_verify',
            ]
        lines += [
            'sys.exit(package.main(["--verify", ' + repr(str(output))
            + ', "--expect-commit", ' + repr(COMMIT)
            + ', "--expect-version", "0.1.0", "--expect-build", "1", '
            '"--expect-sha256", '
            + repr(receipt['artifact']['sha256']) + ']))',
        ]
        return '\n'.join(lines)

    def assert_verify(self, tmp, mode, close_after=False):
        output = Path(tmp) / 'out'
        pack(tmp)
        script = self.verify_script(output, close_after)
        result = self.run_child(script, mode)
        self.assertEqual(result.returncode, 0, result.stderr)
        if mode in ('normal', 'closed-after'):
            self.assertEqual(result.stdout, b'')

    def test_verify_normal_stdout(self):
        with tempfile.TemporaryDirectory() as tmp:
            self.assert_verify(tmp, 'normal')

    def test_verify_broken_read_end(self):
        with tempfile.TemporaryDirectory() as tmp:
            self.assert_verify(tmp, 'broken')

    def test_verify_stdout_closed_at_start(self):
        with tempfile.TemporaryDirectory() as tmp:
            self.assert_verify(tmp, 'closed-start')

    def test_verify_stdout_closed_after_collection(self):
        with tempfile.TemporaryDirectory() as tmp:
            self.assert_verify(tmp, 'closed-after', close_after=True)


class WorkflowContract(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.workflow = WORKFLOW.read_text()

    def test_workflow_is_manual_only(self):
        self.assertRegex(self.workflow, r'(?m)^on:\n  workflow_dispatch:')
        for forbidden in ('push:', 'pull_request:', 'schedule:'):
            self.assertNotIn(forbidden, self.workflow)

    def test_permissions_are_read_only(self):
        self.assertIn('permissions:\n  contents: read', self.workflow)
        for forbidden in ('contents: write', 'packages: write',
                          'actions: write', 'id-token:'):
            self.assertNotIn(forbidden, self.workflow)

    def test_every_action_is_pinned_to_a_full_sha(self):
        for action in re.findall(r'(?m)^\s+- uses: ([^\s#]+)', self.workflow):
            self.assertRegex(action,
                             r'^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+@[0-9a-f]{40}$')

    def test_pinned_flutter_and_macos_runner(self):
        self.assertIn("flutter-version: '3.38.10'", self.workflow)
        self.assertIn('runs-on: macos-26', self.workflow)

    def test_output_directory_is_fresh_per_run(self):
        self.assertIn('t34-ios-package-${{ github.run_id }}-'
                      '${{ github.run_attempt }}', self.workflow)

    def test_package_and_verify_bind_the_checkout_commit(self):
        self.assertGreaterEqual(
            self.workflow.count('--expect-commit "$GITHUB_SHA"'), 2)
        self.assertIn('--github-output "$GITHUB_OUTPUT"', self.workflow)
        self.assertIn('--expect-sha256 "${{ steps.package.outputs.sha256 }}"',
                      self.workflow)
        self.assertIn('--expect-version "${{ steps.package.outputs.version }}"',
                      self.workflow)
        self.assertIn('--expect-build "${{ steps.package.outputs.build_number }}"',
                      self.workflow)

    def test_upload_runs_only_after_package_and_verify(self):
        packaged = self.workflow.index('package.py --output-dir')
        verified = self.workflow.index('package.py --verify')
        uploaded = self.workflow.index('actions/upload-artifact')
        self.assertLess(packaged, verified)
        self.assertLess(verified, uploaded)
        self.assertIn('if-no-files-found: error', self.workflow)
        upload = self.workflow[uploaded:]
        self.assertIn('${{ runner.temp }}/t34-ios-package-'
                      '${{ github.run_id }}-${{ github.run_attempt }}'
                      '/Runner.app.zip', upload)
        self.assertIn('/receipt.json', upload)
        self.assertNotIn('/t34-ios-package-${{ github.run_id }}-'
                         '${{ github.run_attempt }}/\n', upload)

    def test_artifact_name_uses_the_packaged_endpoint_type(self):
        upload = self.workflow[self.workflow.index('actions/upload-artifact'):]
        self.assertIn('steps.package.outputs.endpoint_type', upload)
        self.assertIn('endpoint_type', self.workflow[
            self.workflow.index('--github-output'):])

    def test_no_signing_cloud_or_secret_paths(self):
        for forbidden in ('secrets.', 'codesign', 'mobileprovision',
                          'altool', 'notarytool', 'xcodebuild -export',
                          'aws ', 'gcloud ', 'az ', 'kubectl', 'helm '):
            self.assertNotIn(forbidden, self.workflow)


if __name__ == '__main__':
    unittest.main()
