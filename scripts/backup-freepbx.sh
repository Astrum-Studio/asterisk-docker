#!/usr/bin/env bash
# Daily backup for FreePBX stack (MariaDB + optional recordings list).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BACKUP_DIR="${BACKUP_DIR:-${ROOT}/backups}"
STAMP="$(date +%Y%m%d-%H%M%S)"
mkdir -p "${BACKUP_DIR}"

if [ -f "${ROOT}/.env" ]; then
  # shellcheck disable=SC1091
  source "${ROOT}/.env"
fi

DB_CONTAINER="${FREEPBX_DB_CONTAINER:-freepbx-db}"
ROOT_PASS="${MYSQL_ROOT_PASSWORD:-}"

if [ -z "${ROOT_PASS}" ]; then
  echo "MYSQL_ROOT_PASSWORD not set; export or add to .env" >&2
  exit 1
fi

OUT="${BACKUP_DIR}/freepbx-${STAMP}.sql.gz"
docker exec "${DB_CONTAINER}" mariadb-dump -uroot -p"${ROOT_PASS}" \
  --databases "${FREEPBX_DB_NAME:-asterisk}" "${FREEPBX_CDR_DB_NAME:-asteriskcdrdb}" \
  | gzip -9 >"${OUT}"

echo "Backup written: ${OUT}"
find "${BACKUP_DIR}" -name 'freepbx-*.sql.gz' -mtime +14 -delete 2>/dev/null || true
