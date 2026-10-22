#!/usr/bin/env bash
# Nightly update for a Docker Compose deployment using SQLite.
#
# 1. Pull the image configured for the new-api service. No new image: exit,
#    the service is not touched.
# 2. Run the existing off-site backup script (if present); abort on failure.
# 3. Stop the service, copy the SQLite files aside, start on the new image.
# 4. If /api/status does not report success in time, restore the copied
#    database and the previous image, then start again.
#
# Usage: nightly-update.sh [compose dir]   (default /opt/new-api)
# Env:   SERVICE (default new-api), BACKUP_DIR (default <compose dir>/backups),
#        KEEP_DAYS (default 7), PRE_BACKUP (default /root/scripts/backup-to-tencent.sh),
#        HEALTH_TIMEOUT seconds (default 600)
set -euo pipefail

COMPOSE_DIR=${1:-/opt/new-api}
SERVICE=${SERVICE:-new-api}
BACKUP_DIR=${BACKUP_DIR:-$COMPOSE_DIR/backups}
KEEP_DAYS=${KEEP_DAYS:-7}
PRE_BACKUP=${PRE_BACKUP:-/root/scripts/backup-to-tencent.sh}
HEALTH_TIMEOUT=${HEALTH_TIMEOUT:-600}
DB_FILES=(one-api.db one-api.db-wal one-api.db-shm)

cd "$COMPOSE_DIR"
mkdir -p "$BACKUP_DIR"
log() { echo "[$(date '+%F %T')] $*"; }

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

if [ -x "$PRE_BACKUP" ]; then
  log "running off-site backup $PRE_BACKUP"
  if ! "$PRE_BACKUP"; then
    log "off-site backup failed, abort update"
    exit 1
  fi
fi

SNAPSHOT="$BACKUP_DIR/pre-update-$(date '+%Y%m%d-%H%M%S')"
mkdir -p "$SNAPSHOT"
log "stopping $SERVICE and copying the database to $SNAPSHOT"
docker compose stop "$SERVICE"
for f in "${DB_FILES[@]}"; do
  if [ -f "$DATA_DIR/$f" ]; then cp -p "$DATA_DIR/$f" "$SNAPSHOT/"; fi
done
cp -p docker-compose.yml "$SNAPSHOT/"
echo "$OLD_IMAGE_ID" > "$SNAPSHOT/previous-image-id"

docker compose up -d "$SERVICE"

# Database migrations on a large SQLite file can take minutes after a big jump.
healthy=false
deadline=$((SECONDS + HEALTH_TIMEOUT))
while [ "$SECONDS" -lt "$deadline" ]; do
  sleep 5
  if docker compose exec -T "$SERVICE" wget -q -O - http://localhost:3000/api/status 2>/dev/null \
      | grep -q '"success":\s*true'; then
    healthy=true
    break
  fi
done

if [ "$healthy" = true ]; then
  log "healthy on new image"
else
  log "health check failed, restoring $SNAPSHOT and image $OLD_IMAGE_ID"
  docker compose logs --tail=80 "$SERVICE" > "$SNAPSHOT/failed-start.log" 2>&1 || true
  docker compose stop "$SERVICE"
  for f in "${DB_FILES[@]}"; do
    rm -f "$DATA_DIR/$f"
    if [ -f "$SNAPSHOT/$f" ]; then cp -p "$SNAPSHOT/$f" "$DATA_DIR/"; fi
  done
  docker tag "$OLD_IMAGE_ID" "$IMAGE"
  docker compose up -d "$SERVICE"
  log "rolled back, see $SNAPSHOT/failed-start.log"
  exit 1
fi

find "$BACKUP_DIR" -maxdepth 1 -name 'pre-update-*' -mtime +"$KEEP_DAYS" -exec rm -rf {} +
docker image prune -f >/dev/null
log "done"
