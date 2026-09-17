import os
from datetime import datetime

_this_dir = os.path.dirname(os.path.abspath(__file__))
_timestamp = datetime.now().strftime("%Y_%m_%d__%H.%M.%S")


def required(name):
    value = os.environ.get(name)
    if not value:
        raise RuntimeError(f"Required environment variable is missing: {name}")
    return value


settings = {
    "log_file": os.path.join(_this_dir, "../__logs", f"{_timestamp}.txt"),
    "memory_log_file": os.path.join(_this_dir, "../__logs", f"{_timestamp}.memory.txt"),
    "resume_dir": os.path.join(_this_dir, "__temp", "resume"),
    "backend": {
        "endpoint": required("MIGRATION_BACKEND_ENDPOINT"),
        "user": required("MIGRATION_ADMIN_EMAIL"),
        "password": required("MIGRATION_ADMIN_PASSWORD"),
        "authentication": True,
        "reauth_minutes": 20,
        "import_workers": 6,
        "ignore_deleted_bitstreams": True,
        "testing": False,
    },
    "ignore": {
        "missing-icons": ["PUB", "RES", "ReD", "Inf"],
        "epersons": [198],
        "fields": ["local.bitstream.file", "local.bitstream.redirectToURL", "local.branding"],
    },
    "replaced": {"fields": ["local.hasMetadata"]},
    "db_dspace_7": {
        "name": "dspace",
        "host": required("MIGRATION_TARGET_DB_HOST"),
        "port": 5432,
        "user": "dspace",
        "password": required("MIGRATION_TARGET_DB_PASSWORD"),
    },
    "db_dspace_5": {
        "name": "clarin-dspace",
        "host": required("MIGRATION_LEGACY_DB_HOST"),
        "port": 5432,
        "user": "postgres",
        "password": required("MIGRATION_LEGACY_DB_PASSWORD"),
    },
    "db_utilities_5": {
        "name": "clarin-utilities",
        "host": required("MIGRATION_LEGACY_DB_HOST"),
        "port": 5432,
        "user": "postgres",
        "password": required("MIGRATION_LEGACY_DB_PASSWORD"),
    },
    "input": {
        "tempdbexport_v5": "/opt/dspace-migrate/input/tempdbexport_v5",
        "tempdbexport_v7": "/opt/dspace-migrate/input/tempdbexport_v7",
        "icondir": "/opt/dspace-migrate/assets/icon/",
        "test": "/opt/dspace-migrate/input/test",
        "test_json_filename": "test.json",
    },
    "licenses": {
        "to_replace_def_url": os.environ.get("MIGRATION_LICENSE_SOURCE_PREFIX", ""),
        "replace_with_def_url": os.environ.get("MIGRATION_LICENSE_TARGET_PREFIX", ""),
    },
    "version_date_fields": ["dc.date.issued", "dc.date.accessioned", "dc.date.created"],
}
