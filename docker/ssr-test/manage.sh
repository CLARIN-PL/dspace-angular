#!/usr/bin/env bash
set -Eeuo pipefail

test_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

# The shared local env file sets COMPOSE_PROJECT_NAME for the normal stack.
# An explicit CLI project name takes precedence and keeps these tests isolated.
exec docker compose --project-name clarin-ssr-test \
  --env-file "${test_dir}/../production/.env" \
  -f "${test_dir}/compose.yml" "$@"
