#!/usr/bin/env python3
"""Migrate active CLARIN license-to-bitstream mappings after the REST import.

The upstream importer migrates license definitions, but only consumes
license_resource_mapping while rebuilding historical user allowances. The
CLARIN-PL source has no such allowances, so active resource mappings must be
copied explicitly. Source bitstream IDs are resolved through the stable,
unique assetstore ``internal_id``; licenses are resolved by unique names
because REST creation assigns new numeric IDs.
"""

import argparse
import os
import sys
from collections import Counter

import psycopg2
from psycopg2.extras import execute_values


def required(name: str) -> str:
    value = os.environ.get(name)
    if not value:
        raise RuntimeError(f"Required environment variable is missing: {name}")
    return value


def connect(host: str, database: str, user: str, password: str):
    return psycopg2.connect(
        host=host,
        port=5432,
        dbname=database,
        user=user,
        password=password,
        connect_timeout=10,
    )


def fetch_all(connection, query: str):
    with connection.cursor() as cursor:
        cursor.execute(query)
        return cursor.fetchall()


def unique_map(rows, key_index: int, label: str):
    counts = Counter(row[key_index] for row in rows)
    duplicates = sorted(key for key, count in counts.items() if count > 1)
    if duplicates:
        sample = ", ".join(str(value) for value in duplicates[:5])
        raise RuntimeError(f"Duplicate {label} values ({len(duplicates)}): {sample}")
    return {row[key_index]: row for row in rows}


def build_expected(source_dspace, source_utilities, target):
    source_licenses = fetch_all(
        source_utilities,
        """select license_id, name, confirmation, coalesce(required_info, '')
             from license_definition order by license_id""",
    )
    target_licenses = fetch_all(
        target,
        """select license_id, name, confirmation, coalesce(required_info, '')
             from license_definition order by license_id""",
    )
    target_license_by_name = unique_map(target_licenses, 1, "target license name")
    unique_map(source_licenses, 1, "source license name")

    if {row[1:] for row in source_licenses} != {row[1:] for row in target_licenses}:
        raise RuntimeError("Source and target license definitions differ")

    source_to_target_license = {
        source_id: target_license_by_name[name][0]
        for source_id, name, _confirmation, _required_info in source_licenses
    }

    source_bitstreams = fetch_all(
        source_dspace,
        """select bitstream_id, internal_id
             from bitstream where not deleted order by bitstream_id""",
    )
    target_bitstreams = fetch_all(
        target,
        "select uuid::text, internal_id from bitstream order by internal_id",
    )
    source_by_id = unique_map(source_bitstreams, 0, "active source bitstream ID")
    source_by_internal_id = unique_map(source_bitstreams, 1, "active source internal_id")
    target_by_internal_id = unique_map(target_bitstreams, 1, "target internal_id")

    source_ids = set(source_by_internal_id)
    target_ids = set(target_by_internal_id)
    if source_ids != target_ids:
        missing = sorted(source_ids - target_ids)
        extra = sorted(target_ids - source_ids)
        raise RuntimeError(
            "Active source and target bitstreams differ by internal_id "
            f"(missing={len(missing)}, extra={len(extra)})"
        )

    active_mappings = fetch_all(
        source_utilities,
        """select mapping_id, bitstream_id, license_id
             from license_resource_mapping where active order by mapping_id""",
    )
    expected_by_pair = {}
    skipped_non_active_bitstream = 0
    duplicate_active_pairs = 0
    for mapping_id, bitstream_id, source_license_id in active_mappings:
        source_bitstream = source_by_id.get(bitstream_id)
        if source_bitstream is None:
            skipped_non_active_bitstream += 1
            continue
        internal_id = source_bitstream[1]
        target_uuid = target_by_internal_id[internal_id][0]
        target_license_id = source_to_target_license.get(source_license_id)
        if target_license_id is None:
            raise RuntimeError(
                f"Mapping {mapping_id} references unknown source license {source_license_id}"
            )
        pair = (target_uuid, target_license_id)
        previous = expected_by_pair.get(pair)
        if previous is not None:
            duplicate_active_pairs += 1
        # The DSpace 5 source contains duplicate active rows for some pairs.
        # The DSpace 7 model has no inactive-history flag, so retain exactly
        # one row and use the newest (highest) source mapping identifier.
        if previous is None or mapping_id > previous[0]:
            expected_by_pair[pair] = (mapping_id, target_uuid, target_license_id)

    expected = sorted(expected_by_pair.values())
    return (
        expected,
        len(active_mappings),
        skipped_non_active_bitstream,
        duplicate_active_pairs,
    )


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--apply",
        action="store_true",
        help="insert the validated mappings; without this option only audit",
    )
    args = parser.parse_args()

    legacy_host = required("MIGRATION_LEGACY_DB_HOST")
    legacy_password = required("MIGRATION_LEGACY_DB_PASSWORD")
    target_host = required("MIGRATION_TARGET_DB_HOST")
    target_password = required("MIGRATION_TARGET_DB_PASSWORD")

    with connect(legacy_host, "clarin-dspace", "postgres", legacy_password) as source_dspace, \
            connect(legacy_host, "clarin-utilities", "postgres", legacy_password) as source_utilities, \
            connect(target_host, "dspace", "dspace", target_password) as target:
        expected, source_active, skipped, duplicates = build_expected(
            source_dspace, source_utilities, target
        )
        existing = fetch_all(
            target,
            """select mapping_id, bitstream_uuid::text, license_id
                 from license_resource_mapping order by mapping_id""",
        )

        print(f"source_active_license_mappings={source_active}")
        print(f"skipped_mappings_for_deleted_or_missing_bitstreams={skipped}")
        print(f"normalized_duplicate_active_mappings={duplicates}")
        print(f"expected_target_license_mappings={len(expected)}")
        print(f"existing_target_license_mappings={len(existing)}")

        expected_set = set(expected)
        existing_set = set(existing)
        if existing and existing_set != expected_set:
            print(
                "Refusing to overwrite a non-empty, non-matching target mapping table",
                file=sys.stderr,
            )
            return 1
        if existing_set == expected_set:
            print("License resource mappings already match the source.")
            return 0
        if not args.apply:
            print("Audit passed; rerun with --apply to insert the mappings.")
            return 0

        with target.cursor() as cursor:
            execute_values(
                cursor,
                """insert into license_resource_mapping
                       (mapping_id, bitstream_uuid, license_id) values %s""",
                expected,
                page_size=1000,
            )
            cursor.execute(
                """select setval(
                       'license_resource_mapping_mapping_id_seq',
                       (select max(mapping_id) from license_resource_mapping),
                       true
                   )"""
            )
        target.commit()

        inserted = fetch_all(
            target,
            """select mapping_id, bitstream_uuid::text, license_id
                 from license_resource_mapping order by mapping_id""",
        )
        if set(inserted) != expected_set:
            raise RuntimeError("Post-insert validation of license mappings failed")
        print(f"Migrated and verified {len(inserted)} active license resource mappings.")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as error:
        print(f"License mapping migration failed: {error}", file=sys.stderr)
        raise
