#!/usr/bin/env python3
"""T34+D13 replay on host-provisioned, disposable native PG and Redis."""
import argparse
import base64
import json
import os
from pathlib import Path
import re
import secrets
import shutil
import subprocess
import sys
import tempfile
import time
from urllib.parse import urlsplit, urlunsplit

HERE = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(HERE))
from evidence import check, manifest
from inputs import stage_inputs
from lab import _run_timed_compose, ticket_document
from release import audit, refuse_missing_root, restore_replay, validate_release, verify_before_restore
import release_approval


def local_url(name, schemes):
    url = urlsplit(os.environ.get(name, ''))
    if (url.scheme not in schemes or url.hostname != '127.0.0.1' or not url.port
            or not url.path or url.path == '/' or url.query or url.fragment):
        raise ValueError(f'{name} requires an explicit disposable loopback URL')
    return url


class NativeReplay:
    """Bind the existing release ledger/replay helpers to native commands."""

    def __init__(self, work, source, database, cache, ledger):
        self.work = work
        self.source = source
        self.name = 't34-d13-' + secrets.token_hex(12)
        self.env = {
            'PATH': os.environ['PATH'],
            'APP_ENV': 'development',
            'PAYMENT_MODE': 'disabled',
            'GIN_MODE': 'release',
            'BACKUP_RETENTION_DAYS': '45',
            'FIELD_KEY_BASE64': base64.b64encode(secrets.token_bytes(32)).decode(),
            'INSTALLATION': self.name,
            'DATABASE_URL': database,
            'REDIS_URL': cache,
            'LEDGER_URL': ledger,
            'DB_SERVICE': 'db',
            'CACHE_SERVICE': 'cache',
            'GATE_FILE': str(work / 'ticket'),
            'T34_DRILL_API': str(work / 'api'),
        }

    def command(self, *args, timeout=30, input=None, check=True):
        # Use the shared process-group timeout so it also stops the API child.
        argv = tuple(map(str, args))
        proc = _run_timed_compose(argv, cwd=self.source / 'server', env=self.env,
                                  input=input, stdout=subprocess.PIPE,
                                  stderr=subprocess.PIPE, timeout=timeout)
        if check and proc.returncode:
            if argv[0] == str(self.work / 'drill'):
                diagnostic = re.fullmatch(
                    rb'offline drill refused stage=[a-z0-9_.]+ at=[a-z_]+\.go:[0-9]+\n',
                    proc.stderr)
                if diagnostic:
                    sys.stderr.write(diagnostic.group().decode())
            raise ValueError(f'native {Path(argv[0]).name} {proc.returncode}')
        return proc.stdout if check else proc

    def job(self, service, *args, entry=None, **kwargs):
        if service == 'drill':
            return self.command(str(self.work / 'drill'), *args, timeout=130, **kwargs)
        if (service, entry) == ('permit', '/ops/gate.sh'):
            return self.gate(*args)
        raise ValueError('unexpected native job')

    def exec(self, service, *args, **kwargs):
        if (service, args[0]) != ('ledger', 'redis-cli'):
            raise ValueError('unexpected native Redis command')
        return self.redis(self.env['LEDGER_URL'], *args[1:], **kwargs)

    def redis(self, url, *args, **kwargs):
        return self.command('redis-cli', '-u', url, '--raw', *args, **kwargs)

    def sql(self, database, query):
        return self.command('psql', database, '-XqAt', '-v', 'ON_ERROR_STOP=1', '-c', query)

    def fenced(self):
        # This runner starts no server during backup, deletion or restore.
        # The later child process is loopback-only and reaped by the drill.
        pass

    def gate(self, *args, **kwargs):
        return self.command('sh', str(HERE / 'gate.sh'), *args, **kwargs)

    def permit(self, seed, dump_sha, purpose):
        self.env['CHALLENGE'] = secrets.token_hex(24)
        self.env['BUSINESS_DUMP_SHA256'] = dump_sha
        ticket = ticket_document(self.name, self.env['DB_SERVICE'], self.env['CACHE_SERVICE'],
                                 self.env['CHALLENGE'], seed['Seal'], dump_sha,
                                 [] if purpose == 'initial' else seed['Expected'], purpose)
        Path(self.env['GATE_FILE']).write_text(json.dumps(ticket))
        if self.gate('verify').strip() != b'recovery_gate_ok':
            raise ValueError('native gate failed to verify ticket')

    def probe_missing_root(self, root):
        result = self.gate('probe-missing', root, check=False)
        if result.returncode != 1 or result.stdout.strip() != b'recovery_gate_refused_missing_root':
            raise ValueError('native missing-root gate did not fail as expected')

    def verify_empty(self, restore, cold_cache, scratch_ledger):
        databases = (self.env['DATABASE_URL'], restore)
        identities = [self.sql(url, """
            SELECT system_identifier::text || ':' || current_database()
            FROM pg_control_system()
            WHERE current_setting('server_version_num')::int / 10000 = 17
              AND NOT EXISTS (SELECT FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
                              WHERE n.nspname='public');
        """).strip() for url in databases]
        if not all(identities) or identities[0] == identities[1]:
            raise ValueError('native replay requires two distinct empty PostgreSQL 17 databases')
        cache, ledger = self.env['REDIS_URL'], self.env['LEDGER_URL']
        ids = [{line for line in self.redis(url, 'INFO', 'server').splitlines()
                if line.startswith(b'run_id:')} for url in (cache, ledger)]
        if len(ids[0]) != 1 or len(ids[1]) != 1 or ids[0] == ids[1]:
            raise ValueError('native replay requires independent Redis instances')
        if any(self.redis(url, 'DBSIZE').strip() != b'0' for url in
               (cache, cold_cache, ledger, scratch_ledger)):
            raise ValueError('native replay Redis databases must be empty')


def replay(lab, tree, restore, cold_cache):
    raw = lab.job('drill', 'seed-d13')
    seed = json.loads(raw)
    dump = lab.work / 'business.dump'
    started = int(time.time())
    lab.command('pg_dump', '--dbname', lab.env['DATABASE_URL'], '--format=custom',
                '--file', dump, timeout=120)
    build_id = 'native-git-tree:' + tree
    doc = manifest(dump, lab.name, build_id, started)
    check(doc, dump, lab.name, build_id, int(time.time()))
    lab.permit(seed, doc['sha256'], 'initial')
    Path(lab.env['GATE_FILE']).unlink()

    witness = lab.work / 'deletion-receipt.json'
    deadlines = verify_before_restore(lab, seed, witness, lab.job('drill', 'delete', input=raw))

    lab.env.update(DATABASE_URL=restore, REDIS_URL=cold_cache,
                   DB_SERVICE='restored', CACHE_SERVICE='coldcache')
    check(doc, dump, lab.name, build_id, int(time.time()))
    lab.command('pg_restore', '--single-transaction', '--no-owner', '--no-privileges',
                '--dbname', restore, dump, timeout=120)
    restore_replay(lab, raw, seed['Seal'], witness, deadlines)
    lab.permit(seed, doc['sha256'], 'recovery')
    refuse_missing_root(lab, seed['Seal'], witness, deadlines, seed['Expected'][0])
    if lab.gate('verify').strip() != b'recovery_gate_ok':
        raise ValueError('native recovery gate did not reopen after negative probe')

    lab.job('drill', 'retention-process', input=raw)
    audit(lab, witness, deadlines)
    check(doc, dump, lab.name, build_id, int(time.time()))
    return {'dump_sha256': doc['sha256'], 'retention_days': doc['max_days'],
            'deletion_roots': len(deadlines)}


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--repo', type=Path, required=True)
    p.add_argument('--candidate-tree', required=True)
    p.add_argument('--previous', required=True)
    p.add_argument('--decoder-approvals', type=Path,
                   default=os.environ.get(release_approval.APPROVALS_ENV))
    args = p.parse_args()
    os.umask(0o077)
    stage = 'inputs'
    try:
        source_url = local_url('T34_SOURCE_DATABASE_URL', ('postgres', 'postgresql'))
        restore_url = local_url('T34_RESTORE_DATABASE_URL', ('postgres', 'postgresql'))
        cache = local_url('T34_CACHE_URL', ('redis',))
        ledger = local_url('T34_LEDGER_URL', ('redis',))
        if cache.path != '/0' or ledger.path != '/0':
            raise ValueError('native replay requires Redis URLs ending in /0')
        with tempfile.TemporaryDirectory(prefix='t34-d13-replay-') as tmp:
            work = Path(tmp)
            source, prior = work / 'current', work / 'prior'
            tree = stage_inputs(args.repo, source, prior, tree=args.candidate_tree,
                                previous_commit=args.previous)
            composition, schema = validate_release(
                source, prior, args.previous, args.decoder_approvals)
            if composition['chat_imports']['retry_interval_seconds'] != 60:
                raise ValueError('native D13 replay requires the reviewed D13 runtime')
            runner = NativeReplay(work, source, source_url.geturl(), cache.geturl(), ledger.geturl())
            cold_cache = urlunsplit(cache._replace(path='/1'))
            scratch_ledger = urlunsplit(ledger._replace(path='/1'))
            stage = 'build'
            shutil.copytree(source / 'infra/t34/drill', source / 'server/cmd/t34')
            for name, target in (('api', './cmd/api'), ('drill', './cmd/t34')):
                subprocess.run(['go', 'build', '-trimpath', '-o', str(work / name), target],
                               cwd=source / 'server', capture_output=True, timeout=300, check=True)
            stage = 'pristine-storage'
            runner.verify_empty(restore_url.geturl(), cold_cache, scratch_ledger)
            stage = 'backup-replay'
            receipt = replay(runner, tree, restore_url.geturl(), cold_cache)
            print(json.dumps({'result': 'T34+D13 native replay PASS', 'tree': tree,
                              'previous': args.previous,
                              'schema_digest': schema, 'runtime_composition': composition,
                              'httpcheck': '404/200/401', 'expired_removed': 2,
                              'unexpired_retained': 2, 'active_roots_retained': 4,
                              'production': 'blocked', **receipt},
                             sort_keys=True))
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        # Connection strings, SQL output, fixture bytes and command argv stay private.
        print(f'T34+D13 native replay FAIL stage={stage} ({type(error).__name__})', file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
