#!/usr/bin/env bash
set -Eeuo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
production_dir="$(cd -- "${script_dir}/.." && pwd)"
env_file="${production_dir}/.env"

for command in curl jq; do
    if ! command -v "${command}" >/dev/null 2>&1; then
        echo "Missing required command: ${command}" >&2
        exit 1
    fi
done

if [[ ! -f "${env_file}" ]]; then
    echo "Missing ${env_file}. Run ./manage.sh init first." >&2
    exit 1
fi

# shellcheck disable=SC1090
source "${env_file}"

: "${ADMIN_EMAIL:?ADMIN_EMAIL is required in .env}"
: "${ADMIN_PASSWORD:?ADMIN_PASSWORD is required in .env}"

api_host="${HTTP_BIND:-127.0.0.1}"
if [[ "${api_host}" == "0.0.0.0" ]]; then
    api_host="127.0.0.1"
fi
base_url="http://${api_host}:${HTTP_PORT:-4000}/server"
work_dir="$(mktemp -d)"
cookie_file="${work_dir}/cookies"
header_file="${work_dir}/headers"
body_file="${work_dir}/body"
password_file="${work_dir}/admin-password"
security_header_file="${work_dir}/security-headers"
trap 'rm -rf -- "${work_dir}"' EXIT
chmod 700 "${work_dir}"
printf '%s' "${ADMIN_PASSWORD}" >"${password_file}"
touch "${security_header_file}"
chmod 600 "${password_file}" "${security_header_file}"

write_security_headers() {
    : >"${security_header_file}"
    if [[ -n "${authorization:-}" ]]; then
        printf 'Authorization: %s\n' "${authorization}" >>"${security_header_file}"
    fi
    if [[ -n "${xsrf_token:-}" ]]; then
        printf 'X-XSRF-TOKEN: %s\n' "${xsrf_token}" >>"${security_header_file}"
    fi
}

update_security_headers() {
    local value
    value="$(awk 'BEGIN { IGNORECASE=1 }
        /^DSPACE-XSRF-TOKEN:/ {
            sub(/^[^:]+:[[:space:]]*/, ""); sub(/\r$/, ""); print; exit
        }' "${header_file}")"
    if [[ -n "${value}" ]]; then
        xsrf_token="${value}"
    fi

    value="$(awk 'BEGIN { IGNORECASE=1 }
        /^Authorization:/ {
            sub(/^[^:]+:[[:space:]]*/, ""); sub(/\r$/, ""); print; exit
        }' "${header_file}")"
    if [[ -n "${value}" ]]; then
        authorization="${value}"
    fi
    write_security_headers
}

response_status=""
api_get() {
    local url="$1"
    curl --fail-with-body --silent --show-error \
        --dump-header "${header_file}" \
        --output "${body_file}" \
        --cookie "${cookie_file}" \
        --header "@${security_header_file}" \
        "${url}" || true
    response_status="$(awk 'NR == 1 { print $2 }' "${header_file}")"
    update_security_headers
}

api_post() {
    local url="$1"
    local content_type="$2"
    local payload="$3"
    curl --fail-with-body --silent --show-error \
        --dump-header "${header_file}" \
        --output "${body_file}" \
        --cookie "${cookie_file}" \
        --cookie-jar "${cookie_file}" \
        --request POST \
        --header "@${security_header_file}" \
        --header "Content-Type: ${content_type}" \
        --data-binary "${payload}" \
        "${url}" || true
    response_status="$(awk 'NR == 1 { print $2 }' "${header_file}")"
    update_security_headers
}

require_status() {
    local expected="$1"
    local operation="$2"
    if [[ "${response_status}" != "${expected}" ]]; then
        echo "${operation} failed: HTTP ${response_status:-unknown}, expected ${expected}." >&2
        jq '{status, error, message, path}' "${body_file}" 2>/dev/null || true
        exit 1
    fi
}

# Establish the server-side CSRF cookie, then authenticate without printing credentials or tokens.
authorization=""
xsrf_token=""
curl --silent --show-error \
    --dump-header "${header_file}" \
    --output "${body_file}" \
    --cookie-jar "${cookie_file}" \
    "${base_url}/api/authn/status"
update_security_headers

curl --silent --show-error \
    --dump-header "${header_file}" \
    --output "${body_file}" \
    --cookie "${cookie_file}" \
    --cookie-jar "${cookie_file}" \
    --request POST \
    --header "@${security_header_file}" \
    --header 'Content-Type: application/x-www-form-urlencoded' \
    --data-urlencode "user=${ADMIN_EMAIL}" \
    --data-urlencode "password@${password_file}" \
    "${base_url}/api/authn/login"
response_status="$(awk 'NR == 1 { print $2 }' "${header_file}")"
update_security_headers
require_status 200 "Administrator login"
rm -f -- "${password_file}"
unset ADMIN_PASSWORD
if [[ -z "${authorization}" ]]; then
    echo "Administrator login did not return an authorization token." >&2
    exit 1
fi

api_get "${base_url}/api/authn/status?projection=full"
require_status 200 "Administrator status lookup"
admin_id="$(jq -er 'select(.authenticated == true) | ._embedded.eperson.id' "${body_file}")"

declare -A shared_groups

ensure_shared_group() {
    local role="$1"
    local name="$2"
    local encoded_name group_id payload description
    encoded_name="$(printf '%s' "${name}" | jq -sRr @uri)"
    api_get "${base_url}/api/eperson/groups/search/byMetadata?query=${encoded_name}&size=100"
    require_status 200 "Search for group ${name}"
    group_id="$(jq -r --arg name "${name}" \
        'first((._embedded.groups // [])[] | select(.name == $name) | .id) // empty' \
        "${body_file}")"

    if [[ -z "${group_id}" ]]; then
        description="Shared CLARIN-PL team for the ${role} stage of repository submissions."
        payload="$(jq -cn --arg name "${name}" --arg description "${description}" \
            '{name:$name,metadata:{"dc.description":[{value:$description,language:null,authority:null,confidence:-1,place:0}]}}')"
        api_post "${base_url}/api/eperson/groups" 'application/json' "${payload}"
        require_status 201 "Create group ${name}"
        group_id="$(jq -er '.id' "${body_file}")"
        echo "Created shared group: ${name}"
    else
        echo "Using existing shared group: ${name}"
    fi

    api_get "${base_url}/api/eperson/groups/${group_id}/epersons?size=1000"
    require_status 200 "Read members of ${name}"
    if ! jq -e --arg id "${admin_id}" \
        '.. | objects | select(.id? == $id)' "${body_file}" >/dev/null; then
        api_post "${base_url}/api/eperson/groups/${group_id}/epersons" \
            'text/uri-list' "${base_url}/api/eperson/epersons/${admin_id}"
        require_status 204 "Add the initial administrator to ${name}"
    fi
    shared_groups["${role}"]="${group_id}"
}

ensure_workflow_subgroup() {
    local workflow_group_id="$1"
    local shared_group_id="$2"
    api_get "${base_url}/api/eperson/groups/${workflow_group_id}/subgroups?size=1000"
    require_status 200 "Read workflow subgroups"
    if ! jq -e --arg id "${shared_group_id}" \
        '.. | objects | select(.id? == $id)' "${body_file}" >/dev/null; then
        api_post "${base_url}/api/eperson/groups/${workflow_group_id}/subgroups" \
            'text/uri-list' "${base_url}/api/eperson/groups/${shared_group_id}"
        require_status 204 "Attach shared team to workflow role"
    fi
}

ensure_shared_group reviewer 'CLARIN-PL Technical Reviewers'
ensure_shared_group editor 'CLARIN-PL Metadata Editors'
ensure_shared_group finaleditor 'CLARIN-PL Final Approvers'

api_get "${base_url}/api/core/collections?size=1000"
require_status 200 "Collection listing"
mapfile -t collections < <(jq -r \
    '._embedded.collections[] | [.id, .name] | @tsv' "${body_file}" | sort -k2)
if [[ "${#collections[@]}" -eq 0 ]]; then
    echo "No collections found; refusing to configure workflow." >&2
    exit 1
fi

configured_roles=0
for entry in "${collections[@]}"; do
    collection_id="${entry%%$'\t'*}"
    collection_name="${entry#*$'\t'}"
    for role in reviewer editor finaleditor; do
        api_get "${base_url}/api/core/collections/${collection_id}/workflowGroups/${role}"
        if [[ "${response_status}" == 200 ]]; then
            workflow_group_id="$(jq -er '.id' "${body_file}")"
        elif [[ "${response_status}" == 204 ]]; then
            api_post "${base_url}/api/core/collections/${collection_id}/workflowGroups/${role}" \
                'application/json' '{"metadata":{}}'
            require_status 201 "Create ${role} role for ${collection_name}"
            workflow_group_id="$(jq -er '.id' "${body_file}")"
        else
            require_status 200 "Read ${role} role for ${collection_name}"
        fi
        ensure_workflow_subgroup "${workflow_group_id}" "${shared_groups[${role}]}"
        configured_roles=$((configured_roles + 1))
    done
    echo "Workflow enabled: ${collection_name}"
done

echo "Workflow setup complete: ${configured_roles} role assignments across ${#collections[@]} collections."
