#!/usr/bin/env bash
set -Eeuo pipefail

env_file="${1:?Path to .env is required}"
mode="${2:-full}"
set -a
# shellcheck disable=SC1090
source "${env_file}"
set +a

fail() {
    echo "Migration preflight failed: $*" >&2
    exit 1
}

[[ "${MAIL_SERVER_DISABLED:-}" == "true" ]] || fail "MAIL_SERVER_DISABLED must be true"
[[ "${HANDLE_PREFIX:-}" == "11321" ]] || fail "HANDLE_PREFIX must be 11321 for this dump"
[[ -d "${DSPACE_ASSETSTORE_PATH:-}" ]] || fail "assetstore directory is missing"
[[ -r "${LEGACY_DSPACE_DUMP:-}" ]] || fail "DSpace dump is missing or unreadable"
[[ -r "${LEGACY_UTILITIES_DUMP:-}" ]] || fail "utilities dump is missing or unreadable"
[[ "${LEGACY_DSPACE_DUMP}" != *"dspace-backup-31_3_2017.sql" ]] || fail "the obsolete 2017 dump was selected"

grep -q '^COPY bitstream ' "${LEGACY_DSPACE_DUMP}" || fail "DSpace dump has no bitstream table"
grep -q '^COPY license_definition ' "${LEGACY_UTILITIES_DUMP}" || fail "utilities dump has no license definitions"

asset_sample="$(find "${DSPACE_ASSETSTORE_PATH}" -mindepth 4 -maxdepth 4 -type f -print -quit)"
[[ -n "${asset_sample}" && -r "${asset_sample}" ]] || fail "no readable bitstream sample found in assetstore"

if [[ "${mode}" == "static-only" ]]; then
    echo "Static preflight OK: newest 2026 dumps, Handle 11321, disabled mail and in-place assetstore."
    exit 0
fi

[[ "${mode}" == "full" ]] || fail "unknown preflight mode: ${mode}"

target_counts="$(docker compose --env-file "${env_file}" -f "$(dirname "${env_file}")/compose.yml" \
    exec -T dspacedb psql -U dspace -d dspace -Atc \
    "select count(*) from community; select count(*) from collection; select count(*) from item; select count(*) from bitstream;")"
if grep -qv '^0$' <<<"${target_counts}"; then
    fail "target repository is not empty; use a fresh target database"
fi

echo "Preflight OK: newest 2026 dumps, Handle 11321, empty target and in-place assetstore."
