# Isolated SSR verification

Run from the repository root. This environment uses a separate Compose project,
copied PostgreSQL/Solr volumes, disabled outgoing mail and a separate assetstore
that was initially empty.
Only the gateway is published, on `127.0.0.1:4400`. App containers use an
internal network. Do not start the regular production Compose file for testing.

Use `http://127.0.0.1:4400/dspace/` in the browser. The gateway redirects
`localhost` to that canonical origin and forwards the public port 4400 in
`X-Forwarded-Port` and the host in `X-Forwarded-Host`. Without those headers,
some authentication HAL links lose the port. Mixing localhost and 127.0.0.1
also fails the backend's origin check. Keep CORS and CSRF protection enabled.
Local password login was confirmed working by the user after this fix on
2026-10-27; no user password or production setting was changed.

The external test volumes `clarin-ssr-test-pg-20261027` and
`clarin-ssr-test-solr-20261027` must already exist. They were copied from the
stopped local volumes, without modifying those source volumes. This manifest
does not clone or import production data automatically. The wrapper explicitly
sets `--project-name` because the existing local env file overrides Compose's
top-level project name.

Build and start:

```sh
docker build --network none -f Dockerfile.ssr-test -t clarin-pl/dspace-angular:ssr-candidate-20261027 .
bash docker/ssr-test/manage.sh up -d
curl -fsS http://127.0.0.1:4400/app/live
curl -fsS http://127.0.0.1:4400/app/health
```

The local-only build reuses installed dependencies from
`clarin-pl/dspace-angular:anchor-navigation-check`; its yarn.lock matched this
checkout (SHA-256 `074dff0b9c5804363d0ace81bf6b5a0c6da3b8d8b3e9ae57f0a14fab20654bb0`).
Recheck that match if dependencies change. Both browser and SSR must be built
with `NODE_ENV=production`; otherwise the translation filenames do not match
the hashes embedded in the bundles. Server source maps remain private to the
test image. Use `Dockerfile.dist` for the eventual production image.

Checks:

```sh
# With dependencies installed and the project Node selected:
nvm use
yarn test:ssr
# Host recovery script (requires Bash, timeout, flock and awk):
node --test tests/ops/watchdog.test.cjs
# Mixed traffic on the fixed local port only:
python3 docker/ssr-test/check.py --seconds 60 --workers 4
# Longer stability run, followed by a separate peak test:
python3 docker/ssr-test/check.py --seconds 7200 --workers 4
python3 docker/ssr-test/check.py --seconds 60 --workers 8
```

The traffic check reports 429/503 separately and tolerates them during a peak;
it does not prove that normal traffic has acceptable availability. Check that
sequential real SSR pages return 200 with the expected content before using it.
Compare memory, restart count, errors and latency before/after the stability
run. The configured request rate is a test value, not a measurement of twice
the actual production peak.

Only two imported PDF thumbnails were restored as verified fixtures (10,487
bytes total). New files uploaded during local submission tests are stored in
this test volume. The original assetstore was not copied as a whole.

Limitations: the missing imported originals prevent validation of their downloads. Public
federation callbacks, authenticated editorial workflows and production OAI/
Handle integration need their own checks before rollout. Generic renderer
failure tests do not establish the source of the production RxJS error.

Stop only this project when finished:

```sh
bash docker/ssr-test/manage.sh stop
```

# Recovery template

`../production/frontend-watchdog.sh` and its service/timer are staged templates;
they are not installed or enabled on production. The script requires the
dedicated `/app/live` healthcheck, checks liveness again, and targets exactly one
Compose frontend. It caps attempts at three per 30 minutes with 90 seconds
between attempts. A failed backend readiness check alone does not trigger it.
Messages go to stderr/the system journal; external alert delivery still needs
to be connected to the operator's monitoring.

The timer expects the script installed as executable
`/usr/local/sbin/clarin-dspace-frontend-watchdog`. Installation and activation
belong to the later production rollout, after acceptance tests. No Docker
socket is mounted into an application container.
