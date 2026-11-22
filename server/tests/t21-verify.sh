#!/usr/bin/env bash
# Default: exact T21 offline suite. --storage uses only disposable synthetic services.
set -euo pipefail
cd "$(dirname "$0")/.."
go vet -tags integration ./...
go test -tags integration -run '^$' ./...
go test -race -count=1 ./internal/replies ./internal/service ./internal/membership
go test -race -count=1 -run 'TestReplyWholeObjectApproval|TestReplySuggestionCannotDeclareCrisis|TestCallAuthorizeGuards|TestCallAuthorizeHoldsScopeThroughRoutedLookupAndProvider|TestModeratedAttempts|TestRoutedJSONWireAndPrivateStats|TestTerminalContracts' ./internal/gateway
case ${1:-} in
  '') ;;
  --storage) ./tests/migrations.sh; ./tests/runtime.sh ;;
  *) echo 'usage: t21-verify.sh [--storage]' >&2; exit 2 ;;
esac
