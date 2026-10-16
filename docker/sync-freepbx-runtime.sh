#!/usr/bin/env bash
# Runtime fixes that must run after Asterisk and FreePBX are up.
# Keeps astdb, inbound-route data, and PHP 8.2 compatibility in sync with MariaDB.

set -euo pipefail

export FREEPBX_DB_HOST="${FREEPBX_DB_HOST:-127.0.0.1}"
export FREEPBX_DB_NAME="${FREEPBX_DB_NAME:-asterisk}"
export FREEPBX_DB_USER="${FREEPBX_DB_USER:-freepbx}"
export FREEPBX_DB_PASS="${FREEPBX_DB_PASS:-freepbx}"
export FREEPBX_DB_PORT="${FREEPBX_DB_PORT:-3307}"

log() {
  printf '[freepbx-sync] %s\n' "$*"
}

apply_php82_patches() {
  local core="/var/www/html/admin/modules/core/Core.class.php"

  [ -f "${core}" ] || return 0

  if ! grep -q "urlencode(\$value\['cidnum'\] ?? '')" "${core}"; then
    log "Applying PHP 8.2 inbound-route patch to Core.class.php..."
    sed -i \
      -e "s/urlencode(\$value\['cidnum'\])/urlencode(\$value['cidnum'] ?? '')/g" \
      -e "s/urlencode(\$value\['extension'\])/urlencode(\$value['extension'] ?? '')/g" \
      "${core}"
  fi
}

normalize_incoming_routes() {
  command -v mariadb >/dev/null 2>&1 || return 0

  mariadb -h"${FREEPBX_DB_HOST}" -P"${FREEPBX_DB_PORT}" -u"${FREEPBX_DB_USER}" -p"${FREEPBX_DB_PASS}" "${FREEPBX_DB_NAME}" -e \
    "UPDATE incoming SET cidnum='' WHERE cidnum IS NULL;" \
    2>/dev/null || true
}

sync_astdb_from_database() {
  if [ ! -x /usr/sbin/fwconsole ]; then
    log "fwconsole not available; skipping astdb sync."
    return 0
  fi

  if ! /usr/sbin/asterisk -rx "core show version" >/dev/null 2>&1; then
    log "Asterisk is not ready; skipping astdb sync."
    return 0
  fi

  log "Rebuilding AMPUSER/DEVICE astdb from MariaDB (fwconsole util resetastdb)..."
  /usr/sbin/fwconsole util resetastdb >/dev/null 2>&1 || {
    log "fwconsole util resetastdb failed."
    return 1
  }
}

apply_php82_patches
normalize_incoming_routes
sync_astdb_from_database
