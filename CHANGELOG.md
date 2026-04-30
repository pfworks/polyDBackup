# Changelog

## v1.0.6
- Added MariaDB support for global roles/grants dump (`DUMP_GLOBALS=true`)
  - Dumps users and `SHOW GRANTS` for each non-system user
- Added MariaDB support for backup encryption (`ENCRYPT_BACKUPS=true`)

## v1.0.5
- Updated README with encryption documentation (key generation, deployment, decryption)
- Added database user requirements section
- Updated configuration variable tables with all new options
- Added notes on Patroni compatibility, `--no-owner`, and network handling
- Updated `db-backup.conf.example` with new variables

## v1.0.4
- Added optional AES-256-CBC encryption of backup files via OpenSSL (`ENCRYPT_BACKUPS`, `ENCRYPT_KEY`)
- Added optional dump of global roles and grants for PostgreSQL (`DUMP_GLOBALS`)
  - Uses `pg_dumpall --globals-only`, uploaded as a separate file to S3
- Encryption is applied after compression, before upload
- Both features are off by default and controlled via environment variables

## v1.0.3
- Changed checksum queries to use fully qualified `schema.table` references
- Checksums now cover all user schemas, not just `public`
- Fixes checksum failures on PostgreSQL instances with empty `search_path` (e.g. Patroni-managed)

## v1.0.2
- Terminate active connections before dropping snapshot databases
- Fixes `database is being accessed by other users` errors during cleanup of stale snapshots
- Applied to all three cleanup locations: stale snapshot cleanup, verification failure cleanup, and end-of-run cleanup

## v1.0.1
- Added `--no-owner --no-acl` to both `pg_dump` calls (snapshot creation and dump to file)
- Fixes `must be member of role "postgres"` errors when backup user is not a superuser

## v1.0.0
- Initial release
- Snapshot-based backup for PostgreSQL, MySQL, and MariaDB
- Table-level checksums for backup verification
- Compression support: zstd, gzip, xz, none
- S3 upload with MD5 sidecar files
- Configurable retention with automatic cleanup
- Automated restore verification via Docker containers or external test servers
- systemd timer integration
- Ansible role for deployment
