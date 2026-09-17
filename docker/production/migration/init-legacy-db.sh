#!/usr/bin/env bash
set -Eeuo pipefail

createuser --username postgres dspace
createdb --username postgres --owner dspace --encoding UTF8 clarin-dspace
createdb --username postgres --owner dspace --encoding UTF8 clarin-utilities

import_dump() {
    local database="$1"
    local dump="$2"
    local pass

    for pass in 1 2; do
        echo "Importing ${database}, pass ${pass}/2"
        # The legacy plain-SQL dumps contain objects in a non-topological order.
        # Continue after individual SQL errors as required by ufal/dspace-migrate.
        psql --username postgres --dbname "${database}" --file "${dump}" \
            >"/tmp/${database}-pass-${pass}.log" 2>&1
    done
}

import_dump clarin-dspace /migration/dump/clarin-dspace.sql
import_dump clarin-utilities /migration/dump/clarin-utilities.sql

psql --username postgres --dbname clarin-dspace --tuples-only --command \
    "select 'legacy items=' || count(*) from item union all select 'legacy bitstreams=' || count(*) from bitstream;"
