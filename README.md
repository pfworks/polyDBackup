# polyDBackup — Verified Database Backup to S3

A containerized database backup tool that dumps PostgreSQL, MySQL, or MariaDB databases to S3 with compression, optional encryption, retention management, and automated restore verification via table-level checksums.

## How It Works

1. **Globals** (optional, PostgreSQL only) — Dumps all roles, passwords, and grants via `pg_dumpall --globals-only`.
2. **Snapshot** — For each target database, a temporary copy (suffixed with `_polydbackup` by default) is created on the source server to get a consistent point-in-time view without locking the live database.
3. **Checksum** — Every table across all user schemas in the snapshot is checksummed (MD5 for PostgreSQL, `CHECKSUM TABLE` for MySQL/MariaDB).
4. **Dump & Compress** — The snapshot is dumped to SQL, compressed, and an MD5 of the archive is generated.
5. **Encrypt** (optional) — The compressed dump is encrypted with AES-256-CBC via OpenSSL.
6. **Upload** — The compressed (and optionally encrypted) dump and its `.md5` sidecar are uploaded to S3.
7. **Retention** — Backups older than `RETENTION_DAYS` are deleted from S3.
8. **Verify** (optional, on a schedule) — The backup is downloaded, restored into a temporary Docker container (or external test server), and table checksums are compared against the originals. A `.verified` marker is written to S3 on success.
9. **Cleanup** — All temporary snapshot databases are dropped.

## Files

| File | Purpose |
|---|---|
| `db-backup.sh` | Main backup script (globals → snapshot → checksum → dump → encrypt → upload → retention → verify) |
| `restore.sh` | Interactive restore tool — lists available backups, downloads, verifies MD5, decrypts, decompresses, and restores to a target database |
| `db-backup.conf` | Configuration file (all variables) |
| `docker-compose.yml` | Two profiles: `backup` (runs backup) and `restore` (interactive restore) |
| `Dockerfile` | Alpine-based image with psql, mariadb-client, aws-cli, openssl, zstd, gzip, xz, docker-cli |
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
| `S3_HOST` | — | Custom S3 endpoint hostname (sets `AWS_ENDPOINT_URL`) |
| `COMPRESSION` | `zstd` | Compression algorithm: `zstd`, `gzip`, `xz`, or `none` |
| `RETENTION_DAYS` | `30` | Delete S3 backups older than this many days. `0` = keep forever |
| `SNAP_SUFFIX` | `_polydbackup` | Suffix appended to database names for temporary snapshots. Change to avoid conflicts |
| `DUMP_GLOBALS` | `false` | Dump global roles and grants (`pg_dumpall --globals-only`). PostgreSQL only |
| `ENCRYPT_BACKUPS` | `false` | Encrypt backups with AES-256-CBC via OpenSSL |
| `ENCRYPT_KEY` | — | Encryption passphrase (required when `ENCRYPT_BACKUPS=true`) |
| `VERIFY_DAY` | `Saturday` | Day of the week to run restore verification. `ALL` = every run, `NONE` = never |
| `VERIFY_MODE` | `docker` | `docker` = spin up a temporary container for verification. `external` = use an existing test server |
| `TEST_DB_HOST` | — | Hostname of external test DB (required when `VERIFY_MODE=external`) |
| `TEST_DB_PORT` | — | Port of external test DB |
| `TEST_DB_USER` | — | Username for external test DB |
| `TEST_DB_PASS` | — | Password for external test DB |
| `TEST_DOCKER_IMAGE` | auto-detected | Override the Docker image used for the verification container (e.g. `postgres:16-alpine`) |
| `DB_BACKUP_CONF` | `/etc/db-backup/db-backup.conf` | Path to the config file (environment variable only) |

## Encryption

polyDBackup supports optional AES-256-CBC encryption of all backup files using OpenSSL. Encryption is applied after compression and before upload to S3. The encryption key (passphrase) is provided at runtime via environment variable and is never stored in the image or source code.

### Generating an encryption key

Generate a strong random passphrase:

```bash
openssl rand -base64 32
```

Save this key securely — you will need it to decrypt/restore backups. If you lose the key, encrypted backups are unrecoverable.

### Enabling encryption

#### Standalone (db-backup.conf)

Add to your `db-backup.conf`:

```
ENCRYPT_BACKUPS=true
ENCRYPT_KEY=your-generated-key-here
```

#### Ansible deployment

Add to your playbook vars:

```yaml
polydbackup_encrypt_backups: "true"
polydbackup_encrypt_key: !vault |
  $ANSIBLE_VAULT;1.1;AES256
  ...your vaulted key...
```

To vault the key:

```bash
ansible-vault encrypt_string 'your-generated-key-here' --name polydbackup_encrypt_key
```

### Decrypting a backup manually

```bash
# Decrypt
openssl enc -d -aes-256-cbc -salt -pbkdf2 -pass pass:your-key -in backup.sql.zst.enc -out backup.sql.zst

# Decompress (example for zstd)
zstd -d backup.sql.zst
```

### Security notes

- The encryption key is passed as an environment variable at runtime. It is not stored in the Docker image, git repo, or Dockerfile.
- The `db-backup.conf` file on the target host contains the key and should be mode `0600` (the Ansible role sets this automatically).
- If the running container or host is compromised, the attacker has access to the key. However, at that point they also have direct database access. The primary purpose of encryption is to protect backups at rest on S3.
- Globals dumps (`pg_dumpall --globals-only`) contain password hashes for all database roles. Enabling encryption is strongly recommended when `DUMP_GLOBALS=true`.

## Usage

### Standalone

#### Run a backup

```bash
docker-compose --profile backup run --rm db-backup
```

#### Run a backup with verification

```bash
docker-compose --profile backup run --rm -e VERIFY_DAY=ALL db-backup
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

After deploying, set `polydbackup_git_update` back to `false` to prevent unintended updates on subsequent runs.

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
| `polydbackup_s3_host` | `S3_HOST` / `AWS_ENDPOINT_URL` | — (optional) |
| `polydbackup_compression` | `COMPRESSION` | `zstd` |
| `polydbackup_retention_days` | `RETENTION_DAYS` | `365` |
| `polydbackup_dump_globals` | `DUMP_GLOBALS` | `false` |
| `polydbackup_encrypt_backups` | `ENCRYPT_BACKUPS` | `false` |
| `polydbackup_encrypt_key` | `ENCRYPT_KEY` | — |
| `polydbackup_verify_day` | `VERIFY_DAY` | `Saturday` |
| `polydbackup_verify_mode` | `VERIFY_MODE` | `docker` |
| `polydbackup_container_name` | Container & systemd unit name | — (required) |
| `polydbackup_container_network_mode` | Docker network mode or named network | `host` |

## Database User Requirements

The backup user needs the following privileges:

### PostgreSQL

```sql
-- Create and drop snapshot databases
ALTER USER backup_user CREATEDB;

-- Read all data across all databases
GRANT pg_read_all_data TO backup_user;
```

### MySQL / MariaDB

The backup user needs `SELECT`, `SHOW DATABASES`, `LOCK TABLES`, `RELOAD`, and `CREATE`/`DROP` privileges for snapshot databases.

## Requirements

When running via Docker (the default), everything is included in the image. For bare-metal usage the host needs:
- `bash`, `coreutils`, `openssl`
- `psql` / `pg_dump` / `pg_dumpall` (for PostgreSQL) or `mariadb` / `mariadb-dump` / `mysql` / `mysqldump` (for MySQL/MariaDB)
- `aws` CLI
- `zstd`, `gzip`, or `xz` (matching your `COMPRESSION` setting)
- `docker` CLI (if using `VERIFY_MODE=docker`)

## Notes

- The `docker.sock` is mounted read-only into the backup container so it can launch ephemeral verification containers on the host.
- When `polydbackup_container_network_mode` is set to a named Docker network (e.g. `postgres-region-net`), the role automatically uses the `networks` key with `external: true` instead of `network_mode`. For `host`, `bridge`, or `none`, `network_mode` is used as-is.
- Snapshot databases (`*_polydbackup`) are cleaned up at the start and end of every run. Active connections to stale snapshots are terminated before dropping.
- The snapshot suffix is configurable via the `SNAP_SUFFIX` environment variable (defaults to `_polydbackup`), avoiding conflicts with user databases.
- PostgreSQL dumps use `--no-owner --no-acl` to avoid permission errors when the backup user is not a superuser.
- Checksums cover all user schemas (not just `public`), using fully qualified `schema.table` references to work regardless of `search_path` settings (e.g. Patroni-managed instances).
- On verification failure the script exits with code 1, making it easy to alert on in systemd or CI.
