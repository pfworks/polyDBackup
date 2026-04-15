#!/bin/bash
set -euo pipefail

# --- Load config ---
CONF="${DB_BACKUP_CONF:-/etc/db-backup/db-backup.conf}"
if [ -f "$CONF" ]; then
    set -a; source "$CONF"; set +a
fi

: "${DB_TYPE:?DB_TYPE required}"
: "${DB_HOST:?DB_HOST required}"
: "${DB_PORT:?DB_PORT required}"
: "${DB_NAME:?DB_NAME required}"
: "${DB_USER:?DB_USER required}"
: "${DB_PASS:?DB_PASS required}"
: "${S3_BUCKET:?S3_BUCKET required}"
: "${S3_PATH:?S3_PATH required}"
: "${S3_REGION:=us-east-1}"
: "${COMPRESSION:=zstd}"
: "${RETENTION_DAYS:=30}"
: "${VERIFY_DAY:=Saturday}"
: "${VERIFY_MODE:=docker}"

export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_DEFAULT_REGION="$S3_REGION"
NOW=$(date +%Y%m%d-%H%M%S)
TODAY=$(date +%A)
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

# --- DB client helpers ---
case "$DB_TYPE" in
    mariadb) MYSQL_CMD=mariadb; MYSQLDUMP_CMD=mariadb-dump ;;
    mysql)   MYSQL_CMD=mysql;   MYSQLDUMP_CMD=mysqldump ;;
esac

pg() { PGPASSWORD="$DB_PASS" psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" "$@"; }
pgq() { pg -d "${1:-postgres}" -t -A -c "$2"; }
my() { $MYSQL_CMD -h "$DB_HOST" -P "$DB_PORT" -u "$DB_USER" -p"$DB_PASS" "$@"; }
myq() { my ${1:+"$1"} -sN -e "$2" 2>/dev/null; }
mydump() { $MYSQLDUMP_CMD -h "$DB_HOST" -P "$DB_PORT" -u "$DB_USER" -p"$DB_PASS" "$@" 2>/dev/null; }

log() { echo "[$(date +%H:%M:%S)] $*"; }

# --- Discover databases ---
discover_dbs() {
    case "$DB_TYPE" in
        pgsql)
            pgq postgres "SELECT datname FROM pg_database WHERE datistemplate = false AND datname NOT IN ('postgres') AND datname NOT LIKE '%_snapshot' ORDER BY datname;"
            ;;
        mysql|mariadb)
            myq "" "SELECT schema_name FROM information_schema.schemata WHERE schema_name NOT IN ('information_schema','performance_schema','mysql','sys') AND schema_name NOT LIKE '%\_snapshot' ORDER BY schema_name;"
            ;;
    esac
}

if [ "$DB_NAME" = "ALL" ]; then
    DB_LIST=$(discover_dbs)
    log "Discovered databases: $(echo $DB_LIST | tr '\n' ' ')"
else
    DB_LIST="$DB_NAME"
fi

# --- Clean up stale snapshots from previous run ---
log "Cleaning up stale snapshots..."
case "$DB_TYPE" in
    pgsql)
        for snap in $(pgq postgres "SELECT datname FROM pg_database WHERE datname LIKE '%_snapshot';"); do
            [ -z "$snap" ] && continue
            log "  Dropping $snap"
            pgq postgres "DROP DATABASE IF EXISTS $snap;" >/dev/null
        done
        ;;
    mysql|mariadb)
        for snap in $(myq "" "SELECT schema_name FROM information_schema.schemata WHERE schema_name LIKE '%\_snapshot';"); do
            [ -z "$snap" ] && continue
            log "  Dropping $snap"
            myq "" "DROP DATABASE IF EXISTS $snap;" >/dev/null
        done
        ;;
esac

# --- Create snapshots, checksum, dump, upload ---
CHECKSUM_FILE="$TMPDIR/checksums.txt"
> "$CHECKSUM_FILE"

for DB in $DB_LIST; do
    SNAP="${DB}_snapshot"
    log "=== $DB ==="

    # Create snapshot
    log "  Creating snapshot: $SNAP"
    case "$DB_TYPE" in
        pgsql)
            pgq postgres "DROP DATABASE IF EXISTS $SNAP;" >/dev/null
            pgq postgres "CREATE DATABASE $SNAP;" >/dev/null
            PGPASSWORD="$DB_PASS" pg_dump -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" "$DB" | pg -d "$SNAP" >/dev/null 2>&1
            ;;
        mysql|mariadb)
            myq "" "DROP DATABASE IF EXISTS $SNAP;" >/dev/null
            myq "" "CREATE DATABASE $SNAP;" >/dev/null
            mydump "$DB" | my "$SNAP" 2>/dev/null
            ;;
    esac

    # Checksum snapshot
    log "  Calculating checksums..."
    case "$DB_TYPE" in
        pgsql)
            pgq "$SNAP" "SELECT tablename FROM pg_tables WHERE schemaname = 'public' ORDER BY tablename;" | while IFS= read -r table; do
                [ -z "$table" ] && continue
                cs=$(pgq "$SNAP" "SELECT md5(COALESCE(string_agg(md5(t::text), ''), '')) FROM (SELECT * FROM \"$table\" ORDER BY 1) t;")
                echo "${DB}.${table}|${cs}"
            done >> "$CHECKSUM_FILE"
            ;;
        mysql|mariadb)
            TABLES=$(myq "$SNAP" "SELECT table_name FROM information_schema.tables WHERE table_schema = '$SNAP' ORDER BY table_name;")
            if [ -n "$TABLES" ]; then
                TABLE_LIST=$(echo "$TABLES" | sed "s/^/${SNAP}./" | tr '\n' ',' | sed 's/,$//')
                myq "" "CHECKSUM TABLE ${TABLE_LIST};" | sed "s/${SNAP}\./${DB}./" >> "$CHECKSUM_FILE"
            fi
            ;;
    esac

    # Dump snapshot
    DUMP_FILE="$TMPDIR/${DB_TYPE}_${SNAP}_${DB_HOST}_${NOW}.sql"
    log "  Dumping snapshot..."
    case "$DB_TYPE" in
        pgsql)
            PGPASSWORD="$DB_PASS" pg_dump -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" "$SNAP" > "$DUMP_FILE"
            ;;
        mysql|mariadb)
            mydump "$SNAP" > "$DUMP_FILE"
            ;;
    esac

    # Compress
    case "$COMPRESSION" in
        zstd) zstd -q --rm "$DUMP_FILE"; DUMP_FILE="${DUMP_FILE}.zst" ;;
        gzip) gzip "$DUMP_FILE"; DUMP_FILE="${DUMP_FILE}.gz" ;;
        xz)   xz "$DUMP_FILE"; DUMP_FILE="${DUMP_FILE}.xz" ;;
    esac

    # Generate MD5
    BASENAME=$(basename "$DUMP_FILE")
    md5sum "$DUMP_FILE" | awk '{print $1}' > "${DUMP_FILE}.md5"

    # Upload
    log "  Uploading to s3://${S3_BUCKET}/${S3_PATH}/${BASENAME}"
    aws s3 cp "$DUMP_FILE" "s3://${S3_BUCKET}/${S3_PATH}/${BASENAME}" --quiet
    aws s3 cp "${DUMP_FILE}.md5" "s3://${S3_BUCKET}/${S3_PATH}/${BASENAME}.md5" --quiet

    rm -f "$DUMP_FILE" "${DUMP_FILE}.md5"
done

TABLE_COUNT=$(wc -l < "$CHECKSUM_FILE")
log "Backup complete: $(echo $DB_LIST | wc -w) databases, ${TABLE_COUNT} tables"

# --- Retention cleanup ---
if [ "$RETENTION_DAYS" -gt 0 ]; then
    log "Cleaning up backups older than ${RETENTION_DAYS} days..."
    CUTOFF=$(date -d "-${RETENTION_DAYS} days" +%Y-%m-%d 2>/dev/null || date -v-${RETENTION_DAYS}d +%Y-%m-%d 2>/dev/null)
    if [ -n "$CUTOFF" ]; then
        aws s3 ls "s3://${S3_BUCKET}/${S3_PATH}/" | while read -r line; do
            FILE_DATE=$(echo "$line" | awk '{print $1}')
            FILE_NAME=$(echo "$line" | awk '{print $4}')
            [ -z "$FILE_NAME" ] && continue
            if [[ "$FILE_DATE" < "$CUTOFF" ]]; then
                aws s3 rm "s3://${S3_BUCKET}/${S3_PATH}/${FILE_NAME}" --quiet
            fi
        done
    fi
fi

# --- Verification ---
if [ "$VERIFY_DAY" = "NONE" ]; then
    log "Verification disabled, cleaning up snapshots"
elif [ "$VERIFY_DAY" != "ALL" ] && ! echo "$VERIFY_DAY" | grep -qiw "$TODAY"; then
    log "Skipping verification (today is ${TODAY}, verify day is ${VERIFY_DAY})"
else
    log "Starting restore verification..."

    # Detect DB version
    case "$DB_TYPE" in
        pgsql)   DB_VERSION=$(pgq postgres "SHOW server_version;" | cut -d. -f1) ;;
        mysql)   DB_VERSION=$(myq "" "SELECT VERSION();" | cut -d. -f1-2) ;;
        mariadb) DB_VERSION=$(myq "" "SELECT VERSION();" | cut -d. -f1-2 | sed 's/-.*//') ;;
    esac

    # Start test container
    DOCKER_CONTAINER=""
    if [ "$VERIFY_MODE" = "docker" ]; then
        case "$DB_TYPE" in
            pgsql)
                DOCKER_IMAGE="${TEST_DOCKER_IMAGE:-postgres:${DB_VERSION:-16}-alpine}"
                DOCKER_CONTAINER="test-restore-pgsql-$$"
                docker rm -f "$DOCKER_CONTAINER" >/dev/null 2>&1 || true
                docker run -d --name "$DOCKER_CONTAINER" \
                    -e POSTGRES_USER=test_user -e POSTGRES_PASSWORD=test_pass -e POSTGRES_DB=postgres \
                    --tmpfs /var/lib/postgresql/data "$DOCKER_IMAGE" >/dev/null
                TEST_DB_HOST=$(docker inspect -f '{{range.NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$DOCKER_CONTAINER")
                TEST_DB_PORT=5432; TEST_DB_USER=test_user; TEST_DB_PASS=test_pass
                log "  Waiting for PostgreSQL ($DOCKER_IMAGE)..."
                for i in $(seq 1 30); do
                    PGPASSWORD="$TEST_DB_PASS" psql -h "$TEST_DB_HOST" -p "$TEST_DB_PORT" -U "$TEST_DB_USER" -d postgres -c "SELECT 1;" >/dev/null 2>&1 && break
                    sleep 1
                done
                ;;
            mysql)
                DOCKER_IMAGE="${TEST_DOCKER_IMAGE:-mysql:${DB_VERSION:-8.0}}"
                DOCKER_CONTAINER="test-restore-mysql-$$"
                docker rm -f "$DOCKER_CONTAINER" >/dev/null 2>&1 || true
                docker run -d --name "$DOCKER_CONTAINER" \
                    -e MYSQL_ROOT_PASSWORD=test_pass --tmpfs /var/lib/mysql "$DOCKER_IMAGE" >/dev/null
                TEST_DB_HOST=$(docker inspect -f '{{range.NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$DOCKER_CONTAINER")
                TEST_DB_PORT=3306; TEST_DB_USER=root; TEST_DB_PASS=test_pass
                log "  Waiting for MySQL ($DOCKER_IMAGE)..."
                for i in $(seq 1 60); do
                    $MYSQL_CMD -h "$TEST_DB_HOST" -P "$TEST_DB_PORT" -u "$TEST_DB_USER" -p"$TEST_DB_PASS" -e "SELECT 1;" >/dev/null 2>&1 && break
                    sleep 1
                done
                ;;
            mariadb)
                DOCKER_IMAGE="${TEST_DOCKER_IMAGE:-mariadb:${DB_VERSION:-11}}"
                DOCKER_CONTAINER="test-restore-mariadb-$$"
                docker rm -f "$DOCKER_CONTAINER" >/dev/null 2>&1 || true
                docker run -d --name "$DOCKER_CONTAINER" \
                    -e MARIADB_ROOT_PASSWORD=test_pass --tmpfs /var/lib/mysql "$DOCKER_IMAGE" >/dev/null
                TEST_DB_HOST=$(docker inspect -f '{{range.NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$DOCKER_CONTAINER")
                TEST_DB_PORT=3306; TEST_DB_USER=root; TEST_DB_PASS=test_pass
                log "  Waiting for MariaDB ($DOCKER_IMAGE)..."
                for i in $(seq 1 60); do
                    $MYSQL_CMD -h "$TEST_DB_HOST" -P "$TEST_DB_PORT" -u "$TEST_DB_USER" -p"$TEST_DB_PASS" -e "SELECT 1;" >/dev/null 2>&1 && break
                    sleep 1
                done
                ;;
        esac
    elif [ "$VERIFY_MODE" = "external" ]; then
        : "${TEST_DB_HOST:?TEST_DB_HOST required for external verify}"
        : "${TEST_DB_PORT:?TEST_DB_PORT required}"
        : "${TEST_DB_USER:?TEST_DB_USER required}"
        : "${TEST_DB_PASS:?TEST_DB_PASS required}"
    fi

    # Test helpers for the test DB
    tpg() { PGPASSWORD="$TEST_DB_PASS" psql -h "$TEST_DB_HOST" -p "$TEST_DB_PORT" -U "$TEST_DB_USER" "$@"; }
    tpgq() { tpg -d "${1:-postgres}" -t -A -c "$2"; }
    tmy() { $MYSQL_CMD -h "$TEST_DB_HOST" -P "$TEST_DB_PORT" -u "$TEST_DB_USER" -p"$TEST_DB_PASS" "$@"; }
    tmyq() { tmy ${1:+"$1"} -sN -e "$2" 2>/dev/null; }

    TEST_DB_NAME=test_restore_db
    TOTAL_DIFF=0
    TOTAL_TABLES=0

    # Find latest snapshot backup per DB in S3
    for DB in $DB_LIST; do
        SNAP="${DB}_snapshot"
        BACKUP_FILE=$(aws s3 ls "s3://${S3_BUCKET}/${S3_PATH}/" | grep "${SNAP}_" | grep -v '\.md5$' | grep -v '\.verified$' | sort | tail -1 | awk '{print $4}')

        if [ -z "$BACKUP_FILE" ]; then
            log "  ✗ No backup found for $SNAP"
            TOTAL_DIFF=$((TOTAL_DIFF + 1))
            continue
        fi

        log "  --- Verifying $DB ($BACKUP_FILE) ---"

        # Download
        aws s3 cp "s3://${S3_BUCKET}/${S3_PATH}/${BACKUP_FILE}" "$TMPDIR/restore.compressed" --quiet
        aws s3 cp "s3://${S3_BUCKET}/${S3_PATH}/${BACKUP_FILE}.md5" "$TMPDIR/restore.md5" --quiet 2>/dev/null || true

        # MD5 check
        if [ -f "$TMPDIR/restore.md5" ]; then
            EXPECTED=$(cat "$TMPDIR/restore.md5")
            ACTUAL=$(md5sum "$TMPDIR/restore.compressed" | awk '{print $1}')
            if [ "$EXPECTED" = "$ACTUAL" ]; then
                log "  ✓ MD5 verified"
            else
                log "  ✗ MD5 mismatch"
                TOTAL_DIFF=$((TOTAL_DIFF + 1))
                rm -f "$TMPDIR"/restore.*
                continue
            fi
        fi

        # Decompress
        rm -f "$TMPDIR/restore.sql"
        case "$BACKUP_FILE" in
            *.zst) zstd -dq "$TMPDIR/restore.compressed" -o "$TMPDIR/restore.sql" ;;
            *.gz)  gunzip -c "$TMPDIR/restore.compressed" > "$TMPDIR/restore.sql" ;;
            *.xz)  unxz -c "$TMPDIR/restore.compressed" > "$TMPDIR/restore.sql" ;;
            *)     mv "$TMPDIR/restore.compressed" "$TMPDIR/restore.sql" ;;
        esac

        # Restore + checksum
        case "$DB_TYPE" in
            pgsql)
                tpgq postgres "DROP DATABASE IF EXISTS $TEST_DB_NAME;" >/dev/null
                tpgq postgres "CREATE DATABASE $TEST_DB_NAME;" >/dev/null
                tpg -d "$TEST_DB_NAME" < "$TMPDIR/restore.sql" >/dev/null 2>&1
                tpgq "$TEST_DB_NAME" "SELECT tablename FROM pg_tables WHERE schemaname = 'public' ORDER BY tablename;" | while IFS= read -r table; do
                    [ -z "$table" ] && continue
                    cs=$(tpgq "$TEST_DB_NAME" "SELECT md5(COALESCE(string_agg(md5(t::text), ''), '')) FROM (SELECT * FROM \"$table\" ORDER BY 1) t;")
                    echo "${DB}.${table}|${cs}"
                done > "$TMPDIR/restored_checksums.txt"
                ;;
            mysql|mariadb)
                tmyq "" "DROP DATABASE IF EXISTS $TEST_DB_NAME;" >/dev/null
                tmyq "" "CREATE DATABASE $TEST_DB_NAME;" >/dev/null
                tmy "$TEST_DB_NAME" < "$TMPDIR/restore.sql" 2>/dev/null
                TABLES=$(tmyq "$TEST_DB_NAME" "SELECT table_name FROM information_schema.tables WHERE table_schema = '$TEST_DB_NAME' ORDER BY table_name;")
                if [ -n "$TABLES" ]; then
                    TABLE_LIST=$(echo "$TABLES" | sed "s/^/${TEST_DB_NAME}./" | tr '\n' ',' | sed 's/,$//')
                    tmyq "" "CHECKSUM TABLE ${TABLE_LIST};" | sed "s/${TEST_DB_NAME}\./${DB}./" > "$TMPDIR/restored_checksums.txt"
                else
                    > "$TMPDIR/restored_checksums.txt"
                fi
                ;;
        esac

        # Compare
        MISMATCH=0
        grep "^${DB}\." "$CHECKSUM_FILE" | while IFS=$'|\t' read -r table src_cs; do
            table=$(echo "$table" | xargs); src_cs=$(echo "$src_cs" | xargs)
            [ -z "$table" ] && continue
            rst_cs=$(grep -E "^${table}[|	]" "$TMPDIR/restored_checksums.txt" 2>/dev/null | sed 's/^[^|	]*//' | tr -d '|\t' | xargs)
            if [ "$src_cs" != "$rst_cs" ]; then
                log "  ✗ Checksum mismatch: $table"
                log "    Source:   $src_cs"
                log "    Restored: $rst_cs"
                echo "MISMATCH"
            fi
        done > "$TMPDIR/mismatches.txt"
        MISMATCH=$(wc -l < "$TMPDIR/mismatches.txt")

        DB_TABLE_COUNT=$(grep -c "^${DB}\." "$CHECKSUM_FILE" 2>/dev/null || echo 0)
        TOTAL_TABLES=$((TOTAL_TABLES + DB_TABLE_COUNT))

        if [ "$MISMATCH" -eq 0 ]; then
            log "  ✓ $DB: All $DB_TABLE_COUNT table checksums match"
            echo "verified=$(date -u +%Y-%m-%dT%H:%M:%SZ) tables=$DB_TABLE_COUNT" | \
                aws s3 cp - "s3://${S3_BUCKET}/${S3_PATH}/${BACKUP_FILE}.verified" --quiet 2>/dev/null || true
        else
            log "  ✗ $DB: $MISMATCH table(s) have checksum mismatches"
            TOTAL_DIFF=$((TOTAL_DIFF + MISMATCH))
        fi

        # Cleanup test DB
        case "$DB_TYPE" in
            pgsql)   tpgq postgres "DROP DATABASE IF EXISTS $TEST_DB_NAME;" >/dev/null 2>&1 || true ;;
            mysql|mariadb) tmyq "" "DROP DATABASE IF EXISTS $TEST_DB_NAME;" >/dev/null 2>&1 || true ;;
        esac
        rm -f "$TMPDIR"/restore.* "$TMPDIR"/restored_checksums.txt "$TMPDIR"/mismatches.txt
    done

    # Cleanup test container
    if [ -n "$DOCKER_CONTAINER" ]; then
        log "Removing test container..."
        docker rm -f "$DOCKER_CONTAINER" >/dev/null 2>&1 || true
    fi

    if [ "$TOTAL_DIFF" -eq 0 ]; then
        log "✓ Verification PASSED — $TOTAL_TABLES tables across $(echo $DB_LIST | wc -w) databases"
    else
        log "✗ Verification FAILED — $TOTAL_DIFF issue(s)"
        # Clean up snapshots before exiting
        for DB in $DB_LIST; do
            case "$DB_TYPE" in
                pgsql)   pgq postgres "DROP DATABASE IF EXISTS ${DB}_snapshot;" >/dev/null 2>&1 || true ;;
                mysql|mariadb) myq "" "DROP DATABASE IF EXISTS ${DB}_snapshot;" >/dev/null 2>&1 || true ;;
            esac
        done
        exit 1
    fi
fi

# --- Clean up snapshots ---
log "Cleaning up snapshots..."
for DB in $DB_LIST; do
    case "$DB_TYPE" in
        pgsql)   pgq postgres "DROP DATABASE IF EXISTS ${DB}_snapshot;" >/dev/null 2>&1 || true ;;
        mysql|mariadb) myq "" "DROP DATABASE IF EXISTS ${DB}_snapshot;" >/dev/null 2>&1 || true ;;
    esac
done

log "Done."
