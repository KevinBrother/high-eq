"""Trusted CI staging identity and crash-persistent unfinished-transition guard."""
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import secrets
import stat
from contextlib import contextmanager

import staging

RECOVERY_DIR_ENV = 'T34_STAGING_RECOVERY_DIR'
INSTANCE_LABEL = 'cn.higheq.t34.state-instance'
JOURNAL = 'transition.json'
_LEGACY_HOLD = 'unresolved'
_PENDING = {'status': 'pending'}
OPERATOR = 'staging recovery blocked; operator verification required'
_INSTANCE = re.compile(r'[0-9a-f]{64}')
_READ_FLAGS = os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK


class RecoveryBlocked(ValueError):
    """Automatic release is not safe; retain the guard and require review."""


@contextmanager
def provisioned_recovery(lab, volume):
    # This must be a preprovisioned, stable runner-local directory outside the
    # checkout, not the temporary Docker client HOME or the state volume itself.
    path = Path(os.environ.get(RECOVERY_DIR_ENV, ''))
    try:
        if not path.is_absolute():
            raise ValueError
        directory = os.open(path, _READ_FLAGS | os.O_DIRECTORY)
    except (OSError, ValueError) as exc:
        raise RecoveryBlocked(OPERATOR + ': recovery directory unavailable') from exc
    try:
        entry = os.fstat(directory)
        if entry.st_uid != os.geteuid() or stat.S_IMODE(entry.st_mode) != 0o700:
            raise RecoveryBlocked(OPERATOR + ': recovery directory is not private')
        try:
            fcntl.flock(directory, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError as exc:
            # Another invocation may be serving. Do not mutate anything on lock failure.
            raise RecoveryBlocked(OPERATOR + ': recovery directory lease not acquired') from exc
        yield Recovery(lab, volume, directory)
    finally:
        os.close(directory)


def _read_provision(directory, volume):
    try:
        fd = os.open('provision.json', _READ_FLAGS, dir_fd=directory)
        with os.fdopen(fd, 'rb') as file:
            entry = os.fstat(file.fileno())
            if (not stat.S_ISREG(entry.st_mode) or entry.st_uid != os.geteuid() or
                    stat.S_IMODE(entry.st_mode) != 0o600):
                raise ValueError
            record = json.loads(file.read(4096))
        if (not isinstance(record, dict) or record.get('volume') != volume or
                not all(isinstance(record.get(k), str) and record[k].strip() == record[k] and
                        record[k] for k in ('engine_id', 'created_at', 'instance')) or
                not _INSTANCE.fullmatch(record['instance'])):
            raise ValueError
    except (OSError, ValueError) as exc:
        raise RecoveryBlocked(OPERATOR + ': trusted provision record invalid') from exc
    return record


class Recovery:
    def __init__(self, lab, volume, directory):
        self.lab, self.volume, self.directory = lab, volume, directory
        self.provision = _read_provision(directory, volume)

    def verify_engine(self):
        try:
            actual = self.lab.run('info', '--format', '{{.ID}}', timeout=15).decode('ascii').strip()
            if actual != self.provision['engine_id']:
                raise ValueError
        except Exception as exc:
            raise staging.StateVolumeUnverified('staging daemon identity could not be verified') from exc

    def verify_owner(self):
        self.verify_engine()
        try:
            entry = json.loads(self.lab.run('volume', 'inspect', '--format', '{{json .}}',
                                            self.volume, timeout=15))
            labels = entry['Labels']
            if (entry['Name'] != self.volume or entry['Driver'] != 'local' or
                    entry['Scope'] != 'local' or entry.get('Options') not in (None, {}) or
                    entry['CreatedAt'] != self.provision['created_at'] or
                    labels[staging.OWNER_LABEL] != self.lab.name or
                    labels[staging.ROLE_LABEL] != staging.STATE_ROLE or
                    labels[INSTANCE_LABEL] != self.provision['instance']):
                raise ValueError
        except Exception as exc:
            raise staging.StateVolumeUnverified('original staging state volume could not be verified') from exc
        self.verify_engine()

    def assert_idle(self):
        self.verify_owner()
        try:
            occupants = self.lab.run('ps', '-aq', '--no-trunc', '--filter', 'volume=' + self.volume,
                                     timeout=30).strip()
        except Exception as exc:
            raise RecoveryBlocked(OPERATOR + ': state volume mount inventory unavailable') from exc
        if occupants:
            # Includes stopped or anonymously named legacy helpers. They are
            # evidence, not implicitly ours to stop, remove, or restart.
            raise RecoveryBlocked(OPERATOR + ': prior writer or other state volume mount remains')
        self.verify_owner()

    def _receipt(self, state):
        return {'status': 'committed', 'instance': self.provision['instance'],
                'state_sha256': hashlib.sha256(staging.state_payload(state)).hexdigest()}

    def _read_journal(self):
        try:
            os.stat(_LEGACY_HOLD, dir_fd=self.directory, follow_symlinks=False)
        except FileNotFoundError:
            pass
        else:
            raise RecoveryBlocked(OPERATOR + ': unresolved prior transition')
        try:
            fd = os.open(JOURNAL, _READ_FLAGS, dir_fd=self.directory)
        except FileNotFoundError:
            return None
        with os.fdopen(fd, 'rb') as file:
            entry = os.fstat(file.fileno())
            if (not stat.S_ISREG(entry.st_mode) or entry.st_uid != os.geteuid() or
                    stat.S_IMODE(entry.st_mode) != 0o600 or not 0 < entry.st_size <= 512):
                raise ValueError('invalid transition journal file')
            receipt = json.load(file)
        if receipt == _PENDING:
            raise RecoveryBlocked(OPERATOR + ': unresolved prior transition')
        if (not isinstance(receipt, dict) or receipt.keys() != {'status', 'instance', 'state_sha256'} or
                receipt['status'] != 'committed' or receipt['instance'] != self.provision['instance'] or
                not isinstance(receipt['state_sha256'], str) or not _INSTANCE.fullmatch(receipt['state_sha256'])):
            raise ValueError('invalid commit receipt')
        # A previous rename may be visible despite a failed directory fsync.
        # Re-establish durability before treating this as evidence, then bind it
        # to the original volume's exact state in read_initial().
        os.fsync(self.directory)
        return receipt

    def read_initial(self):
        """Allow only a virgin volume or an exact affirmative commit receipt."""
        try:
            receipt = self._read_journal()
        except RecoveryBlocked:
            raise
        except (OSError, ValueError) as exc:
            raise RecoveryBlocked(OPERATOR + ': transition journal could not be verified') from exc
        try:
            state = self.read()
        except (RecoveryBlocked, staging.StateVolumeUnverified):
            self.begin()
            raise
        if receipt != (self._receipt(state) if state is not None else None):
            raise RecoveryBlocked(OPERATOR + ': state and durable commit receipt do not agree')
        return state

    def _replace_journal(self, record):
        # Sync each new inode before an atomic replacement. Never unlink the
        # canonical name: after a failed directory fsync recovery sees either
        # the prior record or the fully written replacement, not a clearance by absence.
        tmp = '.transition-' + secrets.token_hex(16)
        fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600, dir_fd=self.directory)
        try:
            with os.fdopen(fd, 'w') as file:
                json.dump(record, file, sort_keys=True)
                file.flush()
                os.fsync(file.fileno())
            os.replace(tmp, JOURNAL, src_dir_fd=self.directory, dst_dir_fd=self.directory)
        except BaseException:
            try:
                os.unlink(tmp, dir_fd=self.directory)
            except OSError:
                pass
            raise
        os.fsync(self.directory)

    def begin(self):
        """Reserve durably before changing storage or starting a writer."""
        try:
            self._replace_journal(_PENDING)
        except OSError as exc:
            raise RecoveryBlocked(OPERATOR + ': could not reserve durable recovery guard') from exc

    def finish(self, state):
        """Record authorization only after state, images and storage were proved."""
        self.assert_idle()
        try:
            self._replace_journal(self._receipt(state))
        except OSError as exc:
            raise RecoveryBlocked(OPERATOR + ': could not sync the commit receipt') from exc

    def read(self):
        self.assert_idle()
        state = staging.read_state(self.lab, self.volume)
        self.verify_owner()
        return state

    def write(self, state):
        self.assert_idle()
        staging.write_state(self.lab, self.volume, state, self.lab.name,
                            verify_owner=self.verify_owner, verify_engine=self.verify_engine)
        self.verify_owner()
