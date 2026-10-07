#!/usr/bin/env bash
set -Eeuo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
env_file="${ENV_FILE:-${script_dir}/.env}"
mode="${1:-auto}"

expected_root_uuid="${EXPECTED_ROOT_UUID:-0f47aa0b-ff21-4f64-907b-756a54e3e236}"
expected_docker_uuid="${EXPECTED_DOCKER_UUID:-f5eb7a92-fb2f-409c-a3a5-f270848441e0}"
expected_docker_root="${EXPECTED_DOCKER_ROOT:-/var/lib/docker}"
staged_checksums="${STAGED_INPUT_CHECKSUMS:-/home/tnaskret/dspace/staging-backups/STAGED_INPUTS.sha256}"

failures=0
warnings=0

pass() { printf 'PASS  %s\n' "$*"; }
warn() { printf 'WARN  %s\n' "$*"; warnings=$((warnings + 1)); }
fail() { printf 'FAIL  %s\n' "$*"; failures=$((failures + 1)); }

check_command() {
    if command -v "$1" >/dev/null 2>&1; then
        pass "command available: $1"
    else
        fail "required command missing: $1"
    fi
}

check_service() {
    local unit="$1"
    if systemctl is-enabled --quiet "${unit}" && systemctl is-active --quiet "${unit}"; then
        pass "${unit} is enabled and active"
    else
        fail "${unit} is not both enabled and active"
    fi
}

check_mount_uuid() {
    local path="$1"
    local expected="$2"
    local actual
    actual="$(findmnt -n -T "${path}" -o UUID 2>/dev/null || true)"
    if [[ -n "${actual}" && "${actual}" == "${expected}" ]]; then
        pass "${path} is on expected filesystem UUID ${expected}"
    else
        fail "${path} filesystem UUID is ${actual:-<none>}; expected ${expected}"
    fi
}

check_free_space() {
    local path="$1"
    local maximum="$2"
    local used
    used="$(df -P "${path}" | awk 'NR == 2 {gsub(/%/, "", $5); print $5}')"
    if [[ "${used}" =~ ^[0-9]+$ ]] && (( used < maximum )); then
        pass "${path} usage is ${used}% (< ${maximum}%)"
    else
        fail "${path} usage is ${used:-unknown}% (required < ${maximum}%)"
    fi
}

if [[ "${EUID}" -ne 0 ]]; then
    fail "run this check as root"
fi

case "${mode}" in
    auto|maintenance|production) ;;
    *)
        echo "Usage: $0 [auto|maintenance|production]" >&2
        exit 2
        ;;
esac

for command_name in findmnt docker curl sha256sum systemctl; do
    check_command "${command_name}"
done

if [[ ! -r "${env_file}" ]]; then
    fail "production environment is not readable: ${env_file}"
    assetstore_path=""
    assetstore_uuid=""
else
    assetstore_path="$(sed -n 's/^DSPACE_ASSETSTORE_PATH=//p' "${env_file}" | tail -n 1)"
    assetstore_uuid="$(sed -n 's/^DSPACE_ASSETSTORE_UUID=//p' "${env_file}" | tail -n 1)"
    [[ -n "${assetstore_path}" ]] || fail "DSPACE_ASSETSTORE_PATH is empty"
    [[ -n "${assetstore_uuid}" ]] || fail "DSPACE_ASSETSTORE_UUID is empty"
fi

check_mount_uuid / "${expected_root_uuid}"
check_mount_uuid "${expected_docker_root}" "${expected_docker_uuid}"
if [[ -n "${assetstore_path}" && -n "${assetstore_uuid}" ]]; then
    check_mount_uuid "${assetstore_path}" "${assetstore_uuid}"
    if [[ -d "${assetstore_path}" ]]; then
        pass "assetstore directory exists: ${assetstore_path}"
    else
        fail "assetstore directory is missing: ${assetstore_path}"
    fi
fi

check_free_space / 85
check_free_space "${expected_docker_root}" 85
if [[ -n "${assetstore_path}" && -d "${assetstore_path}" ]]; then
    check_free_space "${assetstore_path}" 85
fi

check_service ssh.service
check_service docker.service
check_service lvm2-monitor.service

docker_root="$(docker info --format '{{.DockerRootDir}}' 2>/dev/null || true)"
if [[ "${docker_root}" == "${expected_docker_root}" ]]; then
    pass "Docker data root is ${expected_docker_root}"
else
    fail "Docker data root is ${docker_root:-<unknown>}; expected ${expected_docker_root}"
fi

required_images=(
    clarin-pl/dspace-angular:local
    clarin-pl/dspace-backend:local
    clarin-pl/dspace-postgres:local
    clarin-pl/dspace-shibboleth:local
    clarin-pl/dspace-solr:local
    clarin-pl/dspace-migrate:local
    nginx:1.30.4-alpine
    postgres:11.22-bullseye
)
for image_name in "${required_images[@]}"; do
    if docker image inspect "${image_name}" >/dev/null 2>&1; then
        pass "image available: ${image_name}"
    else
        fail "image missing: ${image_name}"
    fi
done

if [[ -r "${staged_checksums}" ]]; then
    if sha256sum --quiet -c "${staged_checksums}"; then
        pass "staged database dumps and Shibboleth credentials match SHA-256"
    else
        fail "staged input checksum verification failed: ${staged_checksums}"
    fi
else
    fail "staged input checksum file is missing: ${staged_checksums}"
fi

failed_units="$(systemctl --failed --no-legend --plain 2>/dev/null || true)"
if [[ -z "${failed_units}" ]]; then
    pass "systemd reports no failed units"
else
    fail "systemd has failed units: ${failed_units//$'\n'/; }"
fi

if [[ "${mode}" == "auto" ]]; then
    if docker ps --format '{{.Names}}' | grep -qx 'clarin-pl-dspace-gateway-1'; then
        mode="production"
    else
        mode="maintenance"
    fi
fi

if [[ "${mode}" == "maintenance" ]]; then
    maintenance_name="$(docker ps --filter 'name=clarin-pl-maintenance' --format '{{.Names}}' | head -n 1)"
    if [[ -n "${maintenance_name}" ]]; then
        pass "maintenance container is running: ${maintenance_name}"
    else
        fail "maintenance container is not running"
    fi
    http_url="http://127.0.0.1/"
else
    http_bind="$(sed -n 's/^HTTP_BIND=//p' "${env_file}" | tail -n 1)"
    http_port="$(sed -n 's/^HTTP_PORT=//p' "${env_file}" | tail -n 1)"
    [[ "${http_bind}" == "0.0.0.0" ]] && http_bind="127.0.0.1"
    http_url="http://${http_bind:-127.0.0.1}:${http_port:-4000}/app/health"
    unhealthy="$(docker ps --filter 'label=com.docker.compose.project=clarin-pl-dspace' \
        --filter 'health=unhealthy' --format '{{.Names}}' | paste -sd, -)"
    if [[ -z "${unhealthy}" ]]; then
        pass "no unhealthy production containers"
    else
        fail "unhealthy production containers: ${unhealthy}"
    fi
fi

http_status="$(curl --silent --show-error --output /dev/null --write-out '%{http_code}' \
    --max-time 10 "${http_url}" 2>/dev/null || true)"
if [[ "${http_status}" == "200" ]]; then
    pass "${mode} endpoint returned HTTP 200: ${http_url}"
else
    fail "${mode} endpoint returned HTTP ${http_status:-error}: ${http_url}"
fi

if [[ "${mode}" == "production" ]]; then
    gateway_base_url="${http_url%/app/health}"
    actuator_health_status="$(curl --silent --show-error --output /dev/null --write-out '%{http_code}' \
        --max-time 10 "${gateway_base_url}/actuator/health" 2>/dev/null || true)"
    if [[ "${actuator_health_status}" == "200" ]]; then
        pass "public Health route is available through the gateway"
    else
        fail "public Health route returned HTTP ${actuator_health_status:-error} through the gateway"
    fi

    actuator_info_status="$(curl --silent --show-error --output /dev/null --write-out '%{http_code}' \
        --max-time 10 "${gateway_base_url}/actuator/info" 2>/dev/null || true)"
    if [[ "${actuator_info_status}" == "401" ]]; then
        pass "Actuator info remains protected from anonymous access"
    else
        fail "Actuator info returned HTTP ${actuator_info_status:-error} without authentication (expected 401)"
    fi
fi

if journalctl -b -p err --no-pager 2>/dev/null | grep -Eqi \
    'EXT4-fs error|I/O error|Buffer I/O|device-mapper.*error|lvm.*failed'; then
    fail "current boot journal contains storage-related errors"
else
    pass "current boot journal contains no detected storage-related errors"
fi

printf '\nSUMMARY failures=%d warnings=%d mode=%s\n' "${failures}" "${warnings}" "${mode}"
(( failures == 0 ))
