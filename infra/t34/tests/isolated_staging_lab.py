"""Narrow Docker boundary for the disposable T34 persistence proof only."""
import json
from pathlib import Path
import re
import secrets
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import lab
from lab import HERE, PG, REDIS
import staging
import staging_recovery


ENGINE_HOST_ENV = 'T34_ISOLATED_STAGING_DOCKER_HOST'
ENGINE_ID_ENV = 'T34_ISOLATED_STAGING_ENGINE_ID'
UUID = re.compile(r'[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}')
# Current Docker engines report a lowercase UUID; retain the historical
# lowercase 64-hex form so the shape check does not reject supported engines.
ENGINE_ID = re.compile(r'(?:' + UUID.pattern + r'|[0-9a-f]{64})')
RUN_ID = re.compile(r'[0-9a-f]{24}')
REVISION = re.compile(r'[0-9a-f]{40}')
RELEASE = re.compile(r'(?:[0-9a-f]{40}|archive-[0-9a-f]{40,64})')
IMAGE_ID = re.compile(r'sha256:[0-9a-f]{64}')
CONTAINER_ID = re.compile(r'[0-9a-f]{12,64}')
OWNER = 'cn.higheq.t34.persistence-proof'
PROJECT = 'com.docker.compose.project'
PG_DATA = '/var/lib/postgresql/data'
RECIPES = {
    'api-a': ('Dockerfile', 'api'), 'api-b': ('Dockerfile', 'api'),
    'web-a': ('Web.Dockerfile', None), 'web-b': ('Web.Dockerfile', None),
    'drill': ('Dockerfile', 'drill'), 'ops': ('Ops.Dockerfile', None),
    'sink': ('Sink.Dockerfile', None),
}
NETWORKS = {'default', 'ledger-net', 'preview'}
VOLUMES = {'business', 'deletions', 'vault', 'quarantine', 'approval'}
# Mask image-declared volumes on services that otherwise do not mount them.
# Leave production YAML and the deployed commands untouched.
MASKS = {'test.yml': dict.fromkeys(('backup', 'monitor', 'permit', 'issuer'), PG_DATA),
         'production.yml': {'release-lock': '/data'}}
for masks in MASKS.values():
    masks['chat-sweeper'] = PG_DATA
BASE_SERVICES = {'db', 'cache', 'ledger', 'api', 'web', 'backup', 'monitor', 'alert-sink', 'chat-sweeper'}
TEST_SERVICES = BASE_SERVICES | {'restored', 'coldcache', 'permit', 'issuer', 'drill'}
SERVICES = TEST_SERVICES | {'release-lock'}
FORMATS = {
    'container': '{{.ID}}\t{{.Names}}',
    'network': '{{.ID}}\t{{.Name}}',
    'volume': '{{.Name}}\t{{.Name}}',
    'image': '{{.ID}}\t{{.Repository}}:{{.Tag}}',
}
INSPECT = {
    'container': ('{{.Id}} {{.State.Running}} {{.State.StartedAt}} {{.RestartCount}} {{.Image}} '
                  '{{json .Mounts}} {{json .NetworkSettings.Networks}}'),
    'network': '{{.Id}}',
    'volume': '{{.Name}} {{.CreatedAt}}',
}


class SafetyError(ValueError):
    pass


def require(condition):
    if not condition:
        raise SafetyError('isolated Docker boundary refused')


def isolated_engine(environ):
    """Require an explicit, non-default Docker daemon and its expected identity."""
    host = environ.get(ENGINE_HOST_ENV)
    identifier = environ.get(ENGINE_ID_ENV)
    require(isinstance(host, str) and isinstance(identifier, str) and ENGINE_ID.fullmatch(identifier))
    require(host.startswith('unix://'))
    path = host[len('unix://'):]
    require(bool(path) and path.startswith('/') and not any(ch in path for ch in '\x00\r\n?#'))
    defaults = ('/var/run/docker.sock', '/run/docker.sock',
                str(Path.home() / '.docker/run/docker.sock'))
    resolved = Path(path).resolve(strict=False)
    require(str(Path(path)) not in defaults and str(resolved) not in {
        str(Path(candidate).resolve(strict=False)) for candidate in defaults
    })
    return host, identifier


def namespace(run_id):
    require(isinstance(run_id, str) and RUN_ID.fullmatch(run_id))
    return 't34-proof-' + run_id


class IsolatedLab(lab.Lab):
    def __init__(self, work, sources, run_id, engine_host, engine_id, owner_token=None, *, durable_state=False):
        name = namespace(run_id)
        self.engine_host, self.engine_id = isolated_engine({
            ENGINE_HOST_ENV: engine_host, ENGINE_ID_ENV: engine_id,
        })
        super().__init__(work, sources[0])
        self.env['DOCKER_HOST'] = self.engine_host
        self.name = name
        self.volume = name + '_state'
        self.work = work
        self.sources = tuple(map(Path, sources))
        if owner_token is None:
            owner_token = secrets.token_hex(24)
        require(isinstance(owner_token, str) and re.fullmatch(r'[0-9a-f]{48}', owner_token))
        # Not the public run ID; also arbitrates competing claims and cross-process reattachment.
        self.token = owner_token
        self._durable_state = durable_state
        self.armed = False
        self._state_writer = None
        self._engine_verified = False
        self._configs = set()
        self._overlays = {}
        for overlay, preview in (('test.yml', False), ('test.yml', True), ('production.yml', False)):
            overlay_path = work / f'proof-{overlay}-{int(preview)}.json'
            test = overlay == 'test.yml'
            labels = {'labels': {OWNER: self.token}}
            services = {name: dict(labels) for name in (TEST_SERVICES if test else BASE_SERVICES | {'release-lock'})}
            for service, target in MASKS[overlay].items():
                services[service]['volumes'] = [{'type': 'tmpfs', 'target': target}]
            overlay_path.write_text(json.dumps({
                'services': services,
                'networks': dict.fromkeys(NETWORKS if preview else NETWORKS - {'preview'}, labels),
                'volumes': dict.fromkeys(VOLUMES if test else VOLUMES - {'quarantine', 'approval'}, labels),
            }))
            self._overlays[overlay, preview] = overlay_path
        self.env.update(INSTALLATION=name, API_IMAGE=self.tag('api-b'), WEB_IMAGE=self.tag('web-b'),
                        DRILL_IMAGE=self.tag('drill'), OPS_IMAGE=self.tag('ops'), SINK_IMAGE=self.tag('sink'))

    def tag(self, name):
        require(name in RECIPES)
        return super().tag(name)

    def _docker(self, *args, **kw):
        # Lab.build requests inherited stdout; no child output may go to the terminal.
        if kw.get('stdout') is None:
            kw.pop('stdout', None)
        elif 'stdout' in kw:
            require(Path(kw['stdout'].name) == self.work / 'business.dump')
        return super().run(*args, stderr=lab.sp.PIPE, **kw)

    def _named(self, value):
        return value == self.name or any(value.startswith(self.name + sep) for sep in ('_', '-', '/', ':', '.'))

    def _rows(self, kind, filter_value):
        args = ['ls', '--format', FORMATS[kind]]
        if kind in ('container', 'image'):
            args += ['-a']
        if kind != 'volume':
            args += ['--no-trunc']
        # Every enumeration is scoped at the daemon. Never list the daemon's
        # complete resource inventory and filter it in this process.
        args += ['--filter', filter_value]
        lines = self._docker(kind, *args).decode().splitlines()
        rows = [tuple(line.split('\t')) for line in lines]
        require(all(len(row) == 2 and all(row) for row in rows))
        return rows

    def _namespace_rows(self, kind):
        filters = ['label=' + OWNER + '=' + self.token,
                   'label=' + PROJECT + '=' + self.name,
                   'reference=' + self.name + '/*' if kind == 'image' else 'name=' + self.name]
        rows = set()
        for filter_value in filters:
            owner_filter = filter_value == 'label=' + OWNER + '=' + self.token
            for row in self._rows(kind, filter_value):
                # A dangling image has no repository name to match. It may only
                # enter through the private owner-label query, never through a
                # name/reference query that could be satisfied by a mutable tag.
                dangling = kind == 'image' and row[1] == '<none>:<none>'
                require(self._named(row[1]) or (dangling and owner_filter))
                rows.add(row)
        return sorted(rows)

    def _verify_engine(self):
        self._engine_verified = False
        raw = self._docker('info', '--format', '{{.ID}}\t{{.OSType}}')
        try:
            identifier, os_type = raw.decode().strip().split('\t')
        except (AttributeError, UnicodeDecodeError, ValueError):
            raise SafetyError('isolated Docker boundary refused') from None
        require(identifier == self.engine_id and os_type == 'linux')
        self._engine_verified = True

    def _check_state_volume(self):
        labels = json.loads(self._docker('volume', 'inspect', '--format', '{{json .Labels}}', self.volume))
        require(isinstance(labels, dict) and
                labels.get(OWNER) == self.token and
                labels.get(staging.OWNER_LABEL) == self.name and
                labels.get(staging.ROLE_LABEL) == staging.STATE_ROLE)
        require(self._docker('volume', 'inspect', '--format', '{{.Driver}} {{json .Options}}',
                             self.volume).strip() in (b'local null', b'local {}'))

    def _image_mounts(self, image, allowed):
        declared = json.loads(self._docker('image', 'inspect', '--format', '{{json .Config.Volumes}}', image))
        require(declared is None or (isinstance(declared, dict) and set(declared) <= allowed))

    def claim(self, *, instance=None):
        require(not self.armed)
        require((not self._durable_state and instance is None) or
                (self._durable_state and isinstance(instance, str) and
                 re.fullmatch(r'[0-9a-f]{64}', instance)))
        # Bind the exact dedicated daemon before inspecting or creating anything.
        self._verify_engine()
        # No mutation (not even state-volume creation) before every collision check.
        for kind in FORMATS:
            require(not self._namespace_rows(kind))
        for image, mount in ((PG, PG_DATA), (REDIS, '/data')):
            self._image_mounts(image, {mount})
        # volume create may succeed on an existing name; never arm if it did not get our private label.
        self._verify_engine()
        extra = ('--label', staging_recovery.INSTANCE_LABEL + '=' + instance) if instance else ()
        self._docker('volume', 'create', '--driver', 'local', '--label', OWNER + '=' + self.token,
                     '--label', staging.OWNER_LABEL + '=' + self.name,
                     '--label', staging.ROLE_LABEL + '=' + staging.STATE_ROLE, *extra, self.volume)
        try:
            self._verify_engine()
            self._check_state_volume()
        except Exception:
            if self._durable_state:
                raise  # The hosted parent retires the whole engine on failure.
            # The name may have won a race with another creator. Recheck the exact
            # private token/labels before removing anything; on any doubt, leave it.
            try:
                self._verify_engine()
                self._check_state_volume()
                self._docker('volume', 'rm', self.volume)
            except Exception:
                pass
            raise
        self.armed = True

    def attach_owned(self, *, allow_empty=False):
        """Reattach to only the exact labelled resources created by this run.

        This is deliberately read-only until every namespace resource, the state
        volume and the daemon identity have been proven. It never creates a
        volume and never adopts an object based on a name or Compose label alone.
        """
        require(not self.armed and isinstance(allow_empty, bool))
        self._verify_engine()
        resources = {kind: self._namespace_rows(kind) for kind in FORMATS}
        if not any(resources.values()):
            if allow_empty:
                return False
            raise SafetyError('isolated Docker boundary refused')
        # A non-empty run namespace must still carry the exact dedicated state
        # volume. This prevents a partial or foreign resource set from arming.
        self._check_state_volume()
        self._owned_resources()
        self.armed = True
        return True

    def owned_namespace_empty(self):
        """Read-only proof that no resource carrying this run's labels remains."""
        self._verify_engine()
        empty = not any(self._namespace_rows(kind) for kind in FORMATS)
        self._verify_engine()
        return empty

    def _compose(self, *args, overlay, preview, **kw):
        files = ['-f', HERE / 'compose.yml', '-f', HERE / overlay]
        if preview:
            files += ['-f', HERE / 'preview.yml']
        files += ['-f', self._overlays[overlay, preview]]
        return self._docker('compose', '--env-file', '/dev/null', '-p', self.name, *files, *args, **kw)

    def _validate_config(self, config, preview, overlay='test.yml'):
        require(config['name'] == self.name and not config.get('secrets') and not config.get('configs'))
        services = config['services']
        require(set(services) <= SERVICES)
        self._safe_ports(services, preview)
        require(bool(services.get('web', {}).get('ports')) == preview)
        for plural, keys in (('networks', NETWORKS), ('volumes', VOLUMES)):
            definitions = config.get(plural, {})
            require(set(definitions) <= keys)
            for key, spec in definitions.items():
                require(spec['name'] == self.name + '_' + key and not spec.get('external') and
                        not spec.get('driver_opts') and spec['labels'].get(OWNER) == self.token)
                if plural == 'networks':
                    require(spec.get('internal') is True and spec.get('driver') in (None, 'bridge'))
                else:
                    require(spec.get('driver') in (None, 'local'))
        masks = MASKS[overlay]
        for service, spec in services.items():
            forbidden = ('build', 'container_name', 'privileged', 'devices', 'device_cgroup_rules',
                         'volumes_from', 'configs', 'secrets', 'pid', 'ipc', 'uts', 'userns_mode',
                         'provider', 'use_api_socket', 'env_file', 'external_links', 'gpus',
                         'develop', 'post_start', 'pre_stop', 'storage_opt', 'annotations', 'runtime',
                         'links', 'credential_spec')
            require(not any(key in spec for key in forbidden) and spec['labels'].get(OWNER) == self.token)
            require(spec.get('network_mode') in (None, 'none'))
            require(set(spec.get('networks') or ()) <= set(config['networks']))
            require(spec.get('pull_policy') in (None, 'never'))
            require(self._allowed_image(spec['image']))
            mounts = spec.get('volumes', [])
            if service in masks:
                require(any(m.get('type') == 'tmpfs' and m['target'] == masks[service] for m in mounts))
            for mount in mounts:
                if mount['type'] == 'tmpfs':
                    require(mount['target'] == masks.get(service) and not mount.get('source'))
                else:
                    require(mount['type'] == 'volume' and mount.get('source') in config.get('volumes', {}) and
                            not (mount.get('volume') or {}).get('subpath'))
        if preview:
            require('preview' in config['networks'] and 'preview' in services['web']['networks'])

    def _allowed_image(self, image):
        """Allow only base images or names that this run may build."""
        if image in (PG, REDIS) or image in {self.tag(key) for key in RECIPES}:
            return True
        if IMAGE_ID.fullmatch(image):
            return self._verify_owned_image(image)
        return False

    def _verify_owned_image(self, image):
        """Prove an existing image was produced by this run, not merely tagged like it."""
        if image in (PG, REDIS):
            return True
        if image not in {self.tag(key) for key in RECIPES} and not IMAGE_ID.fullmatch(image):
            return False
        try:
            labels = json.loads(self._docker('image', 'inspect', '--format', '{{json .Config.Labels}}', image))
        except (TypeError, ValueError, RuntimeError):
            return False
        return isinstance(labels, dict) and labels.get(OWNER) == self.token

    def _compose_command(self, args, overlay, preview):
        args = tuple(args)
        if (self._durable_state and overlay == 'test.yml' and not preview and
                args == ('--profile', 'serve', 'rm', '-f', 'web', 'api')):
            return
        if args[:2] == ('--profile', '*'):
            require(overlay == 'test.yml')
            args = args[2:]
        require(args)
        command, *rest = args
        if overlay == 'production.yml':
            require(not preview and args in (('create', 'release-lock'), ('ps', '-aq', 'release-lock')))
        elif command == 'up':
            flags = {'-d', '--wait', '--wait-timeout', '--pull'}
            while rest and rest[0] in flags:
                flag = rest.pop(0)
                if flag in ('--wait-timeout', '--pull'):
                    require(rest and rest.pop(0) in (('60', '120') if flag == '--wait-timeout' else ('never',)))
            require(rest and set(rest) <= SERVICES - {'release-lock'})
        elif command == 'run':
            require(rest[:3] == ['--rm', '--no-deps', '-T'])
            job = rest[3:]
            require(job in (['issuer'], ['issuer', 'revoke'], ['backup', 'once'],
                            ['--entrypoint', '/ops/gate.sh', 'permit', 'inventory'],
                            ['--entrypoint', 'psql', 'backup', '-XqAt', '-v', 'ON_ERROR_STOP=1']) or
                    (len(job) == 5 and job[:3] == ['--entrypoint', '/ops/gate.sh', 'permit'] and
                     job[3] == 'probe-missing' and UUID.fullmatch(job[4])) or
                    (len(job) == 2 and job[0] == 'drill' and job[1] in ('seed', 'preflight', 'delete', 'restore-plan', 'restore', 'httpcheck')) or
                    (len(job) == 3 and job[:2] == ['backup', 'restore'] and re.fullmatch(r'snap-[a-zA-Z0-9]+', job[2])) or
                    (len(job) == 4 and job[:3] == ['--entrypoint', 'cat', 'backup'] and
                     re.fullmatch(r'/vault/snap-[a-zA-Z0-9]+/(inventory|SHA256SUMS|business\.dump)', job[3])))
        elif command == 'exec':
            if rest[:2] == ['-T', 'chat-sweeper']:
                require(tuple(rest) == ('-T', *lab.CHAT_SWEEPER_PROBE))
                return
            require(len(rest) >= 3 and rest[0] == '-T' and rest[1] in SERVICES - {'release-lock'} and
                    rest[2] in ('psql', '/sink', 'redis-cli', 'wget', '/ops/ops.sh', 'sh'))
        elif command in ('stop', 'kill', 'restart'):
            services = list(rest)
            if command in ('stop', 'kill') and services and services[0] in ('--time', '--timeout'):
                require(len(services) >= 2 and services[1].isdigit() and 0 < int(services[1]) <= 300)
                services = services[2:]
            require(services and set(services) <= SERVICES - {'release-lock'})
        else:
            require(args in (('rm', '-f', 'permit'), ('create', 'permit'), ('ps', '-aq', 'permit'),
                             ('ps', '-q', 'api'), ('ps', '-q', 'web'), ('ps', '-q', 'chat-sweeper')) or
                    (preview and args == ('port', 'web', '8080')))

    def compose(self, *args, overlay='test.yml', preview=False, **kw):
        require((overlay, preview) in self._overlays and isinstance(preview, bool) and args)
        # Validate the immutable Compose source once per interpolated environment and overlay.
        key = (overlay, preview, tuple(sorted(self.env.items())))
        is_config = args == ('--profile', '*', 'config', '--format', 'json')
        self._verify_engine()
        if not is_config:
            require(self.armed)
            self._compose_command(args, overlay, preview)
            # Every mutation starts from a fresh proof that all visible project
            # resources carry this run's private owner token.
            self._owned_resources()
        if is_config or key not in self._configs:
            raw = self._compose('--profile', '*', 'config', '--format', 'json', overlay=overlay, preview=preview)
            self._validate_config(json.loads(raw), preview, overlay)
            self._configs.add(key)
            if is_config:
                return raw
        # Bind the endpoint again after resource inspection and any rendered
        # config read, immediately before the requested mutation.
        self._verify_engine()
        if args[0] == 'up' and '--pull' not in args:
            args = ('up', '--pull', 'never', *args[1:])
        return self._compose(*args, overlay=overlay, preview=preview, **kw)

    def existing_project(self):
        require(self.armed)
        resources = self._owned_resources()
        # The separately provisioned state volume does not constitute a Compose project.
        return bool(resources['container'] or resources['network'] or
                    any(name != self.volume for _, name in resources['volume']))

    def start(self, allow_existing=False):
        require(self.armed)
        self._check_state_volume()
        super().start(allow_existing=allow_existing)

    def _container(self, ref, expected_name=None):
        require(CONTAINER_ID.fullmatch(ref))
        raw = self._docker('container', 'inspect', '--format', '{{.Id}} {{.Name}} {{json .Config.Labels}}', ref)
        identifier, name, labels = raw.decode().split(maxsplit=2)
        labels = json.loads(labels) or {}
        require(CONTAINER_ID.fullmatch(identifier) and identifier.startswith(ref) and
                name.startswith('/' + self.name + '-') and
                labels.get(OWNER) == self.token and
                (labels.get(PROJECT) == self.name or name == '/' + self.name + '-state-helper'))
        if expected_name is not None:
            require(name == '/' + expected_name)
        return identifier

    def _state_helper(self, args, **kw):
        """Run only the current read-only or settled writer helper contract."""
        image = staging._helper_image(self)
        read = ('run', '--rm', '--network', 'none', '--read-only',
                '-v', self.volume + ':/state:ro')
        create = ('create', '-i', '--network', 'none', '-v', self.volume + ':/state')
        durable = self._durable_state and args == (*create, '--user', '0:0', '--entrypoint',
                                                  'python3', self.tag('ops'), '-c',
                                                  staging._DURABLE_WRITER, '/state')
        require(durable or (image == PG and args[-5:-1] == ('--entrypoint', 'sh', image, '-c') and
                            (args[:-5] == read or (not self._durable_state and args[:-5] == create))))
        self._verify_engine()
        self._check_state_volume()
        if durable:
            require(self._verify_owned_image(self.tag('ops')))
            self._image_mounts(self.tag('ops'), {PG_DATA})
        self._verify_engine()
        name = self.name + '-state-helper'
        controlled = ('--name', name, '--label', OWNER + '=' + self.token,
                      '--pull=never', '--mount', 'type=tmpfs,dst=' + PG_DATA)
        if args[:-5] == read:
            require(not kw)
            return self._docker('run', *controlled, *args[1:])

        require(not self._state_writer and set(kw) == {'timeout'} and kw['timeout'] == 30)
        created = self._docker('create', *controlled, *args[1:], **kw)
        try:
            writer = created.decode('ascii').strip()
        except (AttributeError, UnicodeDecodeError) as exc:
            raise SafetyError('isolated Docker boundary refused') from exc
        require(CONTAINER_ID.fullmatch(writer))
        try:
            self._verify_engine()
            writer = self._container(writer, name)
            self._verify_engine()
        except BaseException:
            self._state_writer = None
            raise
        self._state_writer = writer
        return writer.encode('ascii')

    def _verified_state_writer(self, reference):
        require(self._state_writer is not None and isinstance(reference, str) and
                CONTAINER_ID.fullmatch(reference))
        self._verify_engine()
        writer = self._container(reference)
        self._verify_engine()
        require(writer == self._state_writer)
        return writer

    def _start_state_writer(self, args, **kw):
        require(len(args) == 4 and args[:3] == ('start', '-a', '-i'))
        payload = kw.get('input')
        require(set(kw) == {'input', 'timeout'} and isinstance(payload, bytes) and payload and
                kw['timeout'] == 120)
        writer = self._verified_state_writer(args[3])
        self._verify_engine()
        result = self._docker('start', '-a', '-i', writer, **kw)
        self._verify_engine()
        return result

    def _remove_state_writer(self, args, **kw):
        require(len(args) == 3 and args[:2] == ('rm', '-f') and
                set(kw) == {'timeout'} and kw['timeout'] == 30)
        writer = self._verified_state_writer(args[2])
        self._verify_engine()
        result = self._docker('rm', '-f', writer, **kw)
        self._verify_engine()
        return result

    def _probe_state_writer(self, args, **kw):
        require(len(args) == 4 and args[:3] == ('ps', '-aq', '--filter') and
                args[3].startswith('id=') and
                set(kw) == {'timeout'} and kw['timeout'] == 30)
        writer = args[3][3:]
        # The exact writer was verified before start/rm. It may now be gone, so
        # the post-remove probe binds to the recorded identity without an inspect.
        require(self._state_writer is not None and writer == self._state_writer)
        self._verify_engine()
        raw = self._docker('ps', '-aq', '--filter', 'id=' + writer, **kw)
        try:
            rows = raw.decode('ascii').split()
        except (AttributeError, UnicodeDecodeError) as exc:
            raise SafetyError('isolated Docker boundary refused') from exc
        require(len(rows) <= 1 and all(CONTAINER_ID.fullmatch(row) and writer.startswith(row)
                                        for row in rows))
        if not rows:
            self._state_writer = None
        self._verify_engine()
        return raw

    def vault_entries(self):
        """Read completed vault snapshots without restarting a stopped consumer."""
        require(self.armed)
        vault = self.name + '_vault'
        self._verify_engine()
        self._check_project_volume(vault)
        self._verify_engine()
        # ops.sh publishes whole snapshot directories by rename; skip in-progress
        # .partial directories. The helper has no network, bind mount or API data.
        script = '''
          for d in /vault/snap-*; do
            [ -d "$d" ] || continue
            (cd "$d" && sha256sum -c SHA256SUMS >/dev/null &&
              printf '%s ' "${d##*/}" && sha256sum business.dump SHA256SUMS inventory | awk '{print $1}' | xargs)
          done
        '''
        return self._docker(
            'run', '--rm', '--name', self.name + '-vault-evidence',
            '--label', OWNER + '=' + self.token,
            '--label', PROJECT + '=' + self.name,
            '--network', 'none', '--read-only', '--pull=never',
            '--mount', 'type=volume,src=' + vault + ',dst=/vault,readonly',
            '--mount', 'type=tmpfs,dst=' + PG_DATA,
            '--entrypoint', 'sh', PG, '-c', script,
        )

    def state_file_fingerprint(self):
        # Compare file contents and identity without reserializing credentials.
        state = '/state/' + staging.STATE_FILE
        script = f'set -eu; stat -c "%i %y %a" {state}; sha256sum {state}'
        return self.run('run', '--rm', '--network', 'none', '--read-only', '-v', self.volume + ':/state:ro',
                        '--entrypoint', 'sh', PG, '-c', script)

    def _build(self, args, **kw):
        require(len(args) in (8, 10) and args[1] == '-f' and args[3] == '--build-arg' and args[5] == '-t')
        ctx = args[-1]
        require(ctx in self.sources and args[4].startswith('RELEASE=') and RELEASE.fullmatch(args[4][8:]))
        recipe = next((v for k, v in RECIPES.items() if args[6] == self.tag(k)), None)
        require(recipe is not None)
        dockerfile, target = recipe
        require(args[2] == ctx / 'infra/t34' / dockerfile and
                args[7:-1] == (('--target', target) if target else ()))
        # Retagging in phase two is legal only over images built by this same run.
        self._verify_engine()
        current = self._rows('image', 'reference=' + args[6])
        require(all(self._verify_owned_image(identifier) for identifier, _ in current))
        self._verify_engine()
        result = self._docker('build', '--label', OWNER + '=' + self.token, *args[1:], **kw)
        self._verify_engine()
        require(self._verify_owned_image(args[6]))
        self._image_mounts(args[6], {PG_DATA} if args[6] == self.tag('ops') else set())
        return result

    def run(self, *args, **kw):
        require(self.armed and args)
        if self._durable_state:
            evidence = self._fixed_staging_probe(args, kw)
            if evidence is not None:
                return evidence
        if args[0] in ('run', 'create'):
            return self._state_helper(args, **kw)
        if args[0] == 'start' and len(args) == 4:
            return self._start_state_writer(args, **kw)
        if args[0] == 'rm' and len(args) == 3:
            return self._remove_state_writer(args, **kw)
        if args[0] == 'ps' and len(args) == 4 and args[1:3] == ('-aq', '--filter'):
            return self._probe_state_writer(args, **kw)
        if args[0] == 'build':
            return self._build(args, **kw)
        if args == ('volume', 'inspect', '--format', '{{json .Labels}}', self.volume):
            self._verify_engine()
            self._check_state_volume()
        elif len(args) == 2 and args[0] in ('start', 'wait', 'rm'):
            self._verify_engine()
            container = self._container(args[1])
            self._verify_engine()
            args = (args[0], container)
        elif len(args) == 4 and args[:3] == ('inspect', '--format', '{{.Image}}'):
            self._verify_engine()
            args = ('container', *args[:3], self._container(args[3]))
        elif (len(args) == 5 and args[:4] == ('image', 'inspect', '--format', '{{.Id}}') and
              self._verify_owned_image(args[4])):
            pass
        elif args[0] in ('stop', 'kill'):
            rest = list(args[1:])
            option = ()
            if rest and rest[0] in ('--time', '--timeout'):
                require(len(rest) >= 2 and rest[1].isdigit() and 0 < int(rest[1]) <= 300)
                option = tuple(rest[:2])
                rest = rest[2:]
            require(rest and all(CONTAINER_ID.fullmatch(ref) for ref in rest))
            self._verify_engine()
            rest = [self._container(ref) for ref in rest]
            self._verify_engine()
            args = (args[0], *option, *rest)
        elif args == ('ps', '--no-trunc',
                      '--filter=label=' + PROJECT + '=' + self.name,
                      '--format', '{{.ID}} {{.Label "com.docker.compose.service"}}'):
            self._verify_engine()
            raw = self._docker(*args, **kw)
            for row in raw.decode().splitlines():
                fields = row.split()
                require(len(fields) == 2 and CONTAINER_ID.fullmatch(fields[0]) and fields[1] in SERVICES)
                # The project filter is a daemon-side scope, but the private
                # owner label is the final proof that this is our container.
                self._container(fields[0])
            self._verify_engine()
            return raw
        elif args not in (('info', '--format', '{{.OSType}}'),
                          ('info', '--format', '{{.ID}}\t{{.OSType}}')):
            raise SafetyError('isolated Docker command refused')
        return self._docker(*args, **kw)

    def _fixed_staging_probe(self, args, kw):
        """Allow only the fixed runner's source-bound, read-only probes."""
        if args == ('info', '--format', '{{.ID}}') and kw == {'timeout': 15}:
            self._verify_engine()
        elif (args == ('volume', 'inspect', '--format', '{{json .}}', self.volume) and
              kw == {'timeout': 15}):
            self._verify_engine()
            self._check_state_volume()
        elif (args == ('ps', '-aq', '--no-trunc', '--filter', 'volume=' + self.volume) and
              kw == {'timeout': 30}):
            self._verify_engine()
            self._check_state_volume()
        elif (len(args) == 4 and args[:3] == ('inspect', '--format', '{{.State.Status}}:{{.State.ExitCode}}') and
              kw == {'timeout': 30}):
            args = ('container', *args[:3], self._verified_state_writer(args[3]))
        elif (len(args) == 5 and args[:4] == ('image', 'inspect', '--format', '{{json .}}') and
              kw == {'timeout': 15}):
            self._verify_engine()
            require(IMAGE_ID.fullmatch(args[4]) and self._verify_owned_image(args[4]))
        else:
            return None
        self._verify_engine()
        return self._docker(*args, **kw)

    def _check_project_volume(self, name):
        require(name.startswith(self.name + '_') and
                name in {self.name + '_' + key for key in VOLUMES})
        labels = json.loads(self._docker('volume', 'inspect', '--format', '{{json .Labels}}', name))
        # Compose adds its own labels; require the two ownership labels but do
        # not reject an otherwise correctly-owned volume for having extra ones.
        require(isinstance(labels, dict) and
                labels.get(OWNER) == self.token and labels.get(PROJECT) == self.name)

    def _check_project_network(self, identifier, name):
        require(CONTAINER_ID.fullmatch(identifier) and
                name in {self.name + '_' + key for key in NETWORKS})
        labels = json.loads(self._docker('network', 'inspect', '--format', '{{json .Labels}}', identifier))
        require(isinstance(labels, dict) and
                labels.get(OWNER) == self.token and labels.get(PROJECT) == self.name)

    def _check_image_tag(self, name, identifier):
        """Re-read a mutable tag and bind its current ID to this run before removal."""
        require(name in {self.tag(key) for key in RECIPES} and IMAGE_ID.fullmatch(identifier))
        rows = self._rows('image', 'reference=' + name)
        require(len(rows) == 1 and rows[0] == (identifier, name) and
                self._verify_owned_image(identifier))

    def _owned_resources(self):
        self._verify_engine()
        self._check_state_volume()
        resources = {kind: self._namespace_rows(kind) for kind in FORMATS}
        for kind, rows in resources.items():
            for identifier, name in rows:
                if kind == 'container':
                    require(name.startswith(self.name + '-'))
                    self._container(identifier, name)
                    mounts = json.loads(self._docker('container', 'inspect', '--format', '{{json .Mounts}}', identifier))
                    require(all(m['Type'] == 'tmpfs' or
                                (m['Type'] == 'volume' and m['Name'] in {name for _, name in resources['volume']})
                                for m in mounts or []))
                elif kind == 'image':
                    require(name in {self.tag(key) for key in RECIPES} | {'<none>:<none>'} and
                            IMAGE_ID.fullmatch(identifier) and self._verify_owned_image(identifier))
                elif kind != 'volume' or name != self.volume:
                    require(name in {self.name + '_' + key for key in (VOLUMES if kind == 'volume' else NETWORKS)})
                    labels = json.loads(self._docker(kind, 'inspect', '--format', '{{json .Labels}}', identifier))
                    require((labels or {}).get(PROJECT) == self.name and labels.get(OWNER) == self.token)
        return resources

    def resource_snapshot(self):
        self._verify_engine()
        resources = self._owned_resources()
        result = {kind: [(name, self._docker(kind, 'inspect', '--format', INSPECT[kind], identifier))
                         if kind != 'image' else (name, identifier) for identifier, name in rows]
                  for kind, rows in resources.items()}
        self._verify_engine()
        return result

    def resource_identities(self):
        """Stable names/IDs only; container running state is intentionally excluded."""
        self._verify_engine()
        resources = self._owned_resources()
        result = {kind: tuple(sorted((identifier, name) for identifier, name in rows))
                  for kind, rows in resources.items()}
        self._verify_engine()
        return result

    def clean(self):
        if not self.armed:
            return
        # Bind the same daemon and every target again immediately before each
        # destructive command. Never sweep by prefix alone or use prune/force-image-rm.
        self._verify_engine()
        resources = self._owned_resources()
        for identifier, name in resources['container']:
            self._verify_engine()
            verified = self._container(identifier, name)
            self._verify_engine()
            self._docker('container', 'rm', '-f', verified)
        for identifier, name in resources['network']:
            self._verify_engine()
            self._check_project_network(identifier, name)
            self._verify_engine()
            self._docker('network', 'rm', identifier)
        for identifier, name in resources['volume']:
            if name != self.volume:
                self._verify_engine()
                self._check_project_volume(name)
                self._verify_engine()
                self._docker('volume', 'rm', name)
        # Remove our tags first, then old untagged build outputs; never remove
        # another alias or an image that no longer carries our private token.
        for identifier, name in resources['image']:
            if name != '<none>:<none>':
                self._verify_engine()
                self._check_image_tag(name, identifier)
                self._verify_engine()
                self._docker('image', 'rm', '--no-prune', name)
        self._verify_engine()
        dangling_images = self._namespace_rows('image')
        for identifier, name in dangling_images:
            if name == '<none>:<none>':
                self._verify_engine()
                require(IMAGE_ID.fullmatch(identifier) and self._verify_owned_image(identifier))
                self._verify_engine()
                self._docker('image', 'rm', '--no-prune', identifier)
        # Recheck the exact claim immediately before releasing the state volume.
        self._verify_engine()
        self._check_state_volume()
        self._verify_engine()
        self._docker('volume', 'rm', self.volume)
        self.armed = False
