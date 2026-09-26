FROM python:3.11-slim-bookworm

ARG DSPACE_MIGRATE_REF

COPY patches/parallel-bitstreams.patch /tmp/parallel-bitstreams.patch

RUN apt-get update \
    && apt-get install -y --no-install-recommends git libpq5 \
    && git clone https://github.com/ufal/dspace-migrate.git /opt/dspace-migrate \
    && cd /opt/dspace-migrate \
    && git checkout --detach "${DSPACE_MIGRATE_REF}" \
    && git submodule update --init --depth 1 libs/dspace-rest-python \
    && git apply --recount /tmp/parallel-bitstreams.patch \
    && pip install --no-cache-dir -r requirements.txt \
    && pip install --no-cache-dir -r libs/dspace-rest-python/requirements.txt \
    && apt-get purge -y --auto-remove git \
    && rm -rf /var/lib/apt/lists/* /tmp/parallel-bitstreams.patch

COPY project_settings.py /opt/dspace-migrate/src/project_settings.py
COPY migrate_license_mappings.py /opt/dspace-migrate/src/migrate_license_mappings.py

WORKDIR /opt/dspace-migrate/src
