#!/usr/bin/env bash
set -euo pipefail
umask 077

usage='usage: accept.sh [--config-only|--preview|--stage-test|--ci-staging|--destroy-stage]'
case "${1:-}" in
  ''|--config-only|--preview|--stage-test|--ci-staging|--destroy-stage) ;;
  *) printf '%s\n' "$usage" >&2; exit 64 ;;
esac
[[ $# -le 1 ]] || { printf '%s\n' "$usage" >&2; exit 64; }

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
archive=$(cd "$here/../.." && pwd)

if [[ ( "${1:-}" == --stage-test || "${1:-}" == --destroy-stage ) && -n "${CI:-}" ]]; then
  printf '%s\n' 'persistent stage and its destroy entry are local-only' >&2
  exit 64
fi
if [[ "${1:-}" == --ci-staging ]]; then
  if [[ "${CI:-}" != true || "${GITHUB_ACTIONS:-}" != true || "${RUNNER_ENVIRONMENT:-}" != self-hosted ]]; then
    printf '%s\n' 'CI staging requires an authorized GitHub Actions self-hosted runner' >&2
    exit 64
  fi
  volume=${T34_STAGING_STATE_VOLUME:-}
  if [[ -z "$volume" ]]; then
    printf '%s\n' 'CI staging requires a project-provisioned T34_STAGING_STATE_VOLUME' >&2
    exit 64
  fi
  if [[ ! "$volume" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}$ || "$volume" == . || "$volume" == .. ]]; then
    printf '%s\n' 'T34_STAGING_STATE_VOLUME must be a Docker volume name, not a path or mount spec' >&2
    exit 64
  fi
fi
if [[ "${1:-}" == --stage-test && "${T34_ALLOW_PERSISTENT_TEST:-}" != 1 ]]; then
  printf '%s\n' 'persistent stage requires explicit local authorization: T34_ALLOW_PERSISTENT_TEST=1' >&2
  exit 64
fi
if [[ "${1:-}" == --destroy-stage ]]; then
  exec python3 "$archive/infra/t34/release.py" --destroy-stage
fi

decoder_approvals=${T34_DECODER_APPROVALS:-}
if [[ "$decoder_approvals" != /* ]]; then
  printf '%s\n' 'T34_DECODER_APPROVALS must be an absolute external approval path' >&2
  exit 64
fi
decoder_approvals=$(python3 - "$archive" "$decoder_approvals" <<'PY'
from pathlib import Path
import stat
import sys

checkout = Path(sys.argv[1]).resolve()
requested = Path(sys.argv[2])
if requested.is_symlink():
    raise SystemExit('T34_DECODER_APPROVALS must not be a symlink')
resolved = requested.resolve()
if resolved == checkout or checkout in resolved.parents:
    raise SystemExit('T34_DECODER_APPROVALS must be outside the checkout')
if not resolved.is_file() or not stat.S_ISREG(resolved.stat().st_mode):
    raise SystemExit('T34_DECODER_APPROVALS must be a regular file')
if stat.S_IMODE(resolved.stat().st_mode) & 0o022:
    raise SystemExit('T34_DECODER_APPROVALS must not be group/other writable')
print(resolved)
PY
)

previous=${T34_PREVIOUS_COMMIT:-}
if [[ ! "$previous" =~ ^[0-9a-f]{40}$ ]]; then
  printf '%s\n' 'T34_PREVIOUS_COMMIT must be a full commit SHA' >&2
  exit 64
fi
repo=$(git -C "$archive" rev-parse --show-toplevel)
candidate_tree=${T34_CANDIDATE_TREE:-$(git -C "$repo" rev-parse 'HEAD^{tree}')}
tmp=$(mktemp -d "${TMPDIR:-/tmp}/t34-stage.XXXXXXXX")
trap 'rm -rf "$tmp"' EXIT HUP INT TERM

# Build contexts come only from the immutable candidate tree and a fixed path
# whitelist. A parent validating uncommitted work must provide a full tree ID.
T34_CANDIDATE_TREE=$candidate_tree PYTHONDONTWRITEBYTECODE=1 \
  python3 "$archive/infra/t34/inputs.py" \
  "$repo" "$tmp/current" "$tmp/prior" "$previous" >/dev/null

revision=$(python3 - "$tmp/current" <<'PY'
from hashlib import sha256
from pathlib import Path
import sys
root = Path(sys.argv[1])
h = sha256()
for path in sorted(p for p in root.rglob('*') if p.is_file()):
    h.update(path.relative_to(root).as_posix().encode() + b'\0')
    h.update(path.read_bytes())
print('archive-' + h.hexdigest())
PY
)

PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s "$tmp/current/infra/t34/tests"
PYTHONDONTWRITEBYTECODE=1 python3 "$tmp/current/infra/t34/release.py" \
  "$tmp/current" "$tmp/prior" "$revision" "$previous" \
  --decoder-approvals "$decoder_approvals" "$@"
