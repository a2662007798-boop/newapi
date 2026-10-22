#!/usr/bin/env bash
# Nightly backup + safe update for a Docker Compose deployment using SQLite.
#
# 1. Back up the live database online (sqlite3 .backup, no downtime), check
#    its integrity, gzip it into <backup dir>/daily, keep KEEP_DAYS days.
# 2. Pull the image configured for the new-api service. No new image: exit.
# 3. Preflight: start the new image on a copy of that backup in an isolated
#    container (no network). The production database is not touched; if the
#    copy does not come up healthy, stop here.
# 4. Run the existing off-site backup script (if present); abort on failure.
# 5. Stop the service, copy the SQLite files aside, start on the new image.
# 6. If /api/status does not report success in time, move the migrated files
#    aside, put the copied database back, retag the previous image, start.
#
# Usage: nightly-update.sh [compose dir]   (default /opt/new-api)
# Env:   SERVICE (default new-api), BACKUP_DIR (default <compose dir>/backups),
#        KEEP_DAYS (default 7), PRE_BACKUP (default /root/scripts/backup-to-tencent.sh),
#        HEALTH_TIMEOUT seconds (default 900)
set -euo pipefail

COMPOSE_DIR=${1:-/opt/new-api}
SERVICE=${SERVICE:-new-api}
BACKUP_DIR=${BACKUP_DIR:-$COMPOSE_DIR/backups}
KEEP_DAYS=${KEEP_DAYS:-7}
PRE_BACKUP=${PRE_BACKUP:-/root/scripts/backup-to-tencent.sh}
HEALTH_TIMEOUT=${HEALTH_TIMEOUT:-900}
DB_FILES=(one-api.db one-api.db-wal one-api.db-shm)
PREFLIGHT=newapi-preflight
STAMP=$(date '+%Y%m%d-%H%M%S')

cd "$COMPOSE_DIR"
mkdir -p "$BACKUP_DIR"
log() { echo "[$(date '+%F %T')] $*"; }

# wait_healthy <docker exec target...>: polls /api/status until success or timeout.
wait_healthy() {
  local deadline=$((SECONDS + HEALTH_TIMEOUT))
  while [ "$SECONDS" -lt "$deadline" ]; do
    sleep 5
    if "$@" wget -q -O - http://localhost:3000/api/status 2>/dev/null | grep -q '"success":\s*true'; then
      return 0
    fi
  done
  return 1
}

exec 9>/var/run/newapi-nightly-update.lock
if ! flock -n 9; then
  log "another update is running, skip"
  exit 0
fi

CID=$(docker compose ps -q "$SERVICE")
if [ -z "$CID" ]; then
  log "service $SERVICE is not running in $COMPOSE_DIR, abort"
  exit 1
fi

# Only SQLite is handled here; refuse to migrate an external database blindly.
if docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$CID" | grep -qE '^SQL_DSN=.+'; then
  log "SQL_DSN is set: the database is not SQLite, this script cannot back it up. abort"
  exit 1
fi

DATA_DIR=$(docker inspect -f '{{range .Mounts}}{{if eq .Destination "/data"}}{{.Source}}{{end}}{{end}}' "$CID")
if [ -z "$DATA_DIR" ] || [ ! -f "$DATA_DIR/one-api.db" ]; then
  log "cannot find one-api.db in the host directory mounted at /data, abort"
  exit 1
fi
if ! command -v sqlite3 >/dev/null; then
  log "sqlite3 is required on the host (apt install -y sqlite3), abort"
  exit 1
fi

# Read the image from the compose file, not the running container, so a
# freshly edited image: line is picked up on the first run.
IMAGE=$(docker compose config --format json \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["services"][sys.argv[1]]["image"])' "$SERVICE")
OLD_IMAGE_ID=$(docker inspect -f '{{.Image}}' "$CID")
log "pulling $IMAGE"
docker compose pull -q "$SERVICE"
NEW_IMAGE_ID=$(docker image inspect -f '{{.Id}}' "$IMAGE")

# Unless the upgrade succeeds, point the compose image tag back at the running
# version on exit, so a later manual `docker compose up` never starts an
# image that was not verified.
UPGRADED=false
WORK=""
cleanup() {
  docker rm -f "$PREFLIGHT" >/dev/null 2>&1 || true
  if [ -n "$WORK" ]; then rm -rf "$WORK"; fi
  if [ "$UPGRADED" != true ]; then docker tag "$OLD_IMAGE_ID" "$IMAGE" >/dev/null 2>&1 || true; fi
}
trap cleanup EXIT

# --- Nightly backup, every run, no downtime. ---
WORK=$(mktemp -d /var/tmp/newapi-preflight.XXXXXX)
mkdir -p "$BACKUP_DIR/daily"
DAILY="$BACKUP_DIR/daily/one-api-$STAMP.db"
log "backing up the live database to $DAILY.gz"
sqlite3 "$DATA_DIR/one-api.db" ".backup '$DAILY'"
check=$(sqlite3 "$DAILY" "PRAGMA quick_check;")
if [ "$check" != "ok" ]; then
  mv "$DAILY" "$DAILY.corrupt"
  log "backup integrity check failed ($check), kept as $DAILY.corrupt; no update. check the live database"
  exit 1
fi
if [ "$OLD_IMAGE_ID" != "$NEW_IMAGE_ID" ]; then
  cp "$DAILY" "$WORK/one-api.db"
fi
gzip -f "$DAILY"
find "$BACKUP_DIR/daily" -name 'one-api-*.db.gz' -mtime +"$((KEEP_DAYS - 1))" -delete
log "backup ok ($(du -h "$DAILY.gz" | cut -f1))"

if [ "$OLD_IMAGE_ID" = "$NEW_IMAGE_ID" ]; then
  log "no new image, nothing to update"
  exit 0
fi
log "new image $NEW_IMAGE_ID (running $OLD_IMAGE_ID)"

# --- Preflight on a copy; production keeps running and is not touched. ---
docker rm -f "$PREFLIGHT" >/dev/null 2>&1 || true
log "preflight: starting the new image on a copy of the database (no network)"
started=$SECONDS
docker run -d --name "$PREFLIGHT" --network none -e TZ=Asia/Shanghai -v "$WORK:/data" "$IMAGE" >/dev/null
if ! wait_healthy docker exec "$PREFLIGHT"; then
  docker logs --tail=200 "$PREFLIGHT" > "$BACKUP_DIR/preflight-failed-$STAMP.log" 2>&1 || true
  log "preflight FAILED, production untouched. see $BACKUP_DIR/preflight-failed-$STAMP.log"
  exit 1
fi
log "preflight passed in $((SECONDS - started))s (expected downtime is about this long)"
docker rm -f "$PREFLIGHT" >/dev/null
rm -rf "$WORK"

if [ -x "$PRE_BACKUP" ]; then
  log "running off-site backup $PRE_BACKUP"
  if ! "$PRE_BACKUP"; then
    log "off-site backup failed, abort update"
    exit 1
  fi
fi

# --- Real upgrade. ---
SNAPSHOT="$BACKUP_DIR/pre-update-$STAMP"
mkdir -p "$SNAPSHOT"
log "stopping $SERVICE and copying the database to $SNAPSHOT"
docker compose stop "$SERVICE"
for f in "${DB_FILES[@]}"; do
  if [ -f "$DATA_DIR/$f" ]; then
    cp -p "$DATA_DIR/$f" "$SNAPSHOT/"
    if [ "$(stat -c%s "$DATA_DIR/$f")" != "$(stat -c%s "$SNAPSHOT/$f")" ]; then
      log "copy of $f is incomplete, starting the old version again"
      docker tag "$OLD_IMAGE_ID" "$IMAGE"
      docker compose up -d "$SERVICE"
      exit 1
    fi
  fi
done
cp -p docker-compose.yml "$SNAPSHOT/"
echo "$OLD_IMAGE_ID" > "$SNAPSHOT/previous-image-id"

docker compose up -d "$SERVICE"
if wait_healthy docker compose exec -T "$SERVICE"; then
  UPGRADED=true
  log "healthy on new image"
else
  log "health check failed, restoring $SNAPSHOT and image $OLD_IMAGE_ID"
  docker compose logs --tail=200 "$SERVICE" > "$SNAPSHOT/failed-start.log" 2>&1 || true
  docker compose stop "$SERVICE"
  mkdir -p "$SNAPSHOT/failed-migrated"
  for f in "${DB_FILES[@]}"; do
    if [ -f "$DATA_DIR/$f" ]; then mv "$DATA_DIR/$f" "$SNAPSHOT/failed-migrated/"; fi
    if [ -f "$SNAPSHOT/$f" ]; then cp -p "$SNAPSHOT/$f" "$DATA_DIR/"; fi
  done
  docker tag "$OLD_IMAGE_ID" "$IMAGE"
  docker compose up -d "$SERVICE"
  if wait_healthy docker compose exec -T "$SERVICE"; then
    log "rolled back, old version is healthy. see $SNAPSHOT/failed-start.log"
  else
    log "rolled back but the old version is NOT healthy, check manually"
  fi
  exit 1
fi

find "$BACKUP_DIR" -maxdepth 1 -name 'pre-update-*' -mtime +"$KEEP_DAYS" -exec rm -rf {} +
docker image prune -f >/dev/null
log "done"
