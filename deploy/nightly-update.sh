#!/usr/bin/env bash
# Safe update for a Docker Compose deployment using SQLite.
#
# 1. Pull the image configured for the new-api service. No new image: exit.
# 2. Preflight: take an online copy of the database (sqlite3 .backup) and start
#    the new image on that copy in an isolated container (no network). The
#    production database is not touched; if the copy does not come up
#    healthy, stop here.
# 3. Run the existing off-site backup script (if present); abort on failure.
# 4. Stop the service, copy the SQLite files aside, start on the new image.
# 5. If /api/status does not report success in time, move the migrated files
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
if [ "$OLD_IMAGE_ID" = "$NEW_IMAGE_ID" ]; then
  log "no new image, nothing to do"
  exit 0
fi
log "new image $NEW_IMAGE_ID (running $OLD_IMAGE_ID)"

# --- Preflight on a copy; production keeps running and is not touched. ---
WORK=$(mktemp -d /var/tmp/newapi-preflight.XXXXXX)
trap 'docker rm -f "$PREFLIGHT" >/dev/null 2>&1 || true; rm -rf "$WORK"' EXIT
docker rm -f "$PREFLIGHT" >/dev/null 2>&1 || true

log "preflight: copying the live database to $WORK"
sqlite3 "$DATA_DIR/one-api.db" ".backup '$WORK/one-api.db'"
log "preflight: starting the new image on the copy (no network)"
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
      docker compose up -d "$SERVICE"
      exit 1
    fi
  fi
done
cp -p docker-compose.yml "$SNAPSHOT/"
echo "$OLD_IMAGE_ID" > "$SNAPSHOT/previous-image-id"

docker compose up -d "$SERVICE"
if wait_healthy docker compose exec -T "$SERVICE"; then
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
