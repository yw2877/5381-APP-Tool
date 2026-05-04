#!/usr/bin/env bash
# scripts/backup.sh — daily SQLite backup for the Shiny container.
#
# Drops a timestamped copy of data/alerts.sqlite into ${BACKUP_DIR}
# (default: ./backups). Keeps the last 14 days. Never deletes the live DB.
#
# Cron line (DigitalOcean droplet, as the deploy user):
#   0 3 * * * cd /home/deploy/5381-APP-Tool && bash scripts/backup.sh >> /var/log/msc-backup.log 2>&1

set -euo pipefail

CONTAINER="${CONTAINER:-msc-shiny}"
DB_IN_CONTAINER="${DB_IN_CONTAINER:-/app/data/alerts.sqlite}"
BACKUP_DIR="${BACKUP_DIR:-./backups}"
RETAIN_DAYS="${RETAIN_DAYS:-14}"

mkdir -p "${BACKUP_DIR}"
DATE=$(date +%F_%H%M%S)
OUT="${BACKUP_DIR}/alerts-${DATE}.sqlite"

if ! command -v docker >/dev/null 2>&1; then
  echo "[backup.sh] docker not found on PATH — falling back to direct file copy"
  if [ -f "data/alerts.sqlite" ]; then
    cp "data/alerts.sqlite" "${OUT}"
    echo "[backup.sh] copied data/alerts.sqlite -> ${OUT}"
  else
    echo "[backup.sh] ERROR: no docker AND no local data/alerts.sqlite. Nothing to back up." >&2
    exit 1
  fi
else
  # Use SQLite's online backup so writes during copy are safe.
  STAGING="/tmp/alerts-${DATE}.sqlite"
  docker exec "${CONTAINER}" sqlite3 "${DB_IN_CONTAINER}" ".backup '${STAGING}'"
  docker cp "${CONTAINER}:${STAGING}" "${OUT}"
  docker exec "${CONTAINER}" rm -f "${STAGING}"
  echo "[backup.sh] backed up ${CONTAINER}:${DB_IN_CONTAINER} -> ${OUT}"
fi

# Prune backups older than RETAIN_DAYS days. Use -mtime +N for safety.
find "${BACKUP_DIR}" -name 'alerts-*.sqlite' -type f -mtime "+${RETAIN_DAYS}" -print -delete || true

echo "[backup.sh] done at $(date)"
