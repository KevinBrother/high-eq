#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd -P)"
cd -- "$repo_root"
exec python3 -I -c \
  'import sys; sys.path.insert(0, sys.argv.pop(1)); from ci.hosted_entry import main; raise SystemExit(main())' \
  "$repo_root/infra/t34"
