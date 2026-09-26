# CLARIN-PL DSpace deployment plan for 10.45.126.11

Status: **public production active — Handle and manual B-centre acceptance pending**
Initial audit date: 2026-09-23
Storage change date: 2026-09-25
Target host: `10.45.126.11` (`dspace`)
Target branches: `clarin-pl-main` in `dspace-angular` and `clarin-dspace`

The approved storage expansion, Docker data-root migration, assetstore
synchronization and DSpace 5 to 7 migration were completed on 2026-09-25. The
external proxy cutover is complete, the production gateway is healthy on
`10.45.126.11:80`, and the maintenance container is stopped. SMTP is enabled
after a successful authenticated STARTTLS test and DSpace test message. Global
Handle service and the external/manual acceptance tests remain open.

## Completed application migration and validation (2026-09-25)

- Migrated all 1,043 materializable source items: 528 archived, 226 withdrawn
  and 289 workspace items. The one source orphan documented in `MIGRATION.md`
  was skipped. Two separately reconstructed historical deposits were then
  added, resulting in 530 archived, 226 withdrawn and 289 workspace items.
- Migrated all 33,301 active source bitstreams in place. A full DSpace fixity
  pass read 485,258,620,522 bytes and returned `CHECKSUM_MATCH` for every active
  bitstream.
- Migrated 31,756 valid resource policies and 25,296 normalized active licence
  mappings. Twenty-seven duplicate source licence pairs were intentionally
  normalized; 137 mappings to deleted/non-migrated bitstreams were excluded.
- Rebuilt Discovery and OAI. The final OAI rebuild processed the 754 migrated
  collection records (including withdrawn tombstones) and the two reconstructed
  records.
- Restored `11321/1008` (Korpus Czterech Wieszczów) and `11321/1010` (Polish
  Drama Corpus). Both UI pages return 200, CMDI and BibTeX OAI records exist,
  and files downloaded through REST exactly match the documented SHA-256 sums.
  Record 1010 retains an explicit provenance warning that its historical
  licence still requires depositor confirmation.
- Transferred the local hierarchy to production by stable Handle. `CLARIN-PL`
  now contains `Open Resources`, `Project Collections` and `Restricted
  Collections`; `Main community/Main collection` was removed after dependency
  checks. The target has 4 communities and 12 collections.
- Enabled the mandatory reviewer, metadata-editor and final-approver roles on
  all 12 collections. The idempotent second run confirmed 36 role assignments.
- Verified local administrator password authentication. Shibboleth Status and
  Metadata return 200 and the protected DSpace endpoint redirects to the CLARIN
  Discovery Service with the registered entity ID and an HTTPS callback without
  an internal port. A real institutional round trip remains a manual cutover
  test.
- `./manage.sh post-reboot-check production` completed with zero failures and
  zero warnings. All six runtime services are healthy, have zero restarts and
  have not been OOM-killed. The migration-only PostgreSQL 11 container is
  stopped but retained for rollback/audit.
- Installed the current Ubuntu security update for `libpcap0.8` and refreshed
  the unused LXD snap. No regular APT or snap updates remain, no service restart
  is required, and `/var/run/reboot-required` is absent. Two Ubuntu Pro ESM Apps
  updates remain unavailable until the host is attached to Ubuntu Pro.

Database rollback points (mode `0600`) are stored under
`docker/production/migration/backups/` on the target:

| Backup | SHA-256 |
| --- | --- |
| `pre-migration-20260925-074312.sql` | `7a2d8d2935eb754003234636173167bcb0a6ad96c148fe680334fd468bd775fe` |
| `post-import-pre-finalize-20260925-080949.sql` | `bdf4bd2d27ec79b6f94cb396aa187046a449724df3a23cc7e38eb8319d05b65e` |
| `pre-reconstruction-20260925-102716.sql` | `b3f43e747891215e2d2fcf5a805636ecb8f31f9c39272ffa5014711df695435c` |
| `pre-community-reorganization-production-20260925T132908Z.dump` | `ed7d67af4ebff63bb80634c48fc22b8cc26b70c061e62f35b8ec3f998bcf077c` |

The current automated B-centre report is
`/var/tmp/clarin-b-centre-post-reorganization-20260925.txt`. Its summary is
`PASS=32 FAIL=3 WARN=4 MANUAL=11`; all three failures concern global Handle
resolution/content negotiation. The report is not a production acceptance
certificate until Handle works and the manual checks are signed off.

## Completed storage preparation

| Area | Completed state |
| --- | --- |
| System disk | `/dev/xvda3`, `ubuntu-vg/ubuntu-lv` and ext4 expanded to 98 GiB; approximately 75 GiB free after the change |
| Data disk | `/dev/xvdb`, `data/dspace` and ext4 expanded from 800 GiB to 2000 GiB; approximately 1.2 TiB free |
| Runtime disk | `/dev/xvdc1` initialized as LVM; `clarin-runtime/docker` provides a 250 GiB ext4 filesystem mounted at `/var/lib/docker` |
| Docker protection | `RequiresMountsFor=/var/lib/docker`; default `json-file` rotation set to `50m` and 5 files |
| Maintenance page | Recreated with log rotation and verified from localhost and a remote client with HTTP 200 |

## Completed pre-reboot preparation (2026-09-25)

- Stored an off-host copy of the host recovery bundle at
  `deployment-artifacts/20260925-pre-reboot/clarin-pre-reboot-20260925T061820Z.tar.gz`.
  Its SHA-256 is
  `8d53d34da9456c4ab59b9a97651bb890038e9351fc3bd1d9a115aeddb1a5abf5`.
- Staged the exact current working trees, including uncommitted changes, in
  `/opt/clarin-pl-dspace/{dspace-angular,clarin-dspace}`. Commit, branch, status,
  patch and content-verification artifacts are retained in
  `/opt/clarin-pl-dspace/source-metadata` and the local deployment artifacts.
- Created the private production environment at
  `/opt/clarin-pl-dspace/dspace-angular/docker/production/.env` (mode `0600`) and
  a protected copy at `/home/tnaskret/dspace/production-secrets/dspace.env`.
  `docker compose config` and the external-storage UUID guard pass.
- Staged and checksum-verified the 17 February 2026 DSpace and utilities SQL
  dumps under `/home/tnaskret/dspace/migration-input`.
- Staged the Shibboleth SP key/certificate under
  `/home/tnaskret/dspace/production-secrets/shibboleth`; the private key is mode
  `0600` and owned by root.
- Built `clarin-pl/dspace-angular:local`, `dspace-backend:local`,
  `dspace-postgres:local`, `dspace-solr:local`, `dspace-shibboleth:local` and
  `dspace-migrate:local`. Pulled `nginx:1.30.4-alpine` and
  `postgres:11.22-bullseye` by immutable registry digest.
- Installed the read-only reboot check as
  `/opt/clarin-pl-dspace/dspace-angular/docker/production/post-reboot-check.sh`.
  Its pre-reboot baseline completed with `failures=0 warnings=0` in maintenance
  mode.
- Left only the maintenance page running on port 80. The production database,
  Solr, backend, Shibboleth, Angular and gateway remain stopped.

## Post-reboot validation (2026-09-25)

The host restarted at 07:21 UTC and the complete maintenance-mode check passed:
`SUMMARY failures=0 warnings=0 mode=maintenance`. All expected filesystems and
LVM volumes returned on their recorded UUIDs, Docker waited for and uses the
dedicated `/var/lib/docker` mount, the maintenance container returned
automatically, and no systemd unit failed. The assetstore recount remains
75,326 files and 682,845,516,337 bytes. The current source manifests and all
prepared production images remain readable.

After refreshing APT metadata, the available `libpcap0.8` security update and
the routine LXD snap refresh were installed. The normal Ubuntu, Docker and snap
channels now report no available updates and no reboot requirement. The running
kernel is the newest installed kernel (`5.15.0-194-generic`). Ubuntu Pro still
reports two ESM Apps updates; applying them requires attaching a subscription.

Recovery material on the target host:

- storage metadata: `/root/clarin-storage-change-20260925T060314Z`;
- previous Docker data root: `/var/lib/docker.before-xvdc-20260925T060314Z`.

Keep both until the production stack has passed acceptance and a reboot test.

## Approval gate

The disk-capacity and assetstore-synchronization parts of this gate are complete.
Before application deployment, confirm the independent database/assetstore
backup and retain the hypervisor snapshot according to the local infrastructure
procedure.

Recommended target layout:

| Device | Target size | Purpose |
| --- | ---: | --- |
| `/dev/xvda` | 100 GiB | Operating system, source repositories, image build cache |
| `/dev/xvdb` | 2 TiB (1.5 TiB minimum) | Assetstore and retained legacy data |
| `/dev/xvdc` | 200 GiB (150–250 GiB) | Docker, PostgreSQL, Solr, DSpace logs and Handle configuration |
| Independent backup storage | at least 1.5–2 TiB | Database and assetstore backups outside the production VM |

Minimum acceptable layout when a third disk is unavailable:

- expand `/dev/xvda` to at least 100 GiB;
- expand `/dev/xvdb` to at least 1.5 TiB, preferably 2 TiB;
- leave Docker on the expanded system filesystem;
- keep the assetstore on the data filesystem;
- store backups outside this VM.

## Audited state before deployment

The Xen guest has 12 vCPUs and 31 GiB RAM. This is sufficient for the planned
DSpace stack.

Storage before expansion:

| Area | Current state | Assessment |
| --- | --- | --- |
| `/dev/xvda` | 30 GiB; root LV uses all available PV extents; about 8.4 GiB available | Too small for production image builds |
| `/dev/xvdb` | 800 GiB; `data/dspace` uses all available PV extents | Cannot grow without hypervisor expansion |
| `/home/tnaskret/dspace` | ext4; about 658 GiB used and 89.7 GiB available | Insufficient production headroom |
| `/var/lib/docker` | On the system filesystem; about 4.1 GiB used | Must not be allowed to exhaust `/` |

At the time of the initial audit, the maintenance container exposed port 80 and
there was no service on port 443 on this host. Docker used the `json-file` log
driver without rotation; the maintenance container log alone was approximately
2.23 GB. Rotation was enabled during the completed storage preparation.

The data filesystem also contains approximately 33 GB of legacy Tomcat data:

- approximately 29 GB of legacy Solr Statistics indexes;
- approximately 3.5 GB of historical Tomcat/access logs.

Do not delete these files before deciding how historical usage statistics and
audit logs will be retained or migrated.

## Assetstore comparison

Local authoritative source:

`/media/tomasz/61a05882-c126-4df8-bb14-228582bd35cd1/dspace/assetstore`

Remote partial copy:

`/home/tnaskret/dspace/dspace-store/assetstore`

| Measurement | Local source | Remote copy |
| --- | ---: | ---: |
| Files | 75,326 | 74,277 |
| File content bytes | 682,845,516,337 | 670,845,991,486 |

Comparison result before synchronization:

- the remote assetstore is a strict subset of the local source;
- all 74,277 remote paths exist locally;
- every common path has the same file size;
- there are no remote-only files;
- there are no common paths with different sizes;
- 1,049 files are missing remotely;
- missing content totals 11,999,524,851 bytes (about 11.2 GiB).

Content verification completed during the audit:

- full SHA-256 comparison of 200 deterministically distributed common files;
- block fingerprints (start, middle and end) of the 25 largest common files.

All sampled fingerprints matched. This strongly supports that the remote data
is a correct older copy, but it is not a full cryptographic verification of all
670 GB. Full DSpace fixity verification remains mandatory after synchronization
and database deployment.

Synchronization completed on 2026-09-25 without `--delete` and without
overwriting any existing remote file. The 1,049 missing files
(11,999,524,851 bytes) were copied. The final source and target manifests both
contain exactly 75,326 files and 682,845,516,337 content bytes, with zero
missing, remote-only or size-mismatched paths. SHA-256 was also verified for
every copied file; the aggregate checksum-list digest on both sides is
`c0d6431074ad725b09536444569d92b460fef5e9c7e49fc9f7db7a58b4404b41`.
This does not replace the mandatory DSpace fixity pass after database migration.

## Proposed persistent layout

When the recommended three-disk layout is available:

```text
/srv/clarin-pl/
├── assetstore/
├── legacy/
│   ├── solr-statistics/
│   └── logs/
├── deployment/
└── staging-backups/

/var/lib/docker/
├── PostgreSQL data
├── Solr data
├── DSpace logs
└── Handle Server configuration
```

`staging-backups` is only temporary working space and is not an independent
backup. Production backups must leave the VM.

## Execution sequence after storage expansion

### 1. Pre-change validation

1. Confirm `root@10.45.126.11` access.
2. Confirm the hypervisor snapshot and an external assetstore/database backup.
3. Record `lsblk`, `pvs`, `vgs`, `lvs`, `findmnt` and `df -hT` output.
4. Confirm that maintenance mode remains available during preparation.
5. Confirm the public reverse-proxy owner and change window.

### 2. Storage work

1. Detect the new virtual disk sizes.
2. Expand the existing PV/LV/filesystem or initialize the new runtime disk.
3. Mount persistent storage by UUID in `/etc/fstab`.
4. Use `/srv/clarin-pl` as the canonical production data path.
5. Preserve the old `/home/tnaskret/dspace` path until all references have been
   migrated and verified.
6. Verify ownership, permissions, inode availability and free-space thresholds.
7. Do not remove legacy Tomcat/Solr/log data at this stage.

The exact LVM/filesystem commands must be generated from a fresh read-only audit
after the hypervisor change. Do not reuse commands based only on the old sizes.

### 3. Docker runtime protection

1. Place Docker on the dedicated runtime disk when `/dev/xvdc` is available.
2. Configure log rotation (`max-size` and `max-file`) before starting the stack.
3. Keep PostgreSQL and Solr off the assetstore directory.
4. Ensure PostgreSQL, Solr and internal backend ports are not publicly exposed.
5. Back up database volumes separately from the assetstore.

### 4. Assetstore synchronization

1. Keep the local authoritative assetstore unchanged.
2. Perform an initial dry run that lists only the 1,049 missing paths.
3. Synchronize missing files without deleting or overwriting remote files.
4. Repeat the path-and-size manifest comparison.
5. Require exactly 75,326 files and 682,845,516,337 content bytes.
6. Do not use `--delete` during synchronization.
7. After the migrated database is running, execute the full DSpace checksum
   checker against every active bitstream.
8. Keep the local source until the remote fixity report and an independent
   backup have both been accepted.

### 5. Application deployment

1. Deploy both repositories from `clarin-pl-main`.
2. Generate a private production `.env`; never commit it.
3. Restore the prepared PostgreSQL database.
4. Bind the synchronized assetstore without copying it into a Docker volume.
5. Start PostgreSQL and Solr first, then the backend, Shibboleth, Angular SSR and
   the gateway.
6. Run database migration status, Discovery reindex and OAI rebuild checks.
7. Run `./manage.sh workflow-setup` and verify all collections have `reviewer`,
   `editor` and `finaleditor` roles.
8. Verify local password login and CLARIN federated login.
9. Verify mail, Handle registration, OAI-PMH, thumbnails, file downloads and
   private collection access.
10. Perform an end-to-end deposit and confirm that it cannot bypass editorial
    workflow.
11. Run the automated CLARIN B-Centre acceptance audit and save its report:

    ```bash
    ./manage.sh b-centre-audit \
      --report "/var/tmp/clarin-b-centre-$(date -u +%Y%m%dT%H%M%SZ).txt"
    ```

    Resolve every `FAIL` and complete the manual sign-off described in
    `B-CENTRE-ACCEPTANCE.md` before cutover.

### 6. Reverse proxy and cutover

Public DNS for `clarin-pl.eu` currently resolves to `156.17.1.83`, not directly
to `10.45.126.11`. HTTPS is terminated outside the DSpace VM. Coordinate the
external proxy before cutover.

The external proxy must route these paths to the DSpace gateway while preserving
the host and HTTPS forwarding headers:

- `/dspace/`
- `/server/`
- `/oai/`
- `/shibboleth/`

If the proxy is on another host, bind the gateway only to the required private
interface and allow the gateway port only from the proxy address. PostgreSQL and
Solr must remain on the private Docker network.

### 7. Acceptance and rollback

Acceptance requires:

- all containers healthy;
- complete assetstore manifest and successful full fixity run;
- database backup restore test;
- correct Handles and OAI records;
- successful local and federated login;
- successful mail delivery test;
- successful deposit through all three workflow stages;
- verified private-resource authorization;
- no failures in the automated B-Centre audit and a completed manual B-Centre
  sign-off;
- external monitoring and disk-space alerts;
- documented rollback to the maintenance page and pre-deployment snapshot.

Do not delete the source assetstore, old database dumps, legacy Solr Statistics,
or the hypervisor snapshot during the initial production observation period.

## Current hand-off and remaining gates

For every subsequent reboot run:

```bash
cd /opt/clarin-pl-dspace/dspace-angular/docker/production
./manage.sh post-reboot-check production
```

The expected result is `SUMMARY failures=0 warnings=0 mode=production`.
Investigate any failure instead of bypassing the check.

The following items remain after production cutover:

1. Confirm the hypervisor snapshot and external backup with the infrastructure
   owner; neither can be verified from inside this guest.
2. Publish DNS `handle.clarin-pl.eu` at `156.17.1.83`, terminate HTTPS on TCP
   443 at the perimeter proxy and forward it to `http://10.45.126.11:8000`.
   Native Handle TCP/UDP 2641 and HTTP 8000 remain private. The Handle 9.3.2
   container is already enabled, healthy and configured to restart
   automatically.
3. Send the prepared HTTPS-only `sitebndl.zip` for existing prefix `11321` to
   the Handle.Net Registry administrator. The production keys and site serial
   3 match the bundle; after confirmation, verify global resolution of
   `11321/931` through both the HTML proxy and Handle API.
4. Complete the remaining external/manual tests: federated IdP round trip,
   restricted-item authorization, one end-to-end
   deposit through all three editorial stages, official OAI/CMDI validation and
   VLO visibility.
5. Publish the reconstructed 1008 and 1010 records through Handle after their
   metadata and the unresolved 1010 licence have been approved.
