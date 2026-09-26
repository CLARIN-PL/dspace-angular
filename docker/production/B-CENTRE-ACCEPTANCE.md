# CLARIN B-Centre production acceptance

This is the repeatable, read-only production acceptance procedure based on the
CLARIN B-Centre Checklist 8.0.0. Run it on the production host after the public
proxy, OAI-PMH, Shibboleth and Handle service have been enabled.

The audit does not modify DSpace, PostgreSQL, Handle records, federation
metadata or external registries.

## Production configuration

Set the public URLs in `.env` before the first run:

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
```

Set `B_CENTRE_TEST_HANDLE` to a stable, representative public item. It must be
available from OAI-PMH in CMDI and Dublin Core. Do not use a temporary test
deposit. The remaining `B_CENTRE_*` defaults are documented in `.env.example`.

The host needs `curl`, `openssl` and Docker Compose. Install `xmllint` as well
to enable the additional XML well-formedness check.

## Complete audit on production

From `docker/production` run:

```bash
chmod +x b-centre-audit.sh
./manage.sh b-centre-audit \
  --report "/var/tmp/clarin-b-centre-$(date -u +%Y%m%dT%H%M%SZ).txt"
```

For an external monitoring host, without access to Docker:

```bash
./b-centre-audit.sh \
  --env-file .env \
  --skip-compose \
  --report "/var/tmp/clarin-b-centre-external-$(date -u +%Y%m%dT%H%M%SZ).txt"
```

Exit status `0` means that all automated mandatory checks passed. `WARN` is a
recommendation or a non-blocking inconsistency. `MANUAL` is an acceptance test
which cannot be safely automated. A release is not accepted while any `FAIL`
remains or a manual check is unsigned.

When Compose access is enabled, the audit also verifies that every collection
has all three mandatory editorial roles and that SMTP is enabled with required
STARTTLS and server-certificate identity checking. It never sends a message;
delivery remains a manual acceptance test.

The audit checks current policy pages under `/dspace/static/...` and the legacy
`/dspace/page/about` address published in CLARIN registries. Keep a redirect
from the legacy address until Centre Registry, SIS and re3data have all been
updated and their caches have expired.

## Manual sign-off

Record date, tester, identity and result for each item:

- login through the CLARIN IdP;
- login through an IdP from a country other than Poland;
- access to a restricted item and enforcement of its licence;
- a complete deposit through reviewer, editor and finaleditor, with no public
  access before final acceptance;
- official CLARIN OAI-PMH Validator result;
- CMDI Curation Module result and visibility of current records in VLO;
- browser access and downloads for representative open and restricted records;
- SSL Labs result for every public repository hostname;
- production mail delivery to a controlled mailbox;
- decision and status for Attribute Checker and Attribute Aggregator;
- validation of OpenAPI JSON if the optional document is published.

Store the generated report and completed sign-off with the release record.

## Schedule

- external audit every day from monitoring;
- complete audit after every deployment and every proxy, certificate, Handle,
  Shibboleth, OAI crosswalk or CMDI profile change;
- complete archived audit once per month;
- Centre Registry, SIS, re3data and certificate review once per quarter;
- renewal preparation at least nine months before the January 2029 expiry.
