"""Single-owner synthetic Docker project. No SSH, host mounts, inherited credentials or production services."""
import base64
import hashlib
import json
import os
from pathlib import Path
import re
import secrets
import shutil
import signal
import subprocess as sp
import time

from sweeper import READY as SWEEPER_READY, TARGET_ENV, TARGET_IDENTITY, target_digest

HERE = Path(__file__).resolve().parent
PG = 'postgres:17.6-alpine'
REDIS = 'redis:8.2.0-alpine'
# Exact composition of the local D13/T35 integration base.
COMPOSITION = '9b763c38ad658244e1c56d720179e53795300c49cfed49ef0a4243046e4253b9'
RUNTIME_FILES = (
    ('server/cmd/api/main.go',
     '50f7a771460509c42491c6ccbb2bd4864873de2843469434f53a93b3ea248d62',
     'runtime API maintenance changed'),
    ('server/internal/service/runtime_maintenance.go',
     '121e1f115c4262795d2881a83282a7ab8356e9e628ce59f4d321b00531557ed2',
     'runtime maintenance implementation changed'),
    ('server/internal/training/chat_imports.go',
     'b7f2155b0a8fda4781088338522618a03052514c76a8cfdb2ee58240a7181c2d',
     'runtime chat import retention implementation changed'),
)
RUNTIME_MODULES = (
    'training', 'chat_imports', 'profiles', 'assessments', 'payments',
    'membership', 'accounts', 'replies', 'ai_calls', 'emotion', 'manual_marks',
    'reviews', 'growth',
)
RUNTIME_HOOKS = (
    'payments.Hooks()', 's.Membership.Hooks()', 'assessment.Hooks(c.Fields)',
    'accounts.Hooks(c.Fields)', 'training.Hooks(c.Fields)', 'training.ChatImportHooks()',
    's.Profiles.Hooks()', 'replies.Hooks(c.Fields)', 'gateway.Hooks(c.authMaster)',
    'emotion.Hooks(c.Fields)', 'marks.Hooks(c.Fields)', 'reviews.Hooks(c.Fields)',
    'growth.Hooks(c.Fields, &training.Service{Fields: c.Fields})',
)
RUNTIME_DECODER = 'training.Decoder(c.Fields, reviews.Decoder(c.Fields))'
RUNTIME_EFFECTS = (
    ('ProfileFeedback:s.Profiles.Consume',
     's.Bus.ProfileFeedback.Subscribe(s.Profiles.Consume)'),
    ('ReplyOutcome:s.Profiles.ConsumeReplyOutcome',
     's.Bus.ReplyOutcome.Subscribe(func(ctx context.Context, tx pgx.Tx, v events.ReplyOutcome) error {'
     'return s.Profiles.ConsumeReplyOutcome(ctx, tx, v, s.Replies)})'),
    ('ScoreCompleted:s.Growth.Consume',
     's.Bus.ScoreCompleted.Subscribe(s.Growth.Consume)'),
    ('AssessmentCompleted:s.Plans.ConsumeAssessment',
     's.Bus.AssessmentCompleted.Subscribe(s.Plans.ConsumeAssessment)'),
    ('DrillProgressed:s.Plans.ConsumeDrill',
     's.Bus.DrillProgressed.Subscribe(s.Plans.ConsumeDrill)'),
    ('ScoreCompleted:s.Plans.ConsumeScore',
     's.Bus.ScoreCompleted.Subscribe(s.Plans.ConsumeScore)'),
)
STAGE_PROJECT = 't34-synthetic-stage'
CI_STAGING_PROJECT = 't34-ci-staging'
ALERT_WEBHOOK = 'http://alert-sink:8080/alerts'
CHAT_SWEEPER_PROBE = ('chat-sweeper', 'python3', '/ops/sweeper.py', 'health', '/tmp/chat-sweep.ready')


def _compact(text):
    return re.sub(r'\s+', '', text)


def _call(text, name):
    """Return one balanced Go call, including nested calls and string literals."""
    start = text.index(name)
    opening = text.index('(', start)
    depth = 0
    quote = None
    escaped = False
    line_comment = block_comment = False
    for i in range(opening, len(text)):
        c = text[i]
        nxt = text[i+1] if i+1 < len(text) else ''
        if line_comment:
            if c == '\n':
                line_comment = False
            continue
        if block_comment:
            if c == '*' and nxt == '/':
                block_comment = False
            continue
        if quote:
            if escaped:
                escaped = False
            elif c == '\\':
                escaped = True
            elif c == quote:
                quote = None
            continue
        if c == '/' and nxt == '/':
            line_comment = True
            continue
        if c == '/' and nxt == '*':
            block_comment = True
            continue
        if c in ('"', "'", '`'):
            quote = c
            continue
        if c == '(':
            depth += 1
        elif c == ')':
            depth -= 1
            if depth == 0:
                return text[start:i+1]
    raise ValueError('unterminated composition call')


def composition_receipt(source):
    """Verify a reviewed composition, including the API maintenance paired with it."""
    runtime = source/'server/internal/service/runtime.go'
    if not runtime.is_file():
        raise ValueError('runtime composition missing')
    raw = runtime.read_bytes()
    text = raw.decode()
    required = _call(text, 'privacy.NewRegistry')
    expected_hooks = 'privacy.NewRegistry([]string{' + ','.join(json.dumps(x) for x in RUNTIME_MODULES) + '},' + ','.join(RUNTIME_HOOKS) + ')'
    actual_hooks = _compact(required)
    expected_hooks = _compact(expected_hooks)
    if actual_hooks.endswith(',)'):
        actual_hooks = actual_hooks[:-2] + ')'
    if actual_hooks != expected_hooks:
        raise ValueError('runtime privacy module inventory or hook order changed')
    expected_decoder = 's.Bus=events.New(s.Data,' + _compact(RUNTIME_DECODER) + ')'
    compact = _compact(text)
    if expected_decoder not in compact:
        raise ValueError('runtime score decoder changed')
    cursor = 0
    for _, effect in RUNTIME_EFFECTS:
        call = _compact(effect)
        position = compact.find(call, cursor)
        if position < 0:
            raise ValueError('runtime event effects changed')
        cursor = position + len(call)
    digest = hashlib.sha256(raw).hexdigest()
    if digest != COMPOSITION:
        raise ValueError('offline recovery inventory requires review against runtime')
    for relative, expected, error in RUNTIME_FILES:
        path = source / relative
        if not path.is_file() or hashlib.sha256(path.read_bytes()).hexdigest() != expected:
            raise ValueError(error)
    chat_imports = {'retention_hours': 24, 'startup': 'best-effort', 'retry_interval_seconds': 60}
    return {'sha256': digest, 'modules': list(RUNTIME_MODULES),
            'hooks': list(RUNTIME_HOOKS), 'decoder': RUNTIME_DECODER,
            'effects': [name for name, _ in RUNTIME_EFFECTS], 'chat_imports': chat_imports}


def ticket_document(installation, db_service, cache_service, challenge, seal, dump_sha256, roots,
                    purpose):
    """Build the exact recovery material accepted by gate.sh, without deriving it from a dump."""
    text = {'installation': installation, 'db_service': db_service,
            'cache_service': cache_service, 'challenge': challenge}
    if any(not isinstance(v, str) or not v for v in text.values()):
        raise ValueError('ticket text field missing')
    if not re.fullmatch(r'[0-9a-fA-F-]{36}:[0-9]+', seal or ''):
        raise ValueError('ticket ledger seal invalid')
    if not re.fullmatch(r'[0-9a-f]{64}', dump_sha256 or ''):
        raise ValueError('ticket dump digest invalid')
    if purpose not in ('initial', 'recovery'):
        raise ValueError('ticket purpose invalid')
    if not isinstance(roots, list):
        raise ValueError('ticket roots invalid')
    if purpose == 'initial':
        if roots:
            raise ValueError('initial ticket roots must be empty')
    elif (not roots or any(not isinstance(v, str) or not v for v in roots) or
          len(set(roots)) != len(roots)):
        raise ValueError('recovery ticket roots must be nonempty, valid and unique')
    return {'version': 2, **text, 'ledger_seal': seal,
            'business_dump_sha256': dump_sha256, 'roots': roots, 'purpose': purpose}


def _run_timed_compose(command, *, timeout, input=None, **options):
    """Bound the CLI and its Compose plugin, not just the immediate child."""
    if input is not None:
        if options.get('stdin') is not None:
            raise ValueError('stdin and input arguments may not both be used')
        options['stdin'] = sp.PIPE
    with sp.Popen(command, start_new_session=True, **options) as process:
        try:
            stdout, stderr = process.communicate(input=input, timeout=timeout)
        except BaseException:
            # Kill the group before waiting on the CLI: the plugin may still
            # hold its pipes or be executing even if the CLI is already gone.
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass  # The group exited concurrently; still reap the CLI.
            process.wait()
            raise
        return sp.CompletedProcess(command, process.returncode, stdout, stderr)


class Lab:
    def __init__(self, work, source, persistent=False, ci_staging=False):
        if persistent and ci_staging:
            raise ValueError('stage modes are exclusive')
        self.source = source
        self.persistent = persistent or ci_staging
        self.ci_staging = ci_staging
        self.name = (CI_STAGING_PROJECT if ci_staging else
                     STAGE_PROJECT if persistent else 't34-' + secrets.token_hex(12))
        self.tags = []
        self.owned = False
        conf = work/'docker'; conf.mkdir(mode=0o700)
        # Only plugin binaries, not personal registry auth, contexts or builders.
        plugins = Path.home()/'.docker/cli-plugins'
        if plugins.is_dir():
            (conf/'cli-plugins').mkdir()
            for name in ('docker-compose', 'docker-buildx'):
                if (plugins/name).is_file():
                    (conf/'cli-plugins'/name).symlink_to((plugins/name).resolve())
        sock = next((p for p in (Path('/var/run/docker.sock'), Path.home()/'.docker/run/docker.sock') if p.is_socket()), Path('/var/run/docker.sock'))
        self.env = dict(PATH=os.environ['PATH'], HOME=str(work), DOCKER_CONFIG=str(conf),
                        DOCKER_HOST='unix://'+str(sock), COMPOSE_DISABLE_ENV_FILE='1',
                        CHALLENGE=secrets.token_hex(24), DB_PASS=secrets.token_hex(24), COST_PASS=secrets.token_hex(24),
                        LEDGER_PASS=secrets.token_hex(24), INSTALLATION=self.name, ALERT_WEBHOOK=ALERT_WEBHOOK,
                        TEST_FIELD_KEY=base64.b64encode(secrets.token_bytes(32)).decode(),
                        PG_IMAGE=PG, REDIS_IMAGE=REDIS, API_IMAGE=self.tag('api-b'),
                        WEB_IMAGE=self.tag('web-b'), DRILL_IMAGE=self.tag('drill'), OPS_IMAGE=self.tag('ops'),
                        SINK_IMAGE=self.tag('sink'))
        self.docker = shutil.which('docker') or 'docker'

    def tag(self, name):
        return self.name+'/'+name+':local'

    def run(self, *args, **kw):
        # CalledProcessError must not echo args/stdin: may contain synthetic bearer material.
        check = kw.pop('check', True)
        if not check and 'stderr' not in kw:
            kw['stderr'] = sp.PIPE
        runner = _run_timed_compose if args[0] == 'compose' and kw.get('timeout') is not None else sp.run
        r = runner([self.docker, *map(str,args)], env=self.env, cwd=self.source,
                   stdout=kw.pop('stdout',sp.PIPE), **kw)
        if check and r.returncode:
            raise RuntimeError(f'Docker {args[0]} failed ({r.returncode})')
        return r.stdout if check else r

    def compose(self, *args, overlay='test.yml', preview=False, **kw):
        files = ['-f', HERE/'compose.yml', '-f', HERE/overlay]
        if preview:
            files += ['-f', HERE/'preview.yml']
        return self.run('compose','--env-file','/dev/null','-p',self.name,*files,*args,**kw)

    def _safe_ports(self, services, expose):
        for service, spec in services.items():
            ports = spec.get('ports', [])
            if not ports:
                continue
            if not expose or service != 'web' or len(ports) != 1:
                raise ValueError('host exposure forbidden')
            port = ports[0]
            if (port.get('host_ip') != '127.0.0.1' or int(port.get('target', 0)) != 8080 or
                    port.get('protocol') != 'tcp' or port.get('published') not in ('', None)):
                raise ValueError('persistent/preview port must be random loopback:8080')

    def config(self, expose=False):
        for name in ('test.yml','production.yml'):
            c = json.loads(self.compose('--profile','*','config','--format','json', overlay=name))
            self._safe_ports(c['services'], False)
            for service, spec in c['services'].items():
                if any(v['type']=='bind' for v in spec.get('volumes',[])):
                    raise ValueError('host mount forbidden')
                if name=='production.yml' and service!='release-lock':
                    if spec['depends_on']['release-lock']['condition']!='service_completed_successfully':
                        raise ValueError('missing production lock')
            if name=='test.yml':
                for svc in ('api','web','monitor','backup','chat-sweeper'):
                    if c['services'][svc]['depends_on']['permit']['condition']!='service_completed_successfully':
                        raise ValueError('missing test restore interlock')
                for svc in ('api', 'web'):
                    if c['services'][svc]['depends_on']['chat-sweeper']['condition'] != 'service_healthy':
                        raise ValueError('missing chat import sweep interlock')
                if c['services']['monitor']['depends_on']['alert-sink']['condition']!='service_healthy':
                    raise ValueError('missing local alert delivery dependency')
            if not c['networks']['default']['internal']:
                raise ValueError('egress not isolated')
        if expose:
            c = json.loads(self.compose('--profile','*','config','--format','json', preview=True))
            self._safe_ports(c['services'], True)
            for service, spec in c['services'].items():
                if any(v['type']=='bind' for v in spec.get('volumes',[])):
                    raise ValueError('host mount forbidden')
            if not c['networks']['preview']['internal']:
                raise ValueError('preview egress not isolated')
        print('PASS compose test + locked production (loopback-only exposure when requested)',flush=True)

    def existing_project(self):
        """Return whether any labelled resource proves the fixed project exists."""
        for resource, flag in (('container', '-aq'), ('network', '-q'), ('volume', '-q')):
            if self.run(resource, 'ls', flag,
                        '--filter=label=com.docker.compose.project=' + self.name).strip():
                return True
        return False

    def start(self, allow_existing=False):
        if self.run('info','--format','{{.OSType}}').strip()!=b'linux':
            raise RuntimeError('local Linux daemon required')
        exists = self.existing_project()
        if exists and not allow_existing:
            raise RuntimeError('project already exists')
        if allow_existing and not exists:
            raise RuntimeError('project is missing')
        self.owned = not exists

    def build(self, ctx, target, dockerfile, tag, release):
        image=self.tag(tag); args=['build','-f',ctx/'infra/t34'/dockerfile,'--build-arg','RELEASE='+release,'-t',image]
        if target: args+=['--target',target]
        self.tags.append(image)
        self.run(*args,ctx,stdout=None)
        return self.run('image','inspect','--format','{{.Id}}',image).decode().strip()

    def exec(self, service, *args, **kw):
        return self.compose('exec','-T',service,*args,**kw)

    def job(self, service, *args, entry=None, **kw):
        extra=['--entrypoint',entry] if entry else []
        return self.compose('run','--rm','--no-deps','-T',*extra,service,*args,**kw)

    def sql(self, service, sql, *, timeout=None):
        return self.exec(service,'psql','-XqAt','-U','postgres','-v','ON_ERROR_STOP=1',
                         input=sql.encode(), timeout=timeout).decode().strip()

    @staticmethod
    def _validate_release_ids(ids):
        if not isinstance(ids, (list, tuple)) or len(ids) != 2:
            raise ValueError('release image IDs missing')
        if any(not isinstance(image_id, str) or not re.fullmatch(r'sha256:[0-9a-f]{64}', image_id)
               for image_id in ids):
            raise ValueError('release image ID invalid')

    def preflight_release(self, version, ids):
        """Check local image identity and launch metadata without creating containers."""
        self._validate_release_ids(ids)
        for service, image_id, entrypoint in (
                ('api', ids[0], ['/api']),
                ('web', ids[1], ['nginx', '-g', 'daemon off;'])):
            try:
                image = json.loads(self.run('image', 'inspect', '--format', '{{json .}}',
                                            image_id, timeout=15))
                config = image['Config']
                if image['Id'] != image_id or config['Entrypoint'] != entrypoint:
                    raise ValueError
                if service == 'api' and config['Labels']['org.opencontainers.image.version'] != version:
                    raise ValueError
            except (TypeError, KeyError, ValueError) as exc:
                raise ValueError(f'{service} release image metadata differs from release receipt') from exc

    def require_chat_sweeper(self):
        try:
            ready = self.exec(*CHAT_SWEEPER_PROBE, timeout=15)
        except (RuntimeError, OSError, sp.TimeoutExpired) as exc:
            raise ValueError('chat import sweeper health unavailable') from exc
        if ready.strip() != SWEEPER_READY:
            raise ValueError('chat import sweeper not ready')

    def _start_chat_sweeper(self, preview):
        # Fence ingress first and stop the old worker so a previous receipt
        # cannot authorize a new launch, even on the same database.
        self.compose('stop', '--timeout', '5', 'web', 'api', 'chat-sweeper',
                     preview=preview, timeout=45)
        for service in ('web', 'api', 'chat-sweeper'):
            if self.compose('ps', '-q', service, preview=preview, timeout=15).strip():
                raise ValueError('ingress or old chat import sweeper still running')
        database = self.env.get('DB_SERVICE', 'db')
        if database not in ('db', 'restored'):
            raise ValueError('chat import sweeper target service invalid')
        expected = target_digest(self.sql(database, TARGET_IDENTITY, timeout=15))
        if expected is None:
            raise ValueError('chat import sweeper target identity unavailable')
        self.env[TARGET_ENV] = expected
        try:
            self.compose('up', '-d', '--pull', 'never', '--wait', '--wait-timeout', '120',
                         'chat-sweeper', preview=preview, timeout=130)
        except (RuntimeError, OSError, sp.TimeoutExpired) as exc:
            raise ValueError('chat import sweeper unavailable') from exc
        self.require_chat_sweeper()

    def open_release(self, suffix, version, ids, preview=False, by_id=False):
        self._validate_release_ids(ids)
        if by_id:
            api_image, web_image = ids
        else:
            api_image, web_image = self.tag('api-'+suffix), self.tag('web-'+suffix)
        self.env.update(API_IMAGE=api_image,WEB_IMAGE=web_image)
        try:
            self._start_chat_sweeper(preview)
            self.compose('up','-d','--pull','never','--wait','--wait-timeout','120','api','web',preview=preview)
            for svc,expected in zip(('api','web'),ids):
                cid=self.compose('ps','-q',svc).strip().decode()
                if self.run('inspect','--format','{{.Image}}',cid).decode().strip()!=expected:
                    raise ValueError('running image differs from release receipt')
            for uri in ('/','/main.dart.js','/v1/health','/release.txt'):
                body=self.exec('web','wget','-qO-', 'http://127.0.0.1:8080'+uri)
                ok={'/':b'flutter_bootstrap.js' in body,'/main.dart.js':len(body)>10000,
                    '/v1/health':b'"ok":true' in body,'/release.txt':body.strip()==version.encode()}[uri]
                if not ok: raise ValueError('release smoke failed: '+uri)
            self.require_chat_sweeper()
        except (ValueError, RuntimeError, OSError, sp.TimeoutExpired):
            try:
                self.close_serving()
            except (ValueError, RuntimeError, OSError, sp.TimeoutExpired) as exc:
                raise ValueError('release failed and serving shutdown could not be verified') from exc
            raise

    def permit(self, issue, document=None):
        if issue:
            if document is None:
                raise ValueError('complete ticket required')
            payload=(json.dumps(document,separators=(',',':'),sort_keys=True)+'\n').encode()
            out=self.job('issuer',input=payload)
            if b'ticket_issued' not in out:
                raise ValueError('ticket issue was not acknowledged')
        else:
            self.job('issuer','revoke')
            self.env.pop('BUSINESS_DUMP_SHA256',None)

    def rotate_challenge(self):
        self.env['CHALLENGE']=secrets.token_hex(24)

    def gate_exit(self):
        self.compose('rm','-f','permit')
        self.compose('create','permit')
        cid=self.compose('ps','-aq','permit').decode().strip()
        self.run('start',cid)
        return int(self.run('wait',cid).decode().strip())

    def probe_missing_root(self, root):
        result = self.job('permit', 'probe-missing', root, entry='/ops/gate.sh',
                          check=False, timeout=30)
        if result.returncode != 1 or result.stdout.strip() != b'recovery_gate_refused_missing_root':
            raise ValueError('isolated missing-root probe did not prove refusal')

    def alert_count(self, *, timeout=5):
        try:
            raw = self.exec('alert-sink', '/sink', 'count', timeout=timeout)
        except sp.TimeoutExpired:
            raise ValueError('local alert sink count timed out') from None
        return int(raw.decode().strip())

    def wait_alert_count(self, minimum, timeout=45):
        deadline = time.monotonic() + timeout
        while (remaining := deadline - time.monotonic()) > 0:
            count = self.alert_count(timeout=remaining)
            # A successful exec can race its process timeout; a late count
            # must not satisfy the release interlock, even if it increased.
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                break
            if count >= minimum:
                return count
            time.sleep(min(1, remaining))
        raise ValueError('local alert sink did not receive expected alerts')

    def clear_permit_container(self):
        self.compose('rm','-f','permit')

    def _serving_containers(self):
        storage = {'db', 'ledger', 'cache', 'restored', 'coldcache'}
        rows = self.run('ps', '--no-trunc', '--filter=label=com.docker.compose.project='+self.name,
                        '--format', '{{.ID}} {{.Label "com.docker.compose.service"}}',
                        timeout=15).decode().splitlines()
        return [fields[0] for row in rows if (fields := row.split()) and
                (len(fields) != 2 or fields[1] not in storage)]

    def fenced(self):
        if self._serving_containers():
            raise ValueError('ingress or consumer still running')

    def close_serving(self):
        """Bounded, project-scoped shutdown without removing any persistent asset."""
        services = ('web', 'api', 'monitor', 'backup', 'alert-sink', 'chat-sweeper')

        def running():
            try:
                return self._serving_containers()
            except (RuntimeError, OSError, sp.TimeoutExpired):
                return None  # Unknown is never evidence of an empty project.

        def halt(action, containers):
            try:
                if containers is None:
                    # Compose scopes by project and known services without our ps probe.
                    opts = ('--timeout', '5') if action == 'stop' else ()
                    self.compose('--profile', '*', action, *opts, *services, preview=True,
                                 check=False, timeout=45 if action == 'stop' else 30)
                elif containers:
                    opts = ('--time', '5') if action == 'stop' else ()
                    self.run(action, *opts, *containers, check=False,
                             timeout=45 if action == 'stop' else 30)
            except (RuntimeError, OSError, sp.TimeoutExpired):
                pass  # Regardless of the command result, re-query the running project.

        halt('stop', running())
        for _ in range(2):
            remaining = running()
            if remaining == []:
                return
            halt('kill', remaining)
        if running() != []:
            raise ValueError('ingress or consumer still running, or shutdown could not be verified')


    def clean(self):
        if self.owned:
            if self.ci_staging:
                # CI staging is a persistent project. Never let a failed run erase
                # its volumes, backups or independent deletion ledger.
                return
            self.compose('--profile','*','down','-v','--remove-orphans','--timeout','5',preview=True)
            for tag in set(self.tags):
                if sp.run([self.docker,'image','inspect',tag],env=self.env,stdout=sp.DEVNULL,stderr=sp.DEVNULL).returncode==0:
                    self.run('image','rm',tag)

    def _remove_stage_resources(self):
        self.compose('--profile','*','down','-v','--remove-orphans','--timeout','5',preview=True)
        for name in ('api-a','api-b','web-a','web-b','drill','ops','sink'):
            tag=self.tag(name)
            if sp.run([self.docker,'image','inspect',tag],env=self.env,stdout=sp.DEVNULL,stderr=sp.DEVNULL).returncode==0:
                self.run('image','rm',tag)

    def destroy_stage(self):
        """Destroy only the fixed synthetic stage project and its uniquely tagged images."""
        if not self.persistent or self.name != STAGE_PROJECT:
            raise ValueError('refusing to destroy a non-stage project')
        self._remove_stage_resources()


def inventory(lab):
    # Share the exact verifier with the serving interlock; this job is read-only.
    result = json.loads(lab.job('permit', 'inventory', entry='/ops/gate.sh'))
    return result['seal'], result['deadlines']


def schema_digest(source):
    """Hash every migration name and byte in a stable order; an empty schema is invalid."""
    migrations = source/'server/migrations'
    files = sorted(migrations.glob('*.sql')) if migrations.is_dir() else []
    if not files:
        raise ValueError('schema missing: no automatic binary rollback')
    digest = hashlib.sha256()
    for path in files:
        digest.update(path.name.encode() + b'\0')
        digest.update(path.read_bytes())
        digest.update(b'\0')
    return digest.hexdigest()


def same_schema(a,b):
    before = schema_digest(a)
    after = schema_digest(b)
    if before != after:
        raise ValueError(f'schema differs: no automatic binary rollback ({before} != {after})')
    return before
