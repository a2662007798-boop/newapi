#!/usr/bin/env bash
# Nightly backup + update for a Docker Compose deployment using SQLite.
#
# 1. Pull the image used by the new-api service.
# 2. Stop the service briefly and archive its /data directory (SQLite DB).
# 3. Start the service (on the new image if one was pulled).
# 4. If /api/status does not report success, restore the backup and the
#    previous image, then start again.
#
# Usage: nightly-update.sh /path/to/compose/dir
# Env:   SERVICE (default new-api), BACKUP_DIR (default <compose dir>/backups),
#        KEEP_DAYS (default 14)
set -euo pipefail

COMPOSE_DIR=${1:?usage: nightly-update.sh /path/to/compose/dir}
SERVICE=${SERVICE:-new-api}
BACKUP_DIR=${BACKUP_DIR:-$COMPOSE_DIR/backups}
KEEP_DAYS=${KEEP_DAYS:-14}

cd "$COMPOSE_DIR"
mkdir -p "$BACKUP_DIR"
log() { echo "[$(date '+%F %T')] $*"; }

CID=$(docker compose ps -q "$SERVICE")
if [ -z "$CID" ]; then
  log "service $SERVICE is not running in $COMPOSE_DIR, abort"
  exit 1
fi

# Only SQLite is backed up here; refuse to update an external database blindly.
if docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$CID" | grep -qE '^SQL_DSN=.+'; then
  log "SQL_DSN is set: the database is not SQLite, this script cannot back it up. abort"
  exit 1
fi

IMAGE=$(docker inspect -f '{{.Config.Image}}' "$CID")
DATA_DIR=$(docker inspect -f '{{range .Mounts}}{{if eq .Destination "/data"}}{{.Source}}{{end}}{{end}}' "$CID")
if [ -z "$DATA_DIR" ] || [ ! -d "$DATA_DIR" ]; then
  log "cannot find the host directory mounted at /data, abort"
  exit 1
fi

OLD_IMAGE_ID=$(docker inspect -f '{{.Image}}' "$CID")
log "pulling $IMAGE"
docker compose pull -q "$SERVICE"
NEW_IMAGE_ID=$(docker image inspect -f '{{.Id}}' "$IMAGE")

BACKUP_FILE="$BACKUP_DIR/data-$(date '+%Y%m%d-%H%M%S').tar.gz"
log "stopping $SERVICE and backing up $DATA_DIR -> $BACKUP_FILE"
docker compose stop "$SERVICE"
tar -czf "$BACKUP_FILE" -C "$DATA_DIR" .
cp -f docker-compose.yml "${BACKUP_FILE%.tar.gz}.compose.yml"

if [ "$OLD_IMAGE_ID" = "$NEW_IMAGE_ID" ]; then
  log "no new image, starting again"
else
  log "new image $NEW_IMAGE_ID (was $OLD_IMAGE_ID)"
fi
docker compose up -d "$SERVICE"

healthy=false
for _ in $(seq 1 40); do
  sleep 3
  if docker compose exec -T "$SERVICE" wget -q -O - http://localhost:3000/api/status 2>/dev/null \
      | grep -q '"success":\s*true'; then
    healthy=true
    break
  fi
done

if [ "$healthy" = true ]; then
  log "healthy"
else
  log "health check failed, rolling back to $OLD_IMAGE_ID and restoring $BACKUP_FILE"
  docker compose stop "$SERVICE"
  find "$DATA_DIR" -mindepth 1 -delete
  tar -xzf "$BACKUP_FILE" -C "$DATA_DIR"
  docker tag "$OLD_IMAGE_ID" "$IMAGE"
  docker compose up -d "$SERVICE"
  log "rolled back"
  exit 1
fi

find "$BACKUP_DIR" -name 'data-*' -mtime +"$KEEP_DAYS" -delete
docker image prune -f >/dev/null
log "done"
