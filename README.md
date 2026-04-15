# polyDBackup — Verified Database Backup to S3

A containerized database backup tool that dumps PostgreSQL, MySQL, or MariaDB databases to S3 with compression, retention management, and automated restore verification via table-level checksums.

## How It Works

1. **Snapshot** — For each target database, a `_snapshot` copy is created on the source server to get a consistent point-in-time view without locking the live database.
2. **Checksum** — Every table in the snapshot is checksummed (MD5 for PostgreSQL, `CHECKSUM TABLE` for MySQL/MariaDB).
3. **Dump & Compress** — The snapshot is dumped to SQL, compressed, and an MD5 of the archive is generated.
4. **Upload** — The compressed dump and its `.md5` sidecar are uploaded to S3.
5. **Retention** — Backups older than `RETENTION_DAYS` are deleted from S3.
6. **Verify** (optional, on a schedule) — The backup is downloaded, restored into a temporary Docker container (or external test server), and table checksums are compared against the originals. A `.verified` marker is written to S3 on success.
7. **Cleanup** — All `_snapshot` databases are dropped.

## Files

| File | Purpose |
|---|---|
| `db-backup.sh` | Main backup script (snapshot → checksum → dump → upload → retention → verify) |
| `restore.sh` | Interactive restore tool — lists available backups, downloads, verifies MD5, decompresses, and restores to a target database |
| `db-backup.conf` | Configuration file (all variables) |
| `docker-compose.yml` | Two profiles: `backup` (runs backup) and `restore` (interactive restore) |
| `Dockerfile` | Alpine-based image with psql, mariadb-client, aws-cli, zstd, gzip, xz, docker-cli |
| `db-backup.service` | systemd oneshot unit that runs the backup via docker-compose |
| `db-backup.timer` | systemd timer — daily at 02:00 with up to 5 minutes random delay |

## Configuration Variables

All variables are set in `db-backup.conf` (or passed as environment variables).

### Required

| Variable | Description | Example |
|---|---|---|
| `DB_TYPE` | Database engine | `pgsql`, `mariadb`, `mysql` |
| `DB_HOST` | Database hostname or IP | `10.0.0.5` |
| `DB_PORT` | Database port | `5432`, `3306` |
| `DB_NAME` | Database name to back up, or `ALL` to discover and back up every user database | `myapp` or `ALL` |
| `DB_USER` | Database username | `backup_user` |
| `DB_PASS` | Database password | |
| `S3_BUCKET` | S3 bucket name | `my-backups` |
| `S3_PATH` | Key prefix inside the bucket | `backups` |
| `AWS_ACCESS_KEY_ID` | AWS access key | |
| `AWS_SECRET_ACCESS_KEY` | AWS secret key | |

### Optional

| Variable | Default | Description |
|---|---|---|
| `S3_REGION` | `us-east-1` | AWS region for the S3 bucket |
| `COMPRESSION` | `zstd` | Compression algorithm: `zstd`, `gzip`, `xz`, or `none` |
| `RETENTION_DAYS` | `30` | Delete S3 backups older than this many days. `0` = keep forever |
| `VERIFY_DAY` | `Saturday` | Day of the week to run restore verification. `ALL` = every run, `NONE` = never |
| `VERIFY_MODE` | `docker` | `docker` = spin up a temporary container for verification. `external` = use an existing test server |
| `TEST_DB_HOST` | — | Hostname of external test DB (required when `VERIFY_MODE=external`) |
| `TEST_DB_PORT` | — | Port of external test DB |
| `TEST_DB_USER` | — | Username for external test DB |
| `TEST_DB_PASS` | — | Password for external test DB |
| `TEST_DOCKER_IMAGE` | auto-detected | Override the Docker image used for the verification container (e.g. `postgres:16-alpine`) |
| `DB_BACKUP_CONF` | `/etc/db-backup/db-backup.conf` | Path to the config file (environment variable only) |

## Usage

### Standalone

#### Run a backup

```bash
docker-compose --profile backup run --rm db-backup
```

#### Interactive restore

```bash
docker-compose --profile restore run --rm db-restore
```

Options:
- `--verified` — only show backups that passed verification
- Positional args: `db-restore [--verified] [backup_file] [target_db_name]`

#### systemd (host-level scheduling)

```bash
sudo cp db-backup.service db-backup.timer /etc/systemd/system/
sudo cp -r . /opt/db-backup/
sudo systemctl daemon-reload
sudo systemctl enable --now db-backup.timer
```

### Ansible Deployment

polyDBackup includes an Ansible role (`polyDBackup`). The role clones this repo to the target host, builds the Docker image, templates the config, and sets up a systemd timer.

#### Playbooks

```bash
# PostgreSQL
ansible-playbook postgres-polyDBackup.yaml

# MariaDB
ansible-playbook mariadb-polyDBackup.yaml
```

#### Updating to a new version

The role pins to a git tag and does not auto-update. To deploy a new version:

```bash
ansible-playbook postgres-polyDBackup.yaml -e polydbackup_git_version=v1.1.0 -e polydbackup_git_update=true
```

#### Ansible Variables

All role variables use the `polydbackup_` prefix. See `roles/polyDBackup/defaults/main.yaml` for the full list. Key variables:

| Ansible Variable | Maps To | Default |
|---|---|---|
| `polydbackup_git_version` | Git tag/branch to clone | `v1.0.0` |
| `polydbackup_git_update` | Whether to pull changes | `false` |
| `polydbackup_type` | `DB_TYPE` | — (required) |
| `polydbackup_db_name` | `DB_NAME` | — (required) |
| `polydbackup_db_host` | `DB_HOST` | — (required) |
| `polydbackup_db_port` | `DB_PORT` | — (required) |
| `polydbackup_db_username` | `DB_USER` | — (required) |
| `polydbackup_db_password` | `DB_PASS` | — (required) |
| `polydbackup_s3_bucket` | `S3_BUCKET` | — (required) |
| `polydbackup_s3_access_key` | `AWS_ACCESS_KEY_ID` | — (required) |
| `polydbackup_s3_secret_key` | `AWS_SECRET_ACCESS_KEY` | — (required) |
| `polydbackup_s3_path` | `S3_PATH` | — (required) |
| `polydbackup_s3_region` | `S3_REGION` | `{{ region }}` |
| `polydbackup_compression` | `COMPRESSION` | `zstd` |
| `polydbackup_retention_days` | `RETENTION_DAYS` | `365` |
| `polydbackup_verify_day` | `VERIFY_DAY` | `Saturday` |
| `polydbackup_verify_mode` | `VERIFY_MODE` | `docker` |
| `polydbackup_container_name` | Container & systemd unit name | — (required) |
| `polydbackup_container_network_mode` | Docker network mode | `host` |

## Requirements

When running via Docker (the default), everything is included in the image. For bare-metal usage the host needs:
- `bash`, `coreutils`
- `psql` / `pg_dump` (for PostgreSQL) or `mariadb` / `mariadb-dump` / `mysql` / `mysqldump` (for MySQL/MariaDB)
- `aws` CLI
- `zstd`, `gzip`, or `xz` (matching your `COMPRESSION` setting)
- `docker` CLI (if using `VERIFY_MODE=docker`)

## Notes

- The `docker.sock` is mounted read-only into the backup container so it can launch ephemeral verification containers on the host.
- `network_mode: host` is used so the backup container can reach the database directly.
- Snapshot databases (`*_snapshot`) are cleaned up at the start and end of every run to handle interrupted previous runs.
- On verification failure the script exits with code 1, making it easy to alert on in systemd or CI.
