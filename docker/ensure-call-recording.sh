#!/usr/bin/env bash
# Enable Force call recording on all FreePBX inbound/outbound routes.
set -euo pipefail

export FREEPBX_DB_HOST="${FREEPBX_DB_HOST:-127.0.0.1}"
export FREEPBX_DB_NAME="${FREEPBX_DB_NAME:-asterisk}"
export FREEPBX_DB_USER="${FREEPBX_DB_USER:-freepbx}"
export FREEPBX_DB_PASS="${FREEPBX_DB_PASS:-freepbx}"
export FREEPBX_DB_PORT="${FREEPBX_DB_PORT:-3307}"

log() {
  printf '[ensure-call-recording] %s\n' "$*"
}

if ! command -v mariadb >/dev/null 2>&1; then
  log "mariadb client missing; skipping"
  exit 0
fi

mysql_q() {
  mariadb -h"${FREEPBX_DB_HOST}" -P"${FREEPBX_DB_PORT}" -u"${FREEPBX_DB_USER}" -p"${FREEPBX_DB_PASS}" \
    "${FREEPBX_DB_NAME}" -N -B -e "$1"
}

mysql_exec() {
  mariadb -h"${FREEPBX_DB_HOST}" -P"${FREEPBX_DB_PORT}" -u"${FREEPBX_DB_USER}" -p"${FREEPBX_DB_PASS}" \
    "${FREEPBX_DB_NAME}" -e "$1"
}

ensure_mixmon_dir() {
  local monitor="/var/spool/asterisk/monitor/"
  mkdir -p "${monitor}"
  chown asterisk:asterisk "${monitor}" 2>/dev/null || true
  mysql_exec \
    "UPDATE freepbx_settings SET value='${monitor}' WHERE keyword='MIXMON_DIR';" \
    2>/dev/null || true
}

ensure_outbound_route_recording() {
  local route_ids
  route_ids="$(mysql_q "SELECT route_id FROM outbound_routes ORDER BY route_id;" || true)"
  [ -n "${route_ids}" ] || return 0

  while IFS= read -r route_id; do
    [ -n "${route_id}" ] || continue
    mysql_exec "DELETE FROM callrecording_module WHERE display='routing' AND extension='${route_id}';"
    mysql_exec "INSERT INTO callrecording_module (display, extension, cidnum, callrecording)
      VALUES ('routing', '${route_id}', '', 'force');"
    log "outbound route ${route_id}: recording=force"
  done <<< "${route_ids}"
}

ensure_inbound_route_recording() {
  local rows
  rows="$(mysql_q "SELECT extension, IFNULL(cidnum,'') FROM incoming;" || true)"
  [ -n "${rows}" ] || return 0

  while IFS=$'\t' read -r extension cidnum; do
    [ -n "${extension}" ] || continue
    mysql_exec "DELETE FROM callrecording_module
      WHERE display='did' AND extension='${extension}' AND cidnum='${cidnum}';"
    mysql_exec "INSERT INTO callrecording_module (display, extension, cidnum, callrecording)
      VALUES ('did', '${extension}', '${cidnum}', 'force');"
    log "inbound did ext=${extension} cid=${cidnum:-any}: recording=force"
  done <<< "${rows}"
}

ensure_mixmon_dir
ensure_outbound_route_recording
ensure_inbound_route_recording
log "call recording rules applied"
