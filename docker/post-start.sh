#!/usr/bin/env bash
set -euo pipefail

export FREEPBX_DB_HOST="${FREEPBX_DB_HOST:-127.0.0.1}"
export FREEPBX_DB_NAME="${FREEPBX_DB_NAME:-asterisk}"
export FREEPBX_DB_USER="${FREEPBX_DB_USER:-freepbx}"
export FREEPBX_DB_PASS="${FREEPBX_DB_PASS:-freepbx}"
export FREEPBX_DB_PORT="${FREEPBX_DB_PORT:-3307}"
export ASTERISK_AMI_ENABLED="${ASTERISK_AMI_ENABLED:-1}"
export ASTERISK_AMI_BINDADDR="${ASTERISK_AMI_BINDADDR:-127.0.0.1}"
export ASTERISK_AMI_PORT="${ASTERISK_AMI_PORT:-5038}"
export ASTERISK_AMI_USER="${ASTERISK_AMI_USER:-admin}"
export ASTERISK_AMI_PASSWORD="${ASTERISK_AMI_PASSWORD:-admin}"
export ASTERISK_AMI_PERMIT="${ASTERISK_AMI_PERMIT:-127.0.0.0/255.0.0.0}"
export ASTERISK_AMI_PERMIT_HOST_IPS="${ASTERISK_AMI_PERMIT_HOST_IPS:-1}"
export ASTERISK_AMI_PERMIT_DOCKER="${ASTERISK_AMI_PERMIT_DOCKER:-1}"
export LD_LIBRARY_PATH="/usr/lib/asterisk:${LD_LIBRARY_PATH:-}"

# shellcheck source=ensure-ami.sh
source /usr/local/bin/freepbx-ensure-ami
# shellcheck source=ensure-odbc.sh
source /usr/local/bin/freepbx-ensure-odbc

log() {
  printf '[freepbx-post-start] %s\n' "$*"
}

if [ ! -f /etc/freepbx.conf ] || [ ! -x /usr/sbin/fwconsole ]; then
  log "FreePBX is not installed yet; skipping post-start tasks."
  exit 0
fi

log "Waiting for Asterisk control socket..."
for _ in $(seq 1 90); do
  if /usr/sbin/asterisk -rx "core show version" >/dev/null 2>&1; then
    break
  fi
  sleep 2
done

if ! /usr/sbin/asterisk -rx "core show version" >/dev/null 2>&1; then
  log "Asterisk did not become ready in time."
  exit 1
fi

if [ ! -f /data/.freepbx-modules-installed ]; then
  log "Installing packaged FreePBX modules..."
  fwconsole ma installall || true
  fwconsole chown || true
  touch /data/.freepbx-modules-installed
fi

log "Ensuring FreePBX runtime layout..."
/usr/local/bin/freepbx-ensure-layout

log "Ensuring AMI credentials before FreePBX reload..."
ensure_asterisk_ami
sync_freepbx_manager_user
reload_asterisk_ami
log "AMI user ${ASTERISK_AMI_USER} applied (manager reload)"

log "Ensuring ODBC DSN for CDR/CEL..."
if ensure_odbc_config; then
  reload_asterisk_odbc
  log "ODBC DSN MySQL-asteriskcdrdb applied"
else
  log "ODBC DSN setup skipped (driver missing)"
fi

log "Reloading FreePBX after Asterisk is ready..."
fwconsole reload || true

log "Applying FreePBX runtime sync (astdb, inbound routes, PHP patches)..."
/usr/local/bin/freepbx-sync-runtime || true

log "Ensuring call recording on inbound/outbound routes..."
/usr/local/bin/freepbx-ensure-call-recording || true
/usr/sbin/fwconsole reload >/dev/null 2>&1 || true
/usr/sbin/asterisk -rx "dialplan reload" >/dev/null 2>&1 || true

log "Post-start tasks completed."
