# Reconstruction of post-backup items

These Simple Archive Format records restore two deposits missing from the
17 February 2026 DSpace 5 database backup. The `handle` files preserve their
previous persistent identifiers. Import into collection `11321/4` only after
checking that the handles are still absent and backing up the target database.

Bitstreams are intentionally not stored in Git:

| Item | Source on this workstation | SHA-256 |
| --- | --- | --- |
| 11321/1008 | `/home/tomasz/GP_HTML/Downloads/poems.zip` | `252358e3c8b41dd06942a5baf9d21a1c285c988ad66f9c52b2f1d855a86177c0` |
| 11321/1010 | `/home/tomasz/Projects/poldracor/tei/drama.zip` | `315ac8b8e39f5ebaef36e32d55a1a8e07a9d5478ab555dc929eb7053167ca696` |

The `poems.zip` archive contains 1,082 files and matches the old record's
filename and displayed size. `drama.zip` contains 50 TEI XML plays and matches
the old record's displayed 1.85 MiB size. Neither archive's SHA-256 was
published by the old DSpace; these are high-confidence, not cryptographic,
matches to the deposited versions.

The original page for 1008 survives in search indexing. The page for 1010 does
not; its title, authors, publisher, date, type and file size come from the old
collection listing, and its description is newly reconstructed from the
PolDraCor source repository. The old listing showed Creative Commons
attribution, while the source repository declares CC0. This discrepancy is
recorded in the item metadata and needs depositor confirmation; do not silently
present one license as the verified original DSpace license.

Sources:

- https://clarin-pl.eu/dspace/handle/11321/1008
- https://clarin-pl.eu/dspace/handle/11321/4
- https://github.com/dracor-org/poldracor
