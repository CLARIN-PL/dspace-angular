# CLARIN-PL local production stack

This Compose project builds both CLARIN-PL repositories from source and runs the
production Angular SSR bundle with the DSpace backend, PostgreSQL, Solr and an
Nginx single-origin gateway.

The repositories must remain siblings named `dspace-angular` and
`clarin-dspace`, and both should use the `clarin-pl-main` branch.

## Local startup

Requirements: Docker Engine with Compose v2, OpenSSL, at least 12 GB RAM and
roughly 20 GB free disk space for a clean build.

```bash
cd dspace-angular/docker/production
./manage.sh init
./manage.sh config
./manage.sh up
```

The assetstore and Shibboleth key/certificate live on the external disk with UUID
`61a05882-c126-4df8-bb14-228582bd35cd`. Mount that disk *before* starting
the stack, then set `DSPACE_ASSETSTORE_PATH`, `DSPACE_ASSETSTORE_UUID`,
`SHIBBOLETH_KEY_PATH` and `SHIBBOLETH_CERT_PATH` in the private `.env` to the
actual production paths and filesystem UUID. Desktop automount may choose a
suffix such as `...cd1` when another directory already occupies `...cd`; check
with `findmnt -T "$path"`. The startup check refuses a missing disk, a UUID
mismatch, or missing credentials, and Compose must not create missing host
paths for these binds. Avoid `docker compose up` directly when operating this
installation; use `./manage.sh up` so the disk preflight runs.

Open <http://localhost:4000/dspace/>. The REST API remains at
<http://localhost:4000/server>, OAI-PMH is exposed at
<http://localhost:4000/oai/request?verb=Identify>, and the Shibboleth handler
is at <http://localhost:4000/shibboleth/Shibboleth.sso/Metadata>. PostgreSQL
and Solr are only reachable on the private Docker network.

The gateway resolves Docker service names dynamically and its healthcheck
requires both the Angular health endpoint and the REST API. Recreating the
backend or frontend therefore does not leave Nginx pinned to a stale container
address.

## Password and CLARIN AAI login

The stack enables local password authentication and federated authentication at
the same time. The federated button sends the browser through the dedicated
Apache/mod_shib service to the maintained CLARIN Discovery Service. Only
mod_shib can add identity attributes to the protected DSpace endpoint; the
public Nginx gateway removes matching client-supplied headers.

The Shibboleth key and certificate remain outside Git. Their host paths are set
with `SHIBBOLETH_KEY_PATH` and `SHIBBOLETH_CERT_PATH`. Keep the key readable only
by its owner (`chmod 600`). The historical entity ID
`http://www.clarin-pl.eu/shibboleth` is preserved and must not be changed without
coordinating the change with the CLARIN federation. Detailed SP configuration is
in the sibling repository at `clarin-dspace/docker/production/shibboleth/`.

The local HTTP profile is suitable for checking metadata and the redirect to
`https://discovery.clarin.eu`; an institutional sign-in can complete only on a
public HTTPS URL whose metadata and callback endpoints are registered by the
federation. For production set at least:

```dotenv
PUBLIC_URL=https://clarin-pl.eu/dspace
REST_PUBLIC_URL=https://clarin-pl.eu/server
OAI_PUBLIC_URL=https://clarin-pl.eu/oai
REST_SSL=true
REST_HOST=clarin-pl.eu
REST_PORT=443
SHIBBOLETH_SECURE=true
SHIBBOLETH_SERVER_NAME=clarin-pl.eu:443
SHIBBOLETH_HANDLER_SSL=true
SHIBBOLETH_COOKIE_PROPS="; path=/; HttpOnly; secure; SameSite=None"
```

After changing these values, recreate `dspace`, `dspace-shibboleth` and `gateway`,
then publish and register the metadata returned by
`/shibboleth/Shibboleth.sso/Metadata`.

Create the initial administrator after the stack is healthy:

```bash
./manage.sh create-admin
./manage.sh workflow-setup
```

The generated credentials are in `.env` (mode 600). Change the admin password
after the first login. The idempotent `workflow-setup` command enables the
mandatory three-stage process for every collection: technical review,
metadata editing, and final approval. It creates shared CLARIN-PL teams for
these roles and adds the initial administrator as their first member. Manage
later staffing through the DSpace group administration screen; a submitter
cannot publish an item directly while all three collection roles are present.

Run `workflow-setup` again after adding a collection so that the same mandatory
roles are attached to it. Existing drafts remain in their owners' workspaces;
the workflow begins when a submitter completes a deposit. Useful commands are
`./manage.sh status`, `./manage.sh logs`, `./manage.sh db-status`,
`./manage.sh post-reboot-check`, and `./manage.sh down`. Run the reboot check as
root in `maintenance` mode immediately after the storage-change reboot, and in
`production` mode after the final stack has been enabled:

```bash
sudo ./manage.sh post-reboot-check maintenance
sudo ./manage.sh post-reboot-check production
```

The check is read-only. It verifies the expected filesystem UUIDs, free space,
Docker data root, enabled services, pinned images, staged-input checksums,
failed units, the appropriate local HTTP endpoint, and current-boot storage
errors. The host-specific root and Docker UUID defaults may be overridden with
`EXPECTED_ROOT_UUID` and `EXPECTED_DOCKER_UUID` when deploying to another host.

## Preparing the real deployment

Keep `.env` outside version control and back it up securely. Set `PUBLIC_URL`,
`REST_PUBLIC_URL`, `OAI_PUBLIC_URL`, `REST_SSL`, `REST_HOST` and `REST_PORT` to
the public HTTPS endpoints. Keep the gateway bound to loopback when a host-level
TLS proxy is used. The host-level proxy must forward `/dspace/`, `/server/`,
`/oai/` and `/shibboleth/` to the gateway, preserving the path and the
`Host: clarin-pl.eu` header and setting `X-Forwarded-Proto: https`. The
`/server/` path is still required for the REST API and federated login; do not
expose `/solr/`. The main website at `/` can remain served separately.

For an Apache HTTPS vhost on the same host as the Compose gateway, the relevant
path mappings are:

```apache
ProxyPreserveHost On
RequestHeader set X-Forwarded-Proto "https"
ProxyPass "/dspace/" "http://127.0.0.1:4000/dspace/"
ProxyPassReverse "/dspace/" "http://127.0.0.1:4000/dspace/"
ProxyPass "/server/" "http://127.0.0.1:4000/server/"
ProxyPassReverse "/server/" "http://127.0.0.1:4000/server/"
ProxyPass "/oai/" "http://127.0.0.1:4000/oai/"
ProxyPassReverse "/oai/" "http://127.0.0.1:4000/oai/"
ProxyPass "/shibboleth/" "http://127.0.0.1:4000/shibboleth/"
ProxyPassReverse "/shibboleth/" "http://127.0.0.1:4000/shibboleth/"
```

Also redirect the HTTP versions of these paths to HTTPS. The gateway redirects
bare `/dspace` and `/oai` to their trailing-slash forms and both
`/shibboleth` and `/shibboleth/` to the SP metadata endpoint. If Apache
is on another host, replace `127.0.0.1` with a private gateway address and
restrict that port to the proxy. Configure SMTP,
the registered Handle prefix/server, authentication (OIDC or Shibboleth), and
external monitoring before accepting production traffic.

Back up both the PostgreSQL database and the assetstore bind mount. A database
dump without the matching assetstore is not a complete repository backup.

Never use `docker compose down --volumes` on a populated repository: it deletes
the database, Solr index, logs and Handle configuration volumes. The externally
mounted assetstore is not deleted by Compose, but it still needs an independent
backup and integrity monitoring.

## CLARIN B-Centre acceptance

After deployment, run the read-only automated audit and retain its report with
the release record:

```bash
./manage.sh b-centre-audit \
  --report "/var/tmp/clarin-b-centre-$(date -u +%Y%m%dT%H%M%SZ).txt"
```

Every `FAIL` must be resolved and every `MANUAL` item signed off before
production acceptance. The complete procedure, interpretation of results and
recommended schedule are in [`B-CENTRE-ACCEPTANCE.md`](./B-CENTRE-ACCEPTANCE.md).

## Migrating the CLARIN-PL DSpace 5 repository

The reproducible DSpace 5 to 7 procedure, source audit and exact commands are in
[`MIGRATION.md`](./MIGRATION.md). The importer registers files already present
in `DSPACE_ASSETSTORE_PATH`; it does not copy the 637 GB assetstore.
