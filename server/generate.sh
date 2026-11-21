#!/usr/bin/env sh
set -eu
cd "$(dirname "$0")"
for api in app admin; do
  dir=internal/api/$api
  oapi-codegen -config "$dir/config.yaml" "../docs/api/$api.yaml" > "$dir/routes.gen.go"
done
