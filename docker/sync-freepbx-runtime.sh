#!/usr/bin/env bash
# Runtime fixes that must run after Asterisk and FreePBX are up.
# Keeps astdb and inbound-route data in sync with MariaDB.
# Pass "restore-core" to only undo a local Core.class.php edit.
# Pass "notices" to only dismiss stock first-boot dashboard notices.

set -euo pipefail

export FREEPBX_DB_HOST="${FREEPBX_DB_HOST:-127.0.0.1}"
export FREEPBX_DB_NAME="${FREEPBX_DB_NAME:-asterisk}"
export FREEPBX_DB_USER="${FREEPBX_DB_USER:-freepbx}"
export FREEPBX_DB_PASS="${FREEPBX_DB_PASS:-freepbx}"
export FREEPBX_DB_PORT="${FREEPBX_DB_PORT:-3307}"

log() {
  printf '[freepbx-sync] %s\n' "$*"
}

mysql_exec() {
  mariadb -h"${FREEPBX_DB_HOST}" -P"${FREEPBX_DB_PORT}" -u"${FREEPBX_DB_USER}" -p"${FREEPBX_DB_PASS}" "${FREEPBX_DB_NAME}" "$@"
}

# PHP 8.1+ deprecates urlencode(null). An older image rewrote Core.class.php to
# paper over that, which FreePBX then reports as a tampered module file.
# Keep the signed file intact and store empty strings instead of NULL.
restore_core_module_file() {
  local core="/var/www/html/admin/modules/core/Core.class.php"

  [ -f "${core}" ] || return 0

  if grep -q "urlencode(\$value\['cidnum'\] ?? '')" "${core}" \
    || grep -q "urlencode(\$value\['extension'\] ?? '')" "${core}"; then
    log "Restoring signed Core.class.php (removing PHP 8.2 inbound-route patch)..."
    sed -i \
      -e "s/urlencode(\$value\['cidnum'\] ?? '')/urlencode(\$value['cidnum'])/g" \
      -e "s/urlencode(\$value\['extension'\] ?? '')/urlencode(\$value['extension'])/g" \
      "${core}"
    chown asterisk:asterisk "${core}" 2>/dev/null || true
  fi
}

normalize_incoming_routes() {
  command -v mariadb >/dev/null 2>&1 || return 0

  mysql_exec -e \
    "UPDATE incoming SET cidnum='' WHERE cidnum IS NULL; UPDATE incoming SET extension='' WHERE extension IS NULL;" \
    2>/dev/null || true

  if ! mysql_exec <<'SQL'
DROP TRIGGER IF EXISTS incoming_cidnum_bi;
DROP TRIGGER IF EXISTS incoming_extension_bi;
DROP TRIGGER IF EXISTS incoming_cidnum_bu;
DROP TRIGGER IF EXISTS incoming_extension_bu;
CREATE TRIGGER incoming_cidnum_bi BEFORE INSERT ON incoming FOR EACH ROW SET NEW.cidnum = IFNULL(NEW.cidnum, '');
CREATE TRIGGER incoming_extension_bi BEFORE INSERT ON incoming FOR EACH ROW SET NEW.extension = IFNULL(NEW.extension, '');
CREATE TRIGGER incoming_cidnum_bu BEFORE UPDATE ON incoming FOR EACH ROW SET NEW.cidnum = IFNULL(NEW.cidnum, '');
CREATE TRIGGER incoming_extension_bu BEFORE UPDATE ON incoming FOR EACH ROW SET NEW.extension = IFNULL(NEW.extension, '');
SQL
  then
    log "Could not install incoming NULL triggers."
  fi
}

ensure_blacklist_dest() {
  local current

  if ! /usr/sbin/asterisk -rx "core show version" >/dev/null 2>&1; then
    return 0
  fi

  current="$(/usr/sbin/asterisk -rx "database get blacklist dest" 2>/dev/null || true)"
  if ! printf '%s\n' "${current}" | grep -q 'Value: [^[:space:]]'; then
    log "Setting empty blacklist destination to hangup."
    /usr/sbin/asterisk -rx "database put blacklist dest app-blackhole,hangup,1" >/dev/null 2>&1 || true
  fi
}

refresh_core_signature() {
  [ -f /etc/freepbx.conf ] || return 0
  [ -f /var/www/html/admin/modules/core/Core.class.php ] || return 0

  php <<'PHP'
<?php
$bootstrap_settings['freepbx_auth'] = false;
$bootstrap_settings['skip_astman'] = true;
if (!@include '/etc/freepbx.conf') {
    fwrite(STDERR, "freepbx.conf could not be loaded\n");
    exit(1);
}
try {
    $mf = \module_functions::create();
    $mf->updateSignature('core');
    $mf->getAllSignatures(true);
} catch (\Throwable $e) {
    fwrite(STDERR, $e->getMessage() . "\n");
    exit(1);
}
PHP
}

clear_stock_notices() {
  [ -f /etc/freepbx.conf ] || return 0

  php <<'PHP'
<?php
$bootstrap_settings['freepbx_auth'] = false;
$bootstrap_settings['skip_astman'] = true;
if (!@include '/etc/freepbx.conf') {
    fwrite(STDERR, "freepbx.conf could not be loaded\n");
    exit(1);
}
try {
    $nt = \notifications::create();
    foreach ([
        ['framework', 'BROWSER_STATS'],
        ['framework', 'htaccess'],
        ['core', 'EXTENSIONS_MOVE'],
        ['core', 'core_bindaddress_changed'],
        ['api', 'key-regenerated'],
    ] as [$module, $id]) {
        if ($nt->exists($module, $id)) {
            $nt->delete($module, $id);
        }
    }
    $db = \FreePBX::Database();
    $db->prepare("REPLACE INTO admin (`variable`, `value`) VALUES ('htaccess', '1')")->execute();
} catch (\Throwable $e) {
    fwrite(STDERR, $e->getMessage() . "\n");
    exit(1);
}
PHP
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

if [[ "${1:-}" == "notices" ]]; then
  clear_stock_notices
  exit 0
fi

if [[ "${1:-}" == "restore-core" ]]; then
  restore_core_module_file
  exit 0
fi

restore_core_module_file
normalize_incoming_routes
sync_astdb_from_database || true
ensure_blacklist_dest
refresh_core_signature || log "Core signature refresh failed."
