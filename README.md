# db-backuper

Database backup and restore tool supporting PostgreSQL, MariaDB, Valkey/Redis, ClickHouse, and CouchDB with S3-compatible storage and optional AES-256 encryption.

Designed to run as a container job — reads configuration from environment variables, performs one backup or restore operation, then exits.

## Usage

```bash
docker run --rm \
  -e OPERATION=backup \
  -e DATABASE_URL=postgres://user:password@host:5432/mydb \
  -e S3_ENDPOINT=https://minio.example.com \
  -e S3_BUCKET=backups \
  -e S3_KEY=mydb/2026-03-12.dump \
  -e S3_ACCESS_KEY=minioadmin \
  -e S3_SECRET_KEY=minioadmin \
  ghcr.io/eyevinn/db-backuper:latest
```

## Environment Variables

| Variable | Required | Description |
|----------|----------|-------------|
| `OPERATION` | Yes | `backup` or `restore` |
| `DATABASE_URL` | Yes | Connection URL (see supported schemes below) |
| `S3_ENDPOINT` | Yes | S3-compatible storage endpoint |
| `S3_BUCKET` | Yes | S3 bucket name |
| `S3_KEY` | Yes | S3 object key (path within bucket) |
| `S3_ACCESS_KEY` | Yes | S3 access key |
| `S3_SECRET_KEY` | Yes | S3 secret key |
| `ENCRYPTION_KEY` | No | AES-256-CBC encryption key |
| `S3_READY_TIMEOUT_SECONDS` | No | Max seconds to wait for the S3 endpoint to answer before the transfer (default `300`). Skipped for `amazonaws.com` endpoints. On timeout the job proceeds and the transfer decides the outcome |
| `S3_READY_INTERVAL_SECONDS` | No | Seconds between readiness probes (default `5`) |

Before every backup/restore the job waits for the S3 endpoint, `mc cp` is retried up to 3 times (5 s, then 15 s back-off; credential errors and missing objects are not retried), and backups ensure the bucket exists.

## Running the tests

```bash
bash tests/run.sh
```

Requires bash, coreutils and gzip. Tools such as `mc`, `pg_dump` and `sleep` are stubbed.

`tests/restore-valkey.integration.sh` uses real servers and is skipped unless `VALKEY_BIN_DIR` points at a directory with `valkey-server` and `valkey-cli` (or they are on `PATH`). Build the pinned fork commit and run it with `VALKEY_BIN_DIR=/tmp/valkey-src/src bash tests/restore-valkey.integration.sh`, or run it inside the built image.

## Supported Database URL Schemes

The `DATABASE_URL` scheme determines which database client tool to use:

| Scheme | Database | Backup Tool | Default Port |
|--------|----------|-------------|-------------|
| `postgres://` or `postgresql://` | PostgreSQL | pg_dump / pg_restore | 5432 |
| `mariadb://` or `mysql://` | MariaDB/MySQL | mysqldump / mysql | 3306 |
| `valkey://` or `redis://` | Valkey/Redis | redis-cli (backup), valkey-server + valkey-cli (restore) | 6379 |
| `clickhouse://` | ClickHouse | clickhouse-client | 9000 |
| `couchdb://` | CouchDB | HTTP API (curl) | 5984 |

### URL Format

```
scheme://[user:password@]host[:port][/database]
```

Examples:
- `postgres://admin:secret@db.example.com:5432/myapp`
- `mariadb://root:pass@10.0.0.5/orders`
- `valkey://redis.local:6379`
- `clickhouse://default:pass@ch.local:9000/analytics`
- `couchdb://admin:admin@couch.local:5984/documents`

## Valkey/Redis restore

Valkey/Redis restore loads the backup into a throwaway `valkey-server` inside the job pod and copies the keys to the target with `MIGRATE`. The loader is built from the fork commit pinned in the Dockerfile (`VALKEY_COMMIT`, `eyevinn-osaas/valkey`), because official images cannot read these backups. Every job prints `db-backuper: valkey loader <commit>` as its first line.

- **Supported backups**: files whose magic is `REDIS` with RDB version 1-12. That covers the OSC catalog `valkey-io-valkey` build (fork `unstable`, version 255.255.255, RDB 12) and Redis OSS up to 7.2 and Valkey 7.2-8.1 (RDB 11 or lower).
- **Supported targets**: servers that accept RDB-12 `DUMP` payloads, i.e. the OSC catalog fork build.
- **Refused, all with exit code 5 and the target untouched**: a `VALKEY` magic (Valkey 9 or later), RDB above 12, module types, an empty backup, a backup the loader cannot load, and a target that rejects the probe key (an official Valkey 7.2-8.1 or 9.x target, wrong credentials, a timeout).
- **In-place restore**: the target is flushed (`FLUSHALL SYNC`) and then filled from the backup. The flush happens only after the backup has been loaded, is non-empty and the target has accepted one probe key of every type in it.
- **Exit code 5 after the flush**: a partial transfer, a verification shortfall (the target holds fewer keys than the backup in some database) or a `MIGRATE` timeout. After a timeout it is unknown whether the batch arrived, so success is never reported.
- **Tunables**: `VALKEY_MIGRATE_TIMEOUT_MS` (I/O inactivity timeout per `MIGRATE` batch of 500 keys, default `60000`), `VALKEY_LOADER_WAIT_S` (max wait for the loader to load the file, default `3600`), `VALKEY_LOADER_PORT` (default `6390`).
- **Memory**: the loader holds the whole dataset in the job pod. An OOM kill while loading fails the job before the flush.

## Encryption

When `ENCRYPTION_KEY` is set, backups are encrypted with AES-256-CBC before uploading to S3, and decrypted after downloading during restore. ClickHouse backups use the native S3 backup engine and do not support client-side encryption.

## Failure text

The console shows the last `ERROR:` line of the restore job log. Every restore failure path must therefore print one.

- **Explicit failures** print their own line (`ERROR: S3 download failed`, `ERROR: Decryption failed`, `ERROR: mysql restore failed`, `refuse()` in the Valkey restore, and so on).
- **Everything else** (a corrupt gzip, a failing `mv`, a `jq` parse error, `mc alias set`) is caught by `scripts/error-trap.sh`, which `entrypoint.sh` (restore only) and every `restore-*.sh` source. It prints exactly one `ERROR: restore failed during <step>` and exits with the failing command's own status. `<step>` is one of `download`, `decrypt`, `decompress`, `restore`, `configure S3`, set through `RESTORE_STEP` before each phase. The failing command line is never printed, because it can hold a database URL or key.
- **Missing variable and non-executable script**: `ERROR: missing required variable <NAME>` (exit 1) and `ERROR: Script is not executable: <path>` (exit 126).
- **Fixed-class text only, with one exception**: the Valkey line `backup could not be loaded (<last loader log line>), target not modified` keeps the last log line of the throwaway local loader. The loader never sees the target password or key data. Every other message is fixed text.
- **New failure paths** must print an `ERROR:` line before `exit <N>`; `tests/run.sh` lints for it. Exit statuses are part of the contract (see the table in `tests/restore-errors.test.sh`).

## Exit Codes

| Code | Meaning |
|------|---------|
| 0 | Success |
| 1 | Invalid arguments or unsupported database type |
| 2 | Database operation failed (dump/connect) |
| 3 | S3 operation failed (upload/download) |
| 4 | Encryption/decryption failed |
| 5 | Restore operation failed |

## OSC Integration

This project is designed to be used as an [Eyevinn Open Source Cloud](https://www.osaas.io) job service. When imported into the OSC catalog, the platform auto-generates an orchestrator that manages job creation, status tracking, and log retrieval via REST API.

## License

MIT
