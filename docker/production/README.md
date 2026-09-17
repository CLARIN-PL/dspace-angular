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

Open <http://localhost:4000>. The REST API is available on the same origin at
<http://localhost:4000/server>. PostgreSQL and Solr are only reachable on the
private Docker network.

The gateway resolves Docker service names dynamically and its healthcheck
requires both the Angular health endpoint and the REST API. Recreating the
backend or frontend therefore does not leave Nginx pinned to a stale container
address.

Create the initial administrator after the stack is healthy:

```bash
./manage.sh create-admin
```

The generated credentials are in `.env` (mode 600). Change the admin password
after the first login. Useful commands are `./manage.sh status`,
`./manage.sh logs`, `./manage.sh db-status`, and `./manage.sh down`.

## Preparing the real deployment

Keep `.env` outside version control and back it up securely. Set `PUBLIC_URL`,
`REST_SSL`, `REST_HOST` and `REST_PORT` to the public HTTPS endpoint. Keep the
gateway bound to loopback when a host-level TLS proxy is used. Configure SMTP,
the registered Handle prefix/server, authentication (OIDC or Shibboleth), and
external monitoring before accepting production traffic.

Back up both the PostgreSQL database and the assetstore bind mount. A database
dump without the matching assetstore is not a complete repository backup.

Never use `docker compose down --volumes` on a populated repository: it deletes
the database, Solr index, logs and Handle configuration volumes. The externally
mounted assetstore is not deleted by Compose, but it still needs an independent
backup and integrity monitoring.

## Migrating the CLARIN-PL DSpace 5 repository

The reproducible DSpace 5 to 7 procedure, source audit and exact commands are in
[`MIGRATION.md`](./MIGRATION.md). The importer registers files already present
in `DSPACE_ASSETSTORE_PATH`; it does not copy the 637 GB assetstore.
