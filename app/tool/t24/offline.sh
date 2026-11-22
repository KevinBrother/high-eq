#!/usr/bin/env bash
# Offline review coverage. This does not start Docker, HTTP, PG or Redis.
set -euo pipefail
cd "$(dirname "$0")/../../.."
if (($# != 0)); then
  echo 'usage: offline.sh' >&2
  exit 2
fi
command -v flutter >/dev/null 2>&1 || {
  echo 'T24 offline prerequisite missing: flutter' >&2
  exit 2
}
[[ -f app/.dart_tool/package_config.json && -f app/.dart_tool/package_graph.json ]] || {
  echo 'T24 offline prerequisite missing: run flutter pub get in app/' >&2
  exit 2
}
cd app
flutter test --no-pub -r expanded test/reviews
