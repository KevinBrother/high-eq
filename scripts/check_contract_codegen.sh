#!/usr/bin/env bash
# Smoke-test the contract consumer; never write generated T04 code to the checkout.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
for api in app admin; do
  cat > "$tmp/config.yaml" <<CFG
package: $api
generate:
  models: true
  gin-server: true
compatibility:
  always-prefix-enum-values: true
CFG
  oapi-codegen -config "$tmp/config.yaml" "$root/docs/api/$api.yaml" > "$tmp/$api.go"
  gofmt -e "$tmp/$api.go" >/dev/null
  grep -q '^type ServerInterface interface {' "$tmp/$api.go"
  echo "$api: generated models and Gin server interface OK"
done
