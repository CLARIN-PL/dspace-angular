# CLARIN-PL DSpace 5 to 7 migration

This profile follows [`ufal/dspace-migrate`](https://github.com/ufal/dspace-migrate)
pinned to commit `01128d6c01b7e4f0bbe4ce867c9d9813f6feb8ee`.

## Selected source

Use the 17 February 2026 dumps from `Backup_2026/Backup/dspace/backup_db
17_2_2026`. Do not use `dspace/backup/dspace-backup-31_3_2017.sql`: it is an
obsolete snapshot and is rejected by the preflight check.

The selected source contains 2 communities, 10 collections, 1,044 item rows,
74,500 bitstream rows, 1,591 e-persons and 833 handles. Of those bitstreams,
33,301 are active and 41,199 are marked deleted. One item row is orphaned (it
belongs to no collection, workspace or workflow) and is intentionally not
materialized. Every source handle uses prefix `11321`.

The assetstore stays at its existing host path and is bind-mounted at
`/dspace/assetstore`. The CLARIN import endpoint creates database records using
the old `internal_id`, size and checksum. It does not upload or duplicate the
file content. Opening and hashing tens of thousands of files on the external
disk is deliberately deferred to one complete, auditable fixity pass.

## Run

Keep the external disk mounted for the entire import and for subsequent service
operation. From this directory run:

```bash
./manage.sh init
./manage.sh migration-preflight
./manage.sh migration-prepare
./manage.sh migration-run
./manage.sh migration-status
./manage.sh migration-finalize
./manage.sh migration-fixity
```

If the importer is interrupted, keep the same target and migration volumes and
use `./manage.sh migration-resume`. Do not run a fresh import against a partially
populated target. `migration-prepare` creates a mode-600 PostgreSQL backup before
changing the target.

The migration profile temporarily removes the Discovery consumer from the
default event dispatcher. Otherwise DSpace reindexes the owning Item after each
of more than 33,000 bitstream requests. It also defers the aggregate
`local.has.files`, `local.files.count` and `local.files.size` calculation, which
would otherwise rescan a growing bundle after every attachment.
The pinned migrator image applies a repository-owned patch that imports
independent bundles with six workers and uses a migration-only backend path to
write each bundle relationship without materializing the complete bundle. The
active DSpace 7 `bitstream_order` is made unique and contiguous per bundle;
the exact DSpace 5 value, including historical gaps and duplicates, is retained
in `bitstream_order_legacy` for audit.
`migration-finalize` first refuses to run unless the expected item and
active-bitstream counts match, repairs those aggregate fields once, then
rebuilds Discovery and OAI from scratch and recreates the backend with its
normal event consumers. During import, per-file validation is deferred because
random access and hashing on the 637 GB external assetstore would dominate the
database import. `migration-fixity` then initializes the checksum registry
set-wise and runs DSpace's checksum checker once over every active bitstream.
Results are committed in batches of 100 to keep the Hibernate context bounded.
The command fails unless all 33,301 records were processed during the audit and
report `CHECKSUM_MATCH`. Production go-live is blocked until that command passes.

## Expected source exceptions

The following exclusions are properties of the selected source and must be
accounted for explicitly instead of being treated as silent data loss:

- 41,199 bitstreams marked deleted are not materialized; all 33,301 active
  bitstreams and all 26,472 relationships to active bitstreams are migrated.
- Item `646` has no collection, workspace, workflow or Handle relationship and
  is not materialized. The target therefore contains 1,043 items: 754
  published and 289 workspace items.
- 440 legacy `registrationdata` rows are expired/pending tokens which the
  DSpace 7 API rejects. All 1,591 e-persons and 102 `user_registration` rows
  are migrated independently.
- Seven resource policies point to four deleted Item/Bundle targets or three
  skipped bitstreams. The remaining 31,756 policies are migrated and the item
  and bitstream embargo checks must pass.
- Seven unbound Community/Collection Handle rows are dropped and DSpace 7 adds
  its Site Handle. This changes the raw Handle count from 833 to 827 while
  retaining all 814 item, 10 collection and 2 community Handle rows.

Mail must remain disabled until all import and validation work is complete.
After finalization, configure/rebuild optional authority indexes where their
external providers are available and test a sample of public, authenticated,
restricted and withdrawn records before enabling writes.

## Reusable configuration audit

| Area | Decision |
| --- | --- |
| Assetstore | Reuse in place through a bind mount; never copy it into Git or a Docker volume. |
| Handle | Reuse prefix `11321` and canonical `https://hdl.handle.net/`; migrate all handle records. The backup contains no Handle server private key/configuration, so prefix administration cannot be activated from this backup alone. |
| Shibboleth | Reuse `eppn,persistent-id`, `mail`, `givenName`, `sn` and automatic registration. Remove UFAL/Czech role mappings. Password auth remains enabled for the migration administrator. A production Shibboleth SP still requires its external metadata, certificate and private key. |
| Email | Reuse host `clarinpl.nazwa.pl`, port 587, account/from/help addresses. Do not copy the old password; provide it only in ignored `.env`. Keep `MAIL_SERVER_DISABLED=true` during migration. |
| OAI | Reuse repository identity `clarin-pl.eu`; expose it through the new single-origin `/server/oai` endpoint and rebuild the index. |
| Licenses | Migrate the utilities license tables and map the historical plWordNet URL prefix to the current `https://clarin-pl.eu/license/` section. Verify every custom definition after import. |
| Submission forms and vocabularies | Review and port semantically, not by copying DSpace 5 XML over DSpace 7 defaults. Metadata and license registries are migrated from the databases. |
| Solr, logs, temp, upload | Do not reuse. Rebuild indexes and start with clean runtime directories. |
| GeoLiteCity.dat and GA `.p12` | Do not reuse: both integrations are obsolete. Configure current GeoIP/analytics separately if needed. |
| Czech/UFAL settings | Do not reuse featured-service URLs, UFAL groups, Czech IdP discovery defaults, Matomo tokens or test DOI credentials present in the fork defaults. |

## Production gates

- Obtain the registered Handle server bundle/private key from the current
  operator or rotate it with the Handle provider.
- Obtain or create the CLARIN-PL Shibboleth SP key/certificate and signed
  federation metadata configuration; the application backup does not contain
  them.
- Confirm SMTP credentials out of band, test through a mail sink, then set
  `MAIL_SERVER_DISABLED=false`.
- Run database/assetstore consistency checks, repository diff, checksum audit
  and representative authorization/download tests.
- Verify that every bundle has a contiguous active `bitstream_order`, that the
  source-order distribution in `bitstream_order_legacy` matches the source,
  and that no primary bitstream points outside its bundle.
- Keep the source dumps, the pre-migration target dump and assetstore snapshot
  together as the rollback set.
