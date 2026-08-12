#!/usr/bin/env bash
# Migrate one Evolution API WhatsApp instance (Postgres + Redis auth hash).
#
# Auth layout (CACHE_REDIS_ENABLED=true, SAVE_INSTANCES=false):
#   creds  -> Postgres "Session"
#   keys   -> Redis DB N hash "{PREFIX}:instance:{instanceId}"
# Always rewrite Instance.clientName to TARGET_CLIENT_NAME.
#
# Usage:
#   ./scripts/migrate-instance.sh whats2iphone
#   ./scripts/migrate-instance.sh --dry-run whats2iphone
#   ./scripts/migrate-instance.sh --export-only whats2iphone
#
# Defaults assume local Docker containers "postgres"/"redis" -> VPS /opt/evoapi-fluxosmm

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

MODE="migrate"
INSTANCE_NAME=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) MODE="dry-run"; shift ;;
    --export-only) MODE="export-only"; shift ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *) INSTANCE_NAME="$1"; shift ;;
  esac
done

[[ -n "$INSTANCE_NAME" ]] || { echo "Usage: $0 [--dry-run|--export-only] <instanceName>" >&2; exit 1; }

SOURCE_REDIS_CONTAINER="${SOURCE_REDIS_CONTAINER:-redis}"
SOURCE_REDIS_DB="${SOURCE_REDIS_DB:-6}"
SOURCE_REDIS_PREFIX="${SOURCE_REDIS_PREFIX:-evolution}"
SOURCE_PG_CONTAINER="${SOURCE_PG_CONTAINER:-postgres}"
SOURCE_PG_USER="${SOURCE_PG_USER:-evolution}"
SOURCE_PG_DB="${SOURCE_PG_DB:-evolution_db}"
SOURCE_PG_SCHEMA="${SOURCE_PG_SCHEMA:-evolution_api}"

TARGET_CLIENT_NAME="${TARGET_CLIENT_NAME:-evolution_evoapi}"
TARGET_REDIS_PREFIX="${TARGET_REDIS_PREFIX:-evolution_evoapi}"
TARGET_REDIS_DB="${TARGET_REDIS_DB:-6}"

REMOTE_USER="${REMOTE_USER:-root}"
REMOTE_HOST="${REMOTE_HOST:-109.123.249.187}"
REMOTE_DIR="${REMOTE_DIR:-/opt/evoapi-fluxosmm}"

WORK_DIR="${WORK_DIR:-/tmp/evo-migrate-${INSTANCE_NAME}}"
mkdir -p "$WORK_DIR"

need() { command -v "$1" >/dev/null 2>&1 || { echo "Missing: $1" >&2; exit 1; }; }
need docker
need python3

echo "==> Mode=$MODE instance=$INSTANCE_NAME work=$WORK_DIR"

psql_local() {
  docker exec "$SOURCE_PG_CONTAINER" psql -U "$SOURCE_PG_USER" -d "$SOURCE_PG_DB" -At -c \
    "SET search_path TO \"${SOURCE_PG_SCHEMA}\", public; $1"
}

INSTANCE_ID="$(psql_local "SELECT id FROM \"Instance\" WHERE name = '${INSTANCE_NAME}' LIMIT 1;")"
[[ -n "$INSTANCE_ID" ]] || { echo "Instance not found: $INSTANCE_NAME" >&2; exit 1; }
echo "==> instanceId=$INSTANCE_ID"

SRC_HASH="${SOURCE_REDIS_PREFIX}:instance:${INSTANCE_ID}"
DST_HASH="${TARGET_REDIS_PREFIX}:instance:${INSTANCE_ID}"

export_local() {
  echo "==> Export Postgres"
  psql_local "SELECT row_to_json(i) FROM \"Instance\" i WHERE id = '${INSTANCE_ID}';" > "$WORK_DIR/instance.json"
  psql_local "SELECT COALESCE(json_agg(row_to_json(s)), '[]'::json) FROM \"Session\" s WHERE \"sessionId\" = '${INSTANCE_ID}';" > "$WORK_DIR/session.json"
  psql_local "SELECT COALESCE(row_to_json(s), 'null'::json) FROM \"Setting\" s WHERE \"instanceId\" = '${INSTANCE_ID}' LIMIT 1;" > "$WORK_DIR/setting.json"
  psql_local "SELECT COALESCE(row_to_json(p), 'null'::json) FROM \"Proxy\" p WHERE \"instanceId\" = '${INSTANCE_ID}' LIMIT 1;" > "$WORK_DIR/proxy.json" 2>/dev/null || echo 'null' > "$WORK_DIR/proxy.json"

  python3 - <<PY
import json
from pathlib import Path
p = Path("$WORK_DIR/instance.json")
obj = json.loads(p.read_text().strip())
obj["clientName"] = "$TARGET_CLIENT_NAME"
p.write_text(json.dumps(obj))
print("clientName ->", obj["clientName"])
PY

  echo "==> Export Redis DUMP $SRC_HASH (db $SOURCE_REDIS_DB)"
  FIELDS="$(docker exec "$SOURCE_REDIS_CONTAINER" redis-cli -n "$SOURCE_REDIS_DB" HLEN "$SRC_HASH")"
  echo "    fields=$FIELDS"
  docker exec "$SOURCE_REDIS_CONTAINER" sh -c \
    "redis-cli -n ${SOURCE_REDIS_DB} --raw DUMP '${SRC_HASH}' | base64" \
    > "$WORK_DIR/redis_hash.b64"
  printf '%s\n' "$DST_HASH" > "$WORK_DIR/dst_hash.txt"
  printf '%s\n' "$TARGET_REDIS_DB" > "$WORK_DIR/dst_db.txt"
  printf '%s\n' "$INSTANCE_ID" > "$WORK_DIR/instance_id.txt"
  printf '%s\n' "$INSTANCE_NAME" > "$WORK_DIR/instance_name.txt"
}

import_remote() {
  need ssh
  need scp
  echo "==> Upload + import on ${REMOTE_HOST}:${REMOTE_DIR}"
  ssh -o StrictHostKeyChecking=accept-new "${REMOTE_USER}@${REMOTE_HOST}" "mkdir -p /tmp/evo-migrate"
  scp -o StrictHostKeyChecking=accept-new -q \
    "$WORK_DIR"/{instance.json,session.json,setting.json,proxy.json,redis_hash.b64,dst_hash.txt,dst_db.txt,instance_id.txt,instance_name.txt} \
    "${REMOTE_USER}@${REMOTE_HOST}:/tmp/evo-migrate/"

  # Ship importer script to avoid fragile nested heredocs
  scp -o StrictHostKeyChecking=accept-new -q \
    "$ROOT_DIR/scripts/_migrate_remote_import.py" \
    "${REMOTE_USER}@${REMOTE_HOST}:/tmp/evo-migrate/import.py"

  ssh -o StrictHostKeyChecking=accept-new "${REMOTE_USER}@${REMOTE_HOST}" \
    "REMOTE_DIR='${REMOTE_DIR}' python3 /tmp/evo-migrate/import.py"
}

case "$MODE" in
  dry-run|export-only)
    export_local
    echo "==> Export OK ($MODE) -> $WORK_DIR"
    ;;
  migrate)
    export_local
    import_remote
    echo "==> Migrate finished. If connectionState != open, pair QR again (IP change)."
    ;;
esac
