FROM golang:1.23.10-bookworm AS mc-build
ARG MC_TAG=RELEASE.2025-08-13T08-35-41Z
ARG MC_COMMIT=7394ce0dd2a80935aded936b09fa12cbb3cb8096
RUN git clone --depth 1 --branch ${MC_TAG} https://github.com/minio/mc /src/mc \
    && cd /src/mc \
    && test "$(git rev-parse HEAD)" = "${MC_COMMIT}" \
    && CGO_ENABLED=0 go build -trimpath -o /out/mc \
       -ldflags "-s -w \
         -X github.com/minio/mc/cmd.Version=2025-08-13T08:35:41Z \
         -X github.com/minio/mc/cmd.ReleaseTag=${MC_TAG} \
         -X github.com/minio/mc/cmd.CommitID=${MC_COMMIT} \
         -X github.com/minio/mc/cmd.CopyrightYear=2025" .

# The valkey loader is built from the exact fork commit the OSC catalog
# valkey-io-valkey image runs in prod (eyevinn-osaas/valkey unstable, RDB 12).
# It is pinned because official Valkey/Redis images cannot read these backups:
# Valkey 7.2-8.1 use RDB 11 and 9.0 uses RDB 80.
FROM debian:bookworm AS valkey-build
ARG VALKEY_COMMIT=bcb5842925f7c64e4b7a98f0b72891b61730817a
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential git ca-certificates \
    && rm -rf /var/lib/apt/lists/*
RUN git init /src/valkey \
    && cd /src/valkey \
    && git fetch --depth 1 https://github.com/eyevinn-osaas/valkey ${VALKEY_COMMIT} \
    && git checkout FETCH_HEAD \
    && test "$(git rev-parse HEAD)" = "${VALKEY_COMMIT}" \
    && make -j"$(nproc)" BUILD_TLS=no

FROM debian:bookworm-slim

ARG VALKEY_COMMIT=bcb5842925f7c64e4b7a98f0b72891b61730817a
ENV DB_BACKUPER_VALKEY_LOADER_COMMIT=${VALKEY_COMMIT}

RUN apt-get update && apt-get install -y --no-install-recommends \
    curl \
    jq \
    openssl \
    ca-certificates \
    gzip \
    gnupg \
    lsb-release \
    && rm -rf /var/lib/apt/lists/*

# PostgreSQL client (pg_dump, pg_restore) — v17 from PGDG repo
# Debian Bookworm ships pg15; we need pg17 to dump PG 17 servers
RUN curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc \
    | gpg --dearmor -o /usr/share/keyrings/pgdg.gpg && \
    echo "deb [signed-by=/usr/share/keyrings/pgdg.gpg] http://apt.postgresql.org/pub/repos/apt bookworm-pgdg main" \
    > /etc/apt/sources.list.d/pgdg.list && \
    apt-get update && apt-get install -y --no-install-recommends \
    postgresql-client-17 \
    && rm -rf /var/lib/apt/lists/*

# MariaDB client (mysqldump, mysql)
RUN apt-get update && apt-get install -y --no-install-recommends \
    mariadb-client \
    && rm -rf /var/lib/apt/lists/*

# Valkey/Redis CLI
RUN apt-get update && apt-get install -y --no-install-recommends \
    redis-tools \
    && rm -rf /var/lib/apt/lists/*

# ClickHouse client (static binary)
RUN curl -fsSL https://clickhouse.com/ | sh && \
    mv clickhouse /usr/local/bin/clickhouse && \
    ln -s /usr/local/bin/clickhouse /usr/local/bin/clickhouse-client

# Minio client (mc) for S3 operations
COPY --from=mc-build /out/mc /usr/local/bin/mc

# Valkey loader and CLI used by restore-valkey.sh
COPY --from=valkey-build /src/valkey/src/valkey-server /usr/local/bin/valkey-server
COPY --from=valkey-build /src/valkey/src/valkey-cli /usr/local/bin/valkey-cli

COPY scripts/ /opt/backup/
RUN chmod +x /opt/backup/*.sh

ENTRYPOINT ["/opt/backup/entrypoint.sh"]
