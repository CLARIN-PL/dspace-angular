#!/usr/bin/env bash
set -Eeuo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
env_file="${script_dir}/.env"
compose_file="${script_dir}/compose.yml"
report_file=""
skip_compose=false
request_timeout=30
origin=""
repository_url=""
rest_url=""
oai_url=""
test_handle=""
passes=0
failures=0
warnings=0
manuals=0
request_number=0

usage() {
    cat <<'EOF'
Usage: ./b-centre-audit.sh [options]

  --env-file PATH          Environment file (default: ./.env)
  --origin URL             Public origin, e.g. https://clarin-pl.eu
  --repository-url URL     Repository UI URL (default: PUBLIC_URL)
  --rest-url URL           REST URL (default: REST_PUBLIC_URL)
  --oai-url URL            OAI base URL (default: OAI_PUBLIC_URL)
  --handle PREFIX/SUFFIX   Stable public item used by OAI/PID checks
  --report PATH            Also save the report to PATH
  --skip-compose           Check only public interfaces
  --timeout SECONDS        Per-request timeout (default: 30)
  -h, --help               Show help

The audit is read-only. Exit 1 means a mandatory check failed. Warnings and
manual checks do not change the exit status.
EOF
}

while (($#)); do
    case "$1" in
        --env-file) env_file="${2:?Missing --env-file value}"; shift 2 ;;
        --origin) origin="${2:?Missing --origin value}"; shift 2 ;;
        --repository-url) repository_url="${2:?Missing --repository-url value}"; shift 2 ;;
        --rest-url) rest_url="${2:?Missing --rest-url value}"; shift 2 ;;
        --oai-url) oai_url="${2:?Missing --oai-url value}"; shift 2 ;;
        --handle) test_handle="${2:?Missing --handle value}"; shift 2 ;;
        --report) report_file="${2:?Missing --report value}"; shift 2 ;;
        --skip-compose) skip_compose=true; shift ;;
        --timeout) request_timeout="${2:?Missing --timeout value}"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown option: $1" >&2; exit 2 ;;
    esac
done

[[ "${request_timeout}" =~ ^[1-9][0-9]*$ ]] || { echo "Invalid timeout" >&2; exit 2; }
[[ -f "${env_file}" ]] || { echo "Missing environment file: ${env_file}" >&2; exit 2; }

env_value() {
    local value
    value="$(sed -n "s/^$1=//p" "${env_file}" | tail -n 1)"
    value="${value#\"}"
    value="${value%\"}"
    printf '%s' "${value:-${2:-}}"
}

repository_url="${repository_url:-$(env_value PUBLIC_URL)}"
rest_url="${rest_url:-$(env_value REST_PUBLIC_URL)}"
oai_url="${oai_url:-$(env_value OAI_PUBLIC_URL)}"
test_handle="${test_handle:-$(env_value B_CENTRE_TEST_HANDLE 11321/1003)}"
origin="${origin:-$(printf '%s' "${repository_url}" | sed -E 's#^(https?://[^/]+).*$#\1#')}"
repository_url="${repository_url%/}"
rest_url="${rest_url%/}"
oai_url="${oai_url%/}"
origin="${origin%/}"
host="${origin#*://}"
host="${host%%:*}"

[[ "${origin}" =~ ^https?://[^/]+$ ]] || { echo "Invalid public origin: ${origin}" >&2; exit 2; }
[[ "${test_handle}" =~ ^[0-9.]+/[A-Za-z0-9._:-]+$ ]] || { echo "Invalid Handle: ${test_handle}" >&2; exit 2; }

oai_prefix="$(env_value B_CENTRE_OAI_IDENTIFIER_PREFIX clarin-pl.eu)"
saml_entity="$(env_value B_CENTRE_SAML_ENTITY_ID http://www.clarin-pl.eu/shibboleth)"
privacy_url="$(env_value B_CENTRE_PRIVACY_URL "${origin}/privacy-policy")"
registry_url="$(env_value B_CENTRE_REGISTRY_URL https://centres.clarin.eu/centre/25)"
sis_url="$(env_value B_CENTRE_SIS_URL 'https://standards.clarin.eu/sis/views/view-centre.xq?id=CLARIN-PL1')"
fcs_url="$(env_value B_CENTRE_FCS_URL 'https://kontext.clarin-pl.eu/api/v2/fcs/2.0/endpoint/sru?operation=explain&version=2.0')"
vlo_url="$(env_value B_CENTRE_VLO_URL 'https://vlo.clarin.eu/data/clarin/results/cmdi/CLARIN_PL_digital_repository/')"

if [[ -n "${report_file}" ]]; then
    mkdir -p "$(dirname -- "${report_file}")"
    : >"${report_file}"
fi

log() { printf '%s\n' "$*"; [[ -z "${report_file}" ]] || printf '%s\n' "$*" >>"${report_file}"; }
pass() { passes=$((passes + 1)); log "PASS   [$1] $2"; }
fail() { failures=$((failures + 1)); log "FAIL   [$1] $2"; }
warn() { warnings=$((warnings + 1)); log "WARN   [$1] $2"; }
manual() { manuals=$((manuals + 1)); log "MANUAL [$1] $2"; }
contains() { grep -Eiq -- "$2" "$1"; }

temp_dir="$(mktemp -d)"
trap 'rm -rf -- "${temp_dir}"' EXIT
FETCH_BODY=""
FETCH_CODE="000"
FETCH_TYPE=""
FETCH_EFFECTIVE=""

fetch() {
    local url="$1" accept="${2:-*/*}" metrics
    local -a values=()
    request_number=$((request_number + 1))
    FETCH_BODY="${temp_dir}/response-${request_number}"
    if ! metrics="$(curl -sS -L --compressed --max-time "${request_timeout}" \
        --max-filesize 5242880 -H "Accept: ${accept}" -o "${FETCH_BODY}" \
        -w $'%{http_code}\n%{content_type}\n%{url_effective}' "${url}")"; then
        FETCH_CODE=000; FETCH_TYPE=""; FETCH_EFFECTIVE="${url}"; return 1
    fi
    mapfile -t values <<<"${metrics}"
    FETCH_CODE="${values[0]:-000}"
    FETCH_TYPE="${values[1]:-}"
    FETCH_EFFECTIVE="${values[2]:-${url}}"
    [[ "${FETCH_CODE}" =~ ^2[0-9][0-9]$ ]]
}

fetch_oai_record() {
    local prefix="$1" metrics
    local -a values=()
    request_number=$((request_number + 1))
    FETCH_BODY="${temp_dir}/response-${request_number}"
    if ! metrics="$(curl -sS -L --compressed --max-time "${request_timeout}" \
        --max-filesize 5242880 --get --data-urlencode verb=GetRecord \
        --data-urlencode "identifier=oai:${oai_prefix}:${test_handle}" \
        --data-urlencode "metadataPrefix=${prefix}" -o "${FETCH_BODY}" \
        -w $'%{http_code}\n%{content_type}\n%{url_effective}' "${oai_url}/request")"; then
        FETCH_CODE=000; FETCH_TYPE=""; FETCH_EFFECTIVE="${oai_url}/request"; return 1
    fi
    mapfile -t values <<<"${metrics}"
    FETCH_CODE="${values[0]:-000}"
    FETCH_TYPE="${values[1]:-}"
    FETCH_EFFECTIVE="${values[2]:-${oai_url}/request}"
    [[ "${FETCH_CODE}" =~ ^2[0-9][0-9]$ ]]
}

log "CLARIN B-Centre 8.0.0 production audit"
log "UTC: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
log "Repository: ${repository_url}"
log "OAI-PMH: ${oai_url}/request"
log "Test Handle: ${test_handle}"

log ""
log "== Local stack =="
if [[ "${skip_compose}" == true ]]; then
    warn LOCAL "Compose checks skipped."
elif ! command -v docker >/dev/null 2>&1; then
    fail LOCAL "Docker is unavailable."
else
    compose=(docker compose --env-file "${env_file}" -f "${compose_file}")
    if "${compose[@]}" config --quiet >/dev/null 2>&1; then pass LOCAL "Compose configuration is valid."; else fail LOCAL "Compose configuration is invalid."; fi
    for service in dspacedb dspacesolr dspace dspace-shibboleth dspace-angular gateway; do
        container_id="$("${compose[@]}" ps -q "${service}" 2>/dev/null || true)"
        state=""
        [[ -z "${container_id}" ]] || state="$(docker inspect -f '{{.State.Status}} {{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "${container_id}" 2>/dev/null || true)"
        if [[ "${state}" == "running healthy" ]]; then pass LOCAL "${service} is healthy."; else fail LOCAL "${service} state is '${state:-missing}'."; fi
    done
    counts="$("${compose[@]}" exec -T dspacedb psql -U dspace -d dspace -Atc \
        'select count(*) from item where in_archive and not withdrawn; select count(*) from collection;' 2>/dev/null || true)"
    published="$(sed -n '1p' <<<"${counts}")"
    collections="$(sed -n '2p' <<<"${counts}")"
    if [[ "${published}" =~ ^[1-9][0-9]*$ && "${collections}" =~ ^[1-9][0-9]*$ ]]; then
        pass LOCAL "Database has ${published} published items and ${collections} collections."
    else
        fail LOCAL "Published items and collections could not be confirmed."
    fi

    workflow_gaps="$("${compose[@]}" exec -T dspacedb psql -U dspace -d dspace -Atc \
        "select count(*) from collection c
         where not exists (select 1 from cwf_collectionrole r where r.collection_id=c.uuid and r.role_id='reviewer')
            or not exists (select 1 from cwf_collectionrole r where r.collection_id=c.uuid and r.role_id='editor')
            or not exists (select 1 from cwf_collectionrole r where r.collection_id=c.uuid and r.role_id='finaleditor');" \
        2>/dev/null || true)"
    if [[ "${workflow_gaps}" == 0 ]]; then
        pass workflow "Every collection has reviewer, editor and finaleditor roles."
    else
        fail workflow "${workflow_gaps:-unknown} collection(s) lack a mandatory editorial role."
    fi

    mail_disabled="$("${compose[@]}" exec -T dspace /dspace/bin/dspace dsprop -p mail.server.disabled 2>/dev/null | tail -n 1 || true)"
    mail_tls="$("${compose[@]}" exec -T dspace /dspace/bin/dspace dsprop -p mail.extraproperties 2>/dev/null || true)"
    if [[ "${mail_disabled}" == false ]]; then
        pass mail "SMTP delivery is enabled."
    else
        fail mail "SMTP delivery is disabled or its state could not be read."
    fi
    if grep -Fq 'mail.smtp.starttls.required=true' <<<"${mail_tls}" && grep -Fq 'mail.smtp.ssl.checkserveridentity=true' <<<"${mail_tls}"; then
        pass mail "SMTP requires STARTTLS and verifies the server identity."
    else
        fail mail "SMTP does not require STARTTLS with server identity verification."
    fi
fi

log ""
log "== 1-4. Certification, policies and HTTPS =="
if fetch "${registry_url}" text/html; then
    registry_body="${FETCH_BODY}"
    if contains "${registry_body}" 'Certified' && contains "${registry_body}" 'CoreTrustSeal'; then pass 2.f "Certified Centre Registry entry and CTS are present."; else fail 2.f "Registry certification data are incomplete."; fi
    if contains "${registry_body}" 'Planned, Handle via EPIC'; then warn 2.f "Registry still says PID is planned via EPIC."; fi
else fail 2.f "Centre Registry unavailable (HTTP ${FETCH_CODE})."; fi

if fetch "${repository_url}/static/about" text/html && contains "${FETCH_BODY}" 'CLARIN-PL'; then
    pass 2.a-3.a "Public policy page is reachable."
else
    fail 2.a-3.a "Public policy page unavailable or invalid at /static/about (HTTP ${FETCH_CODE})."
fi

# Angular SSR can serve a cached locale independently of the client's language
# cookie. Inspect the canonical English source rather than treating a Polish SSR
# response as missing English policy content.
about_source="${script_dir}/../../src/static-files/about.html"
if [[ -f "${about_source}" ]]; then
    if contains "${about_source}" 'Mission Statement' && contains "${about_source}" 'Continuity of access' && contains "${about_source}" 'Intellectual Property|IPR' && contains "${about_source}" '2028-2033'; then
        pass 2.a-3.a "Canonical English policies cover mission, funding continuity and IPR."
    else
        fail 2.a-3.a "Canonical English policies lack a required statement."
    fi
else
    warn 2.a-3.a "Canonical English policy source is unavailable; inspect /static/about in English manually."
fi

if fetch "${repository_url}/page/about" text/html; then
    pass 2.f "Legacy /page/about URL used by CLARIN registries still resolves."
else
    fail 2.f "Registered legacy /page/about URL is broken; add a redirect to /static/about."
fi

if fetch "${repository_url}/static/deposit" text/html && contains "${FETCH_BODY}" 'CLARIN-PL'; then
    pass 2.e "Public deposit guide is reachable."
else
    fail 2.e "Deposit page unavailable or invalid at /static/deposit (HTTP ${FETCH_CODE})."
fi
deposit_source="${script_dir}/../../src/static-files/deposit.html"
if [[ -f "${deposit_source}" ]] && contains "${deposit_source}" 'standards\.clarin\.eu/.+CLARIN-PL1'; then
    pass 12/R8 "Canonical English deposit guide links to centre-specific SIS formats."
else
    warn 12/R8 "Canonical English deposit guide does not link to CLARIN-PL1 SIS formats."
fi

if fetch "${privacy_url}" text/html; then pass 3.b "Privacy policy is reachable."; else fail 3.b "Privacy policy unavailable (HTTP ${FETCH_CODE})."; fi

if [[ "${origin}" != https://* ]]; then
    fail 4 "Public origin is not HTTPS."
elif fetch "${origin}/" text/html; then
    pass 4 "HTTPS is trusted by the system CA store."
    if command -v openssl >/dev/null 2>&1 && command -v timeout >/dev/null 2>&1; then
        pem="$(timeout "${request_timeout}" openssl s_client -verify_return_error -connect "${host}:443" -servername "${host}" </dev/null 2>/dev/null || true)"
        if openssl x509 -checkend 2592000 -noout <<<"${pem}" >/dev/null 2>&1; then pass 4 "TLS certificate is valid for at least 30 days."; else fail 4 "TLS chain failed or certificate expires within 30 days."; fi
    else warn 4 "OpenSSL expiry check skipped."; fi
else fail 4 "HTTPS validation failed (HTTP ${FETCH_CODE})."; fi

log ""
log "== 5. Federated identity =="
if fetch "${origin}/shibboleth/Shibboleth.sso/Metadata" application/samlmetadata+xml; then
    saml_body="${FETCH_BODY}"
    if grep -Fq "entityID=\"${saml_entity}\"" "${saml_body}" && ! contains "${saml_body}" 'Location="http://(localhost|127\.0\.0\.1)'; then pass 5 "Runtime SAML metadata has the registered entity and public endpoints."; else fail 5 "Runtime SAML metadata has a wrong entity or local endpoint."; fi
else fail 5 "Runtime SAML metadata unavailable (HTTP ${FETCH_CODE})."; fi

request_number=$((request_number + 1))
edugain_body="${temp_dir}/response-${request_number}"
edugain_code="$(curl -sS -L --max-time "${request_timeout}" --get --data-urlencode action=show_entity --data-urlencode "e_id=${saml_entity}" -o "${edugain_body}" -w '%{http_code}' https://technical.edugain.org/api 2>/dev/null || printf 000)"
if [[ "${edugain_code}" =~ ^2[0-9][0-9]$ ]] && contains "${edugain_body}" dataprotection-code-of-conduct && contains "${edugain_body}" PrivacyStatementURL; then pass 3.b/5 "eduGAIN declares DP-CoC and PrivacyStatementURL."; else fail 3.b/5 "eduGAIN DP-CoC/privacy declaration not confirmed."; fi
if fetch "${repository_url}/login" text/html; then pass 5 "Login page is reachable."; else fail 5 "Login page unavailable (HTTP ${FETCH_CODE})."; fi
manual 5 "Test login through the CLARIN IdP."
manual 5 "Test login through an IdP outside Poland and record released attributes."
manual 5/6.d "Open a restricted item and verify licence/authorization enforcement."

log ""
log "== 6. OAI-PMH and CMDI =="
if fetch "${oai_url}/request?verb=Identify" text/xml; then
    identify="${FETCH_BODY}"
    if contains "${identify}" '<repositoryName>CLARIN-PL Repository</repositoryName>' && contains "${identify}" "<repositoryIdentifier>${oai_prefix}</repositoryIdentifier>"; then pass 6.a "OAI Identify has the expected identity."; else fail 6.a "OAI Identify has a wrong identity."; fi
    if contains "${identify}" 'lindat\.cz|ufal\.mff|Prague|Name Surname|\$\{[^}]+\}'; then fail 6.a "OAI Identify contains Czech/template residue."; else pass 6.a "OAI Identify has no known template residue."; fi
    if command -v xmllint >/dev/null 2>&1; then if xmllint --noout "${identify}" >/dev/null 2>&1; then pass 6.a "OAI Identify is well-formed XML."; else fail 6.a "OAI Identify is malformed XML."; fi; else warn 6.a "xmllint unavailable."; fi
else fail 6.a "OAI Identify unavailable (HTTP ${FETCH_CODE})."; fi

if fetch "${oai_url}/request?verb=ListMetadataFormats" text/xml; then
    if contains "${FETCH_BODY}" '<metadataPrefix>cmdi</metadataPrefix>' && contains "${FETCH_BODY}" '<metadataPrefix>oai_dc</metadataPrefix>'; then pass 6.a "OAI offers CMDI and Dublin Core."; else fail 6.a "OAI lacks CMDI or Dublin Core."; fi
else fail 6.a "OAI ListMetadataFormats unavailable (HTTP ${FETCH_CODE})."; fi

if fetch_oai_record cmdi; then
    cmdi="${FETCH_BODY}"
    if contains "${cmdi}" '<error '; then fail 6.b-6.c "CMDI GetRecord returned an OAI error.";
    elif contains "${cmdi}" '<cmd:MdSelfLink>[^<]*(https?://|hdl:)' && contains "${cmdi}" '<cmd:ResourceProxy' && contains "${cmdi}" '<cmd:ResourceRef'; then pass 6.b-6.c "CMDI has a URL/PID MdSelfLink and ResourceProxy.";
    else fail 6.b-6.c "CMDI lacks a URL/PID MdSelfLink or ResourceProxy."; fi
    if contains "${cmdi}" 'localhost|127\.0\.0\.1'; then fail 6.c "CMDI exposes a local URL."; else pass 6.c "CMDI exposes no local URL."; fi
else fail 6.b-6.c "CMDI GetRecord unavailable (HTTP ${FETCH_CODE})."; fi

if fetch_oai_record oai_dc; then
    if contains "${FETCH_BODY}" '<error ' || ! contains "${FETCH_BODY}" '<oai_dc:dc'; then fail 6.a "Dublin Core test record is missing."; else pass 6.a "Dublin Core test record is available."; fi
else fail 6.a "Dublin Core GetRecord unavailable (HTTP ${FETCH_CODE})."; fi
manual 6.a "Run the official CLARIN OAI validator and archive its result."
manual 6.b "Run the CMDI Curation Module and archive its result."
manual 6.a/6.d "Confirm current records and downloads in VLO."

log ""
log "== 7. Persistent identifiers =="
if fetch "https://hdl.handle.net/api/handles/${test_handle}" application/json && contains "${FETCH_BODY}" '"responseCode"[[:space:]]*:[[:space:]]*1'; then pass 7 "Global Handle Registry resolves ${test_handle}."; else fail 7 "Global Handle Registry does not resolve ${test_handle}."; fi
if fetch "https://hdl.handle.net/${test_handle}" text/html && [[ "${FETCH_TYPE}" == text/html* ]]; then pass 7 "Handle negotiates HTML."; else fail 7 "Handle HTML negotiation failed (HTTP ${FETCH_CODE}, ${FETCH_TYPE:-no type})."; fi
if fetch "https://hdl.handle.net/${test_handle}" application/x-cmdi+xml && contains "${FETCH_BODY}" '<cmd:CMD|xmlns:cmd="http://www\.clarin\.eu/cmd/'; then pass 7 "Handle negotiates CMDI."; else fail 7 "Handle CMDI negotiation failed (HTTP ${FETCH_CODE})."; fi

log ""
log "== Recommendations 8-12 =="
if fetch "${fcs_url}" text/xml && contains "${FETCH_BODY}" '<sruResponse:explainResponse' && contains "${FETCH_BODY}" '<sruResponse:version>2\.0'; then pass 8 "FCS returns SRU 2.0 Explain."; else warn 8 "FCS Explain check failed."; fi
if fetch "${sis_url}" text/html; then
    sis="${FETCH_BODY}"
    if contains "${sis}" 'CLARIN-PL Language Technology Centre' && contains "${sis}" 'Curation:' && contains "${sis}" recommended; then pass 12 "SIS has curated format recommendations."; else warn 12 "SIS curation/recommendations not confirmed."; fi
    if contains "${sis}" '>WAV<|>FLAC<|>MP3<|>MP4<|>WebM<'; then pass 12 "SIS includes audio/video formats."; else warn 12 "SIS has no obvious audio/video format; curator should confirm scope."; fi
else warn 12 "SIS entry unavailable."; fi

openapi=false
for path in /api/openapi.json /v3/api-docs /api/openapi; do
    if fetch "${rest_url}${path}" application/json && contains "${FETCH_BODY}" '"openapi"[[:space:]]*:'; then pass 11 "OpenAPI JSON is available at ${rest_url}${path}."; openapi=true; break; fi
done
[[ "${openapi}" == true ]] || warn 11 "No OpenAPI JSON found at known REST paths."
if fetch "${vlo_url}" text/html; then pass 6.a "Configured VLO URL is reachable."; else warn 6.a "Configured VLO URL is unavailable."; fi
manual 9 "Document whether Shibboleth Attribute Checker is enabled."
manual 10 "Confirm a login in LINDAT Attribute Aggregator or document non-use."
manual 4 "Run SSL Labs after final proxy cutover."
manual 2.e/3.a/6.d "Browse open/restricted records; verify licences, files, thumbnails and links."
manual workflow "Complete a deposit through reviewer, editor and finaleditor."

log ""
log "Summary: PASS=${passes} FAIL=${failures} WARN=${warnings} MANUAL=${manuals}"
[[ -z "${report_file}" ]] || log "Report: ${report_file}"
if ((failures > 0)); then log "Result: NOT READY for B-Centre production acceptance."; exit 1; fi
log "Result: automated checks passed; sign off every MANUAL item before cutover."
