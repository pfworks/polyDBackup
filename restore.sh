#!/bin/bash
set -euo pipefail

# Usage: db-restore [--globals] [--verified] [backup_file] [target_db_name]

CONF="${DB_BACKUP_CONF:-/etc/db-backup/db-backup.conf}"
if [ -f "$CONF" ]; then
    set -a; source "$CONF"; set +a
fi

: "${DB_TYPE:?DB_TYPE required}"
: "${DB_HOST:?DB_HOST required}"
: "${DB_PORT:?DB_PORT required}"
: "${DB_USER:?DB_USER required}"
: "${DB_PASS:?DB_PASS required}"
: "${S3_BUCKET:?S3_BUCKET required}"
: "${S3_PATH:?S3_PATH required}"
: "${S3_REGION:=us-east-1}"

export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_DEFAULT_REGION="$S3_REGION"

case "$DB_TYPE" in
    mariadb) MYSQL_CMD=mariadb ;;
    mysql)   MYSQL_CMD=mysql ;;
esac

SHOW_VERIFIED_ONLY=false
GLOBALS_MODE=false
[ "${1:-}" = "--globals" ] && { GLOBALS_MODE=true; shift; }
[ "${1:-}" = "--verified" ] && { SHOW_VERIFIED_ONLY=true; shift; }

# --- Globals restore (download, decrypt, decompress only) ---
if [ "$GLOBALS_MODE" = true ]; then
    echo "Available globals backups in s3://${S3_BUCKET}/${S3_PATH}/:"
    echo ""
    BACKUPS=$(aws s3 ls "s3://${S3_BUCKET}/${S3_PATH}/" | grep '_globals_' | grep -v '\.md5$' | sort)
    [ -z "$BACKUPS" ] && { echo "No globals backups found."; exit 1; }

    i=1
    while IFS= read -r line; do
        FILE=$(echo "$line" | awk '{print $4}')
        SIZE=$(echo "$line" | awk '{print $3}')
        echo "  ${i}) ${FILE}  ${SIZE}"
        i=$((i + 1))
    done <<< "$BACKUPS"

    echo ""
    read -p "Select backup number (or 'q' to quit): " SELECTION
    [ "$SELECTION" = "q" ] && exit 0
    GLOBALS_FILE=$(echo "$BACKUPS" | sed -n "${SELECTION}p" | awk '{print $4}')
    [ -z "$GLOBALS_FILE" ] && { echo "Invalid selection."; exit 1; }

    TMPDIR=$(mktemp -d)
    trap 'rm -rf "$TMPDIR"' EXIT

    echo "Downloading ${GLOBALS_FILE}..."
    aws s3 cp "s3://${S3_BUCKET}/${S3_PATH}/${GLOBALS_FILE}" "$TMPDIR/${GLOBALS_FILE}"

    OUTFILE="$TMPDIR/${GLOBALS_FILE}"

    # Decrypt
    if echo "$OUTFILE" | grep -q '\.enc$'; then
        [ -z "${ENCRYPT_KEY:-}" ] && { echo "ENCRYPT_KEY required to decrypt."; exit 1; }
        openssl enc -d -aes-256-cbc -salt -pbkdf2 -pass env:ENCRYPT_KEY -in "$OUTFILE" -out "${OUTFILE%.enc}"
        OUTFILE="${OUTFILE%.enc}"
    fi

    # Decompress
    case "$OUTFILE" in
        *.zst) zstd -dq "$OUTFILE" -o "${OUTFILE%.zst}"; OUTFILE="${OUTFILE%.zst}" ;;
        *.gz)  gunzip -c "$OUTFILE" > "${OUTFILE%.gz}"; OUTFILE="${OUTFILE%.gz}" ;;
        *.xz)  unxz -c "$OUTFILE" > "${OUTFILE%.xz}"; OUTFILE="${OUTFILE%.xz}" ;;
    esac

    DEST="./$(basename "$OUTFILE")"
    cp "$OUTFILE" "$DEST"
    echo ""
    echo "Globals saved to: ${DEST}"
    echo "Review the file and apply manually, e.g.:"
    case "$DB_TYPE" in
        pgsql)       echo "  PGPASSWORD=\$DB_PASS psql -h $DB_HOST -p $DB_PORT -U $DB_USER -d postgres < ${DEST}" ;;
        mysql|mariadb) echo "  mysql -h $DB_HOST -P $DB_PORT -u $DB_USER -p < ${DEST}" ;;
    esac
    exit 0
fi

# --- Select backup ---
if [ -n "${1:-}" ]; then
    BACKUP_FILE="$1"
else
    echo "Available backups in s3://${S3_BUCKET}/${S3_PATH}/:"
    echo ""
    BACKUPS=$(aws s3 ls "s3://${S3_BUCKET}/${S3_PATH}/" | grep -v '\.\(md5\|verified\)$' | grep "${SNAP_SUFFIX:=_polydbackup}" | sort)
    [ -z "$BACKUPS" ] && { echo "No backups found."; exit 1; }

    VERIFIED_LIST=$(aws s3 ls "s3://${S3_BUCKET}/${S3_PATH}/" | grep '\.verified$' | awk '{print $4}' | sed 's/\.verified$//')

    i=1
    while IFS= read -r line; do
        FILE=$(echo "$line" | awk '{print $4}')
        SIZE=$(echo "$line" | awk '{print $3}')
        if echo "$VERIFIED_LIST" | grep -qx "$FILE"; then
            STATUS="✓ verified"
        else
            [ "$SHOW_VERIFIED_ONLY" = true ] && continue
            STATUS="  unverified"
        fi
        echo "  ${i}) ${FILE}  ${SIZE}  [${STATUS}]"
        i=$((i + 1))
    done <<< "$BACKUPS"

    echo ""
    read -p "Select backup number (or 'q' to quit): " SELECTION
    [ "$SELECTION" = "q" ] && exit 0
    BACKUP_FILE=$(echo "$BACKUPS" | sed -n "${SELECTION}p" | awk '{print $4}')
    [ -z "$BACKUP_FILE" ] && { echo "Invalid selection."; exit 1; }
fi

# --- Target database ---
if [ -n "${2:-}" ]; then
    TARGET_DB="$2"
else
    read -p "Enter target database name: " TARGET_DB
    [ -z "$TARGET_DB" ] && { echo "No target specified."; exit 1; }
fi

echo "$TARGET_DB" | grep -qE '^[a-zA-Z_][a-zA-Z0-9_]*$' || { echo "Invalid database name."; exit 1; }

echo ""
echo "  Backup:  $BACKUP_FILE"
echo "  Target:  $TARGET_DB"
echo "  Host:    ${DB_HOST}:${DB_PORT}"
echo ""
read -p "Restore to '${TARGET_DB}'? Type 'yes' to confirm: " CONFIRM
[ "$CONFIRM" != "yes" ] && { echo "Aborted."; exit 0; }

# --- Download + verify ---
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

aws s3 cp "s3://${S3_BUCKET}/${S3_PATH}/${BACKUP_FILE}" "$TMPDIR/restore.compressed"
aws s3 cp "s3://${S3_BUCKET}/${S3_PATH}/${BACKUP_FILE}.md5" "$TMPDIR/restore.md5" 2>/dev/null || true

if [ -f "$TMPDIR/restore.md5" ]; then
    EXPECTED=$(cat "$TMPDIR/restore.md5")
    ACTUAL=$(md5sum "$TMPDIR/restore.compressed" | awk '{print $1}')
    if [ "$EXPECTED" = "$ACTUAL" ]; then
        echo "✓ MD5 verified"
    else
        echo "✗ MD5 mismatch!"; exit 1
    fi
fi

# --- Decompress ---
case "$BACKUP_FILE" in
    *.zst) zstd -dq "$TMPDIR/restore.compressed" -o "$TMPDIR/restore.sql" ;;
    *.gz)  gunzip -c "$TMPDIR/restore.compressed" > "$TMPDIR/restore.sql" ;;
    *.xz)  unxz -c "$TMPDIR/restore.compressed" > "$TMPDIR/restore.sql" ;;
    *)     mv "$TMPDIR/restore.compressed" "$TMPDIR/restore.sql" ;;
esac

# --- Restore ---
case "$DB_TYPE" in
    pgsql)
        PGPASSWORD="$DB_PASS" psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d postgres -c "DROP DATABASE IF EXISTS $TARGET_DB;"
        PGPASSWORD="$DB_PASS" psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d postgres -c "CREATE DATABASE $TARGET_DB;"
        PGPASSWORD="$DB_PASS" psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$TARGET_DB" < "$TMPDIR/restore.sql"
        TC=$(PGPASSWORD="$DB_PASS" psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$TARGET_DB" -t -A -c "SELECT COUNT(*) FROM pg_tables WHERE schemaname = 'public';")
        ;;
    mysql|mariadb)
        $MYSQL_CMD -h "$DB_HOST" -P "$DB_PORT" -u "$DB_USER" -p"$DB_PASS" -e "DROP DATABASE IF EXISTS $TARGET_DB;"
        $MYSQL_CMD -h "$DB_HOST" -P "$DB_PORT" -u "$DB_USER" -p"$DB_PASS" -e "CREATE DATABASE $TARGET_DB;"
        $MYSQL_CMD -h "$DB_HOST" -P "$DB_PORT" -u "$DB_USER" -p"$DB_PASS" "$TARGET_DB" < "$TMPDIR/restore.sql"
        TC=$($MYSQL_CMD -h "$DB_HOST" -P "$DB_PORT" -u "$DB_USER" -p"$DB_PASS" -sN -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = '$TARGET_DB';")
        ;;
esac

echo "✓ Restored ${TC} tables to ${TARGET_DB}"
