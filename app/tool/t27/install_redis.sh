#!/usr/bin/env bash
# Build native Redis OSS for T27's disposable services on Linux.
set -euo pipefail

destination=${1:?Usage: bash app/tool/t27/install_redis.sh DESTINATION_DIRECTORY}
version=8.2.0
# Published in redis/redis-hashes (README, redis-8.2.0.tar.gz).
sha256=ff95b83b7cf2f7a33af3be1e52fdf2e791c259f8272465c3b09f9e6bc901b604
scratch=$(mktemp -d)
trap 'rm -rf -- "$scratch"' EXIT

archive="$scratch/redis-$version.tar.gz"
curl --fail --silent --show-error --location --proto '=https' --proto-redir '=https' \
  --connect-timeout 10 --max-time 120 --output "$archive" \
  "https://download.redis.io/releases/redis-$version.tar.gz"
printf '%s  %s\n' "$sha256" "$archive" | sha256sum --check --strict

tar -xzf "$archive" -C "$scratch"
source_dir="$scratch/redis-$version"
make -C "$source_dir" -j2 BUILD_WITH_MODULES=no BUILD_TLS=no MALLOC=libc OPTIMIZATION=-O2
binary="$source_dir/src/redis-server"
built_version=$("$binary" --version)
[[ "$built_version" == *" v=$version "* ]]
install -Dm755 "$binary" "$destination/redis-server"
printf '%s\n' "$built_version"
