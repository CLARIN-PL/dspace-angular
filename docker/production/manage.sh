#!/usr/bin/env bash
set -Eeuo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
env_file="${script_dir}/.env"
compose_file="${script_dir}/compose.yml"
migration_compose_file="${script_dir}/compose.migration.yml"

usage() {
    echo "Usage: ./manage.sh {init|config|build|up|down|logs|status|post-reboot-check|create-admin|workflow-setup|db-status|b-centre-audit|migration-preflight|migration-prepare|migration-run|migration-resume|migration-status|migration-license-mappings|migration-finalize|migration-fixity|migration-logs}"
}

require_env() {
    if [[ ! -f "${env_file}" ]]; then
        echo "Missing ${env_file}. Run ./manage.sh init first." >&2
        exit 1
    fi
}

verify_external_storage() {
    require_env
    local assetstore_path assetstore_uuid key_path cert_path mounted_uuid
    assetstore_path="$(sed -n 's/^DSPACE_ASSETSTORE_PATH=//p' "${env_file}" | tail -n 1)"
    assetstore_uuid="$(sed -n 's/^DSPACE_ASSETSTORE_UUID=//p' "${env_file}" | tail -n 1)"
    key_path="$(sed -n 's/^SHIBBOLETH_KEY_PATH=//p' "${env_file}" | tail -n 1)"
    cert_path="$(sed -n 's/^SHIBBOLETH_CERT_PATH=//p' "${env_file}" | tail -n 1)"

    if [[ -z "${assetstore_uuid}" ]]; then
        echo "DSPACE_ASSETSTORE_UUID is missing from ${env_file}." >&2
        exit 1
    fi
    if [[ ! -d "${assetstore_path}" || ! -f "${key_path}" || ! -f "${cert_path}" ]]; then
        echo "Assetstore or Shibboleth credentials are missing. Mount the backup disk before starting services." >&2
        exit 1
    fi
    mounted_uuid="$(findmnt -n -T "${assetstore_path}" -o UUID 2>/dev/null || true)"
    if [[ "${mounted_uuid}" != "${assetstore_uuid}" ]]; then
        echo "Refusing to start: assetstore UUID ${mounted_uuid:-<none>} does not match expected UUID ${assetstore_uuid}." >&2
        exit 1
    fi
}

compose() {
    docker compose --env-file "${env_file}" -f "${compose_file}" "$@"
}

compose_migration() {
    docker compose --env-file "${env_file}" -f "${compose_file}" -f "${migration_compose_file}" "$@"
}

case "${1:-}" in
    init)
        umask 077
        if [[ ! -e "${env_file}" ]]; then
            cp "${script_dir}/.env.example" "${env_file}"
        fi
        ensure_env() {
            local key="$1"
            local value="$2"
            if ! grep -q "^${key}=" "${env_file}"; then
                printf '%s=%s\n' "${key}" "${value}" >>"${env_file}"
            fi
        }
        ensure_env DSPACE_ASSETSTORE_PATH /media/tomasz/61a05882-c126-4df8-bb14-228582bd35cd/dspace/assetstore
        ensure_env DSPACE_ASSETSTORE_UUID 61a05882-c126-4df8-bb14-228582bd35cd
        ensure_env HANDLE_PREFIX 11321
        ensure_env HANDLE_CANONICAL_PREFIX https://hdl.handle.net/
        ensure_env B_CENTRE_TEST_HANDLE 11321/1003
        ensure_env B_CENTRE_OAI_IDENTIFIER_PREFIX clarin-pl.eu
        ensure_env B_CENTRE_SAML_ENTITY_ID http://www.clarin-pl.eu/shibboleth
        ensure_env B_CENTRE_PRIVACY_URL https://clarin-pl.eu/privacy-policy
        ensure_env B_CENTRE_REGISTRY_URL https://centres.clarin.eu/centre/25
        ensure_env B_CENTRE_SIS_URL 'https://standards.clarin.eu/sis/views/view-centre.xq?id=CLARIN-PL1'
        ensure_env B_CENTRE_FCS_URL '"https://kontext.clarin-pl.eu/api/v2/fcs/2.0/endpoint/sru?operation=explain&version=2.0"'
        ensure_env B_CENTRE_VLO_URL https://vlo.clarin.eu/data/clarin/results/cmdi/CLARIN_PL_digital_repository/
        ensure_env MAIL_SERVER_DISABLED true
        ensure_env MAIL_SERVER clarinpl.nazwa.pl
        ensure_env MAIL_SERVER_PORT 587
        ensure_env MAIL_SERVER_USERNAME dspace@clarin-pl.eu
        ensure_env MAIL_SERVER_PASSWORD ''
        ensure_env MAIL_FROM_ADDRESS dspace@clarin-pl.eu
        ensure_env MAIL_ADMIN admin@clarin-pl.eu
        ensure_env FEEDBACK_RECIPIENT dspace@clarin-pl.eu
        ensure_env REGISTRATION_NOTIFY dspace@clarin-pl.eu
        ensure_env AUTHENTICATION_METHODS org.dspace.authenticate.PasswordAuthentication,org.dspace.authenticate.clarin.ClarinShibAuthentication
        ensure_env SHIBBOLETH_LOGIN_URL /shibboleth/Shibboleth.sso/Login
        ensure_env SHIBBOLETH_SECURE false
        ensure_env SHIBBOLETH_SERVER_NAME localhost:4000
        ensure_env SHIBBOLETH_ENTITY_ID http://www.clarin-pl.eu/shibboleth
        ensure_env SHIBBOLETH_DISCOVERY_URL https://discovery.clarin.eu
        ensure_env SHIBBOLETH_HANDLER_SSL false
        ensure_env SHIBBOLETH_COOKIE_PROPS '"; path=/; HttpOnly; SameSite=Lax"'
        ensure_env SHIBBOLETH_SUPPORT_CONTACT dspace@clarin-pl.eu
        ensure_env SHIBBOLETH_NETID_HEADERS eppn,subject-id,pairwise-id,persistent-id
        ensure_env SHIBBOLETH_EMAIL_HEADER mail
        ensure_env SHIBBOLETH_FIRSTNAME_HEADER givenName
        ensure_env SHIBBOLETH_LASTNAME_HEADER sn
        ensure_env SHIBBOLETH_AUTOREGISTER true
        ensure_env SHIBBOLETH_KEY_PATH /media/tomasz/61a05882-c126-4df8-bb14-228582bd35cd/Backup_2026/Backup/dspace/etc/shibboleth/sp-key-2025.pem
        ensure_env SHIBBOLETH_CERT_PATH /media/tomasz/61a05882-c126-4df8-bb14-228582bd35cd/Backup_2026/Backup/dspace/etc/shibboleth/sp-cert-2025.pem
        ensure_env LEGACY_DB_PASSWORD __LEGACY_DB_PASSWORD__
        ensure_env LEGACY_DSPACE_DUMP '"/media/tomasz/61a05882-c126-4df8-bb14-228582bd35cd/Backup_2026/Backup/dspace/backup_db 17_2_2026/dspace"'
        ensure_env LEGACY_UTILITIES_DUMP '"/media/tomasz/61a05882-c126-4df8-bb14-228582bd35cd/Backup_2026/Backup/dspace/backup_db 17_2_2026/dspace_utilities"'
        sed -i \
            -e "s|__POSTGRES_PASSWORD__|$(openssl rand -hex 32)|" \
            -e "s|__JWT_LOGIN_SECRET__|$(openssl rand -base64 24)|" \
            -e "s|__JWT_SHORT_LIVED_SECRET__|$(openssl rand -base64 24)|" \
            -e "s|__CLARIN_TOKEN_ENCRYPTION_SECRET__|$(openssl rand -base64 32)|" \
            -e "s|__ADMIN_PASSWORD__|$(openssl rand -hex 16)|" \
            -e "s|__LEGACY_DB_PASSWORD__|$(openssl rand -hex 32)|" \
            "${env_file}"
        chmod 600 "${env_file}"
        echo "Initialized or updated ${env_file} with mode 600. Existing values were preserved."
        ;;
    config)
        require_env
        verify_external_storage
        compose config --quiet
        echo "Compose configuration is valid."
        ;;
    build)
        require_env
        compose build
        ;;
    up)
        require_env
        verify_external_storage
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
    post-reboot-check)
        require_env
        "${script_dir}/post-reboot-check.sh" "${2:-auto}"
        ;;
    create-admin)
        require_env
        # shellcheck disable=SC1090
        source "${env_file}"
        compose exec dspace /dspace/bin/dspace create-administrator \
            -e "${ADMIN_EMAIL}" -f "${ADMIN_FIRST_NAME}" -l "${ADMIN_LAST_NAME}" \
            -p "${ADMIN_PASSWORD}" -c en
        ;;
    workflow-setup)
        require_env
        "${script_dir}/workflow/setup.sh"
        ;;
    db-status)
        require_env
        compose exec dspace /dspace/bin/dspace database status
        ;;
    b-centre-audit)
        require_env
        "${script_dir}/b-centre-audit.sh" --env-file "${env_file}" "${@:2}"
        ;;
    migration-preflight)
        require_env
        "${script_dir}/migration/preflight.sh" "${env_file}"
        ;;
    migration-prepare)
        require_env
        verify_external_storage
        "${script_dir}/migration/preflight.sh" "${env_file}" static-only
        # The full preflight queries the freshly initialized DSpace schema, so
        # start only the migration dependencies before checking target counts.
        compose_migration up -d --build --wait dspacedb dspacesolr dspace legacydb
        "${script_dir}/migration/preflight.sh" "${env_file}"
        # shellcheck disable=SC1090
        source "${env_file}"
        admin_count="$(compose exec -T dspacedb psql -U dspace -d dspace \
            -v admin_email="${ADMIN_EMAIL}" -Atc \
            "select count(*) from eperson where lower(email)=lower(:'admin_email');")"
        if [[ "${admin_count}" == "0" ]]; then
            compose exec -T dspace /dspace/bin/dspace create-administrator \
                -e "${ADMIN_EMAIL}" -f "${ADMIN_FIRST_NAME}" -l "${ADMIN_LAST_NAME}" \
                -p "${ADMIN_PASSWORD}" -c en
            echo "Created the migration administrator ${ADMIN_EMAIL}."
        elif [[ "${admin_count}" == "1" ]]; then
            echo "Migration administrator ${ADMIN_EMAIL} already exists."
        else
            echo "Refusing migration: unexpected administrator count ${admin_count}." >&2
            exit 1
        fi
        mkdir -p "${script_dir}/migration/backups"
        backup_file="${script_dir}/migration/backups/pre-migration-$(date +%Y%m%d-%H%M%S).sql"
        compose exec -T dspacedb pg_dump -U dspace -d dspace >"${backup_file}"
        chmod 600 "${backup_file}"
        echo "Target database backup: ${backup_file}"
        compose_migration build migrate
        compose_migration exec -T dspace /dspace/bin/dspace database migrate force
        echo "Migration services are ready. Mail remains disabled."
        ;;
    migration-run)
        require_env
        "${script_dir}/migration/preflight.sh" "${env_file}"
        compose_migration run --rm migrate
        ;;
    migration-resume)
        require_env
        compose_migration run --rm migrate python repo_import.py --resume=true --assetstore=/legacy-assetstore
        ;;
    migration-status)
        require_env
        compose_migration ps
        compose_migration exec -T legacydb psql -U postgres -d clarin-dspace -Atc \
            "select 'legacy_items=' || count(*) from item
             union all select 'legacy_published_items=' || count(*) from collection2item
             union all select 'legacy_workspace_items=' || count(*) from workspaceitem
             union all select 'legacy_orphan_items=' || count(*) from item i where not exists (select 1 from collection2item c where c.item_id=i.item_id) and not exists (select 1 from workspaceitem w where w.item_id=i.item_id) and not exists (select 1 from workflowitem f where f.item_id=i.item_id)
             union all select 'legacy_bitstreams=' || count(*) from bitstream
             union all select 'legacy_active_bitstreams=' || count(*) from bitstream where not deleted
             union all select 'legacy_deleted_bitstreams=' || count(*) from bitstream where deleted;"
        compose_migration exec -T dspacedb psql -U dspace -d dspace -Atc \
            "select 'target_items=' || count(*) from item
             union all select 'target_published_items=' || count(*) from collection2item
             union all select 'target_workspace_items=' || count(*) from workspaceitem
             union all select 'target_bitstreams=' || count(*) from bitstream
             union all select 'target_communities=' || count(*) from community
             union all select 'target_collections=' || count(*) from collection
             union all select 'target_epersons=' || count(*) from eperson;"
        ;;
    migration-license-mappings)
        require_env
        compose_migration build migrate
        compose_migration run --rm --no-deps migrate \
            python migrate_license_mappings.py --apply
        ;;
    migration-finalize)
        require_env
        legacy_active="$(compose_migration exec -T legacydb psql -U postgres -d clarin-dspace -Atc \
            "select count(*) from bitstream where not deleted;")"
        legacy_items="$(compose_migration exec -T legacydb psql -U postgres -d clarin-dspace -Atc \
            "select count(*) from item i where exists (select 1 from collection2item c where c.item_id=i.item_id) or exists (select 1 from workspaceitem w where w.item_id=i.item_id) or exists (select 1 from workflowitem f where f.item_id=i.item_id);")"
        target_bitstreams="$(compose_migration exec -T dspacedb psql -U dspace -d dspace -Atc \
            "select count(*) from bitstream;")"
        target_items="$(compose_migration exec -T dspacedb psql -U dspace -d dspace -Atc \
            "select count(*) from item;")"
        if [[ "${target_bitstreams}" != "${legacy_active}" || "${target_items}" != "${legacy_items}" ]]; then
            echo "Refusing finalization: target counts are incomplete (items ${target_items}/${legacy_items}, bitstreams ${target_bitstreams}/${legacy_active})." >&2
            exit 1
        fi
        # The upstream REST importer creates license definitions but does not
        # attach them to bitstreams when no historical user allowances exist.
        # Resolve changed numeric license IDs by unique names and bitstreams by
        # their stable assetstore internal_id before rebuilding indexes.
        compose_migration build migrate
        compose_migration run --rm --no-deps migrate \
            python migrate_license_mappings.py --apply
        compose_migration exec -T \
            -e clarin__P__item__D__files__D__metadata__P__deferred=false \
            dspace /dspace/bin/dspace dsrun org.dspace.app.itemupdate.ItemFilesMetadataRepair \
            -e "$(grep '^ADMIN_EMAIL=' "${env_file}" | cut -d= -f2-)" -f
        compose_migration exec -T dspace /dspace/bin/dspace index-discovery -b
        compose_migration exec -T dspace /dspace/bin/dspace oai import -c
        compose up -d --force-recreate --wait dspace
        echo "Discovery and OAI rebuilt; normal event consumers restored. Mail configuration was not changed."
        ;;
    migration-fixity)
        require_env
        legacy_active="$(compose_migration exec -T legacydb psql -U postgres -d clarin-dspace -Atc \
            "select count(*) from bitstream where not deleted;")"
        target_bitstreams="$(compose exec -T dspacedb psql -U dspace -d dspace -Atc \
            "select count(*) from bitstream where not deleted;")"
        if [[ "${target_bitstreams}" != "${legacy_active}" ]]; then
            echo "Refusing fixity audit: target bitstream count is incomplete (${target_bitstreams}/${legacy_active})." >&2
            exit 1
        fi
        echo "Running a full checksum pass over ${target_bitstreams} in-place bitstreams. This can take many hours."
        compose exec -T dspacedb psql -U dspace -d dspace -v ON_ERROR_STOP=1 -c \
            "update most_recent_checksum
                set last_process_start_date = timestamp '1970-01-01 00:00:00',
                    last_process_end_date = timestamp '1970-01-01 00:00:00'
              where to_be_processed;"
        compose exec -T dspace /dspace/bin/dspace checker -l
        compose exec -T dspacedb psql -U dspace -d dspace -c \
            "select result, count(*) from most_recent_checksum group by result order by result;"
        failures="$(compose exec -T dspacedb psql -U dspace -d dspace -Atc \
            "select count(*) from most_recent_checksum where to_be_processed and result is distinct from 'CHECKSUM_MATCH';")"
        audited="$(compose exec -T dspacedb psql -U dspace -d dspace -Atc \
            "select count(*) from most_recent_checksum
              where to_be_processed
                and result = 'CHECKSUM_MATCH'
                and last_process_start_date > timestamp '1970-01-02 00:00:00';")"
        if [[ "${failures}" != "0" || "${audited}" != "${target_bitstreams}" ]]; then
            echo "Fixity audit failed or is incomplete (matches ${audited}/${target_bitstreams}, failures ${failures})." >&2
            exit 1
        fi
        echo "Fixity audit passed for all ${audited} active bitstreams."
        ;;
    migration-logs)
        require_env
        compose_migration logs -f --tail=200 "${2:-migrate}"
        ;;
    *)
        usage
        exit 1
        ;;
esac
