#!/usr/bin/env bash
set -Eeuo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
env_file="${script_dir}/.env"
compose_file="${script_dir}/compose.yml"

usage() {
    echo "Usage: ./manage.sh {init|config|build|up|down|logs|status|create-admin|db-status}"
}

require_env() {
    if [[ ! -f "${env_file}" ]]; then
        echo "Missing ${env_file}. Run ./manage.sh init first." >&2
        exit 1
    fi
}

compose() {
    docker compose --env-file "${env_file}" -f "${compose_file}" "$@"
}

case "${1:-}" in
    init)
        if [[ -e "${env_file}" ]] && ! grep -q '__POSTGRES_PASSWORD__' "${env_file}"; then
            echo "${env_file} already exists; leaving it unchanged."
            exit 0
        fi
        umask 077
        if [[ ! -e "${env_file}" ]]; then
            cp "${script_dir}/.env.example" "${env_file}"
        fi
        sed -i \
            -e "s|__POSTGRES_PASSWORD__|$(openssl rand -hex 32)|" \
            -e "s|__JWT_LOGIN_SECRET__|$(openssl rand -base64 24)|" \
            -e "s|__JWT_SHORT_LIVED_SECRET__|$(openssl rand -base64 24)|" \
            -e "s|__CLARIN_TOKEN_ENCRYPTION_SECRET__|$(openssl rand -base64 32)|" \
            -e "s|__ADMIN_PASSWORD__|$(openssl rand -hex 16)|" \
            "${env_file}"
        echo "Created ${env_file} with mode 600. Review PUBLIC_URL before a non-local deployment."
        ;;
    config)
        require_env
        compose config --quiet
        echo "Compose configuration is valid."
        ;;
    build)
        require_env
        compose build
        ;;
    up)
        require_env
        compose up -d --build --wait
        compose ps
        ;;
    down)
        require_env
        compose down
        ;;
    logs)
        require_env
        compose logs -f --tail=200 "${@:2}"
        ;;
    status)
        require_env
        compose ps
        ;;
    create-admin)
        require_env
        set -a
        # shellcheck disable=SC1090
        source "${env_file}"
        set +a
        compose exec dspace /dspace/bin/dspace create-administrator \
            -e "${ADMIN_EMAIL}" -f "${ADMIN_FIRST_NAME}" -l "${ADMIN_LAST_NAME}" \
            -p "${ADMIN_PASSWORD}" -c en
        ;;
    db-status)
        require_env
        compose exec dspace /dspace/bin/dspace database status
        ;;
    *)
        usage
        exit 1
        ;;
esac
