#!/usr/bin/env bash
# Runtime fixes that must run after Asterisk and FreePBX are up.
# Keeps astdb, network ports, and inbound-route data in sync with MariaDB and .env.
# Pass "restore-core" to only undo a local Core.class.php edit.
# Pass "notices" to only dismiss stock first-boot dashboard notices.
# Pass "ports" to only synchronize network ports (SIP, RTP, AMI, HTTP, IAX).

set -euo pipefail

export FREEPBX_DB_HOST="${FREEPBX_DB_HOST:-127.0.0.1}"
export FREEPBX_DB_NAME="${FREEPBX_DB_NAME:-asterisk}"
export FREEPBX_DB_USER="${FREEPBX_DB_USER:-freepbx}"
export FREEPBX_DB_PASS="${FREEPBX_DB_PASS:-freepbx}"
export FREEPBX_DB_PORT="${FREEPBX_DB_PORT:-3307}"

export SIP_PORT="${SIP_PORT:-5060}"
export SIPS_PORT="${SIPS_PORT:-5061}"
export SIP_LEGACY_PORT="${SIP_LEGACY_PORT:-5160}"
export RTP_START="${RTP_START:-10000}"
export RTP_FINISH="${RTP_FINISH:-20000}"
export ASTERISK_AMI_PORT="${ASTERISK_AMI_PORT:-5038}"
export ASTERISK_HTTP_PORT="${ASTERISK_HTTP_PORT:-8088}"
export ASTERISK_HTTPS_PORT="${ASTERISK_HTTPS_PORT:-8089}"
export ASTERISK_IAX_PORT="${ASTERISK_IAX_PORT:-4569}"

log() {
  printf '[freepbx-sync] %s\n' "$*"
}

mysql_exec() {
  mariadb -h"${FREEPBX_DB_HOST}" -P"${FREEPBX_DB_PORT}" -u"${FREEPBX_DB_USER}" -p"${FREEPBX_DB_PASS}" "${FREEPBX_DB_NAME}" "$@"
}

sync_ports_and_network() {
  log "Synchronizing network ports and settings (SIP=${SIP_PORT}/${SIPS_PORT}, RTP=${RTP_START}-${RTP_FINISH}, AMI=${ASTERISK_AMI_PORT}, HTTP=${ASTERISK_HTTP_PORT}/${ASTERISK_HTTPS_PORT})..."

  # 1. Update MariaDB tables if available
  if command -v mariadb >/dev/null 2>&1; then
    mysql_exec -e "
      UPDATE freepbx_settings SET value='${ASTERISK_AMI_PORT}' WHERE keyword='ASTMANAGERPORT';
      UPDATE freepbx_settings SET value='${ASTERISK_AMI_BINDADDR:-127.0.0.1}' WHERE keyword='ASTMANAGERHOST';
      UPDATE freepbx_settings SET value='${ASTERISK_HTTP_PORT}' WHERE keyword='HTTPBINDPORT';
      UPDATE freepbx_settings SET value='${ASTERISK_HTTPS_PORT}' WHERE keyword='HTTPTLSBINDPORT';
      UPDATE freepbx_settings SET value='0' WHERE keyword='NODEJSENABLED';
    " 2>/dev/null || true

    mysql_exec -e "
      UPDATE sipsettings SET data='${SIP_LEGACY_PORT}' WHERE keyword='bindport';
      UPDATE sipsettings SET data='${SIPS_PORT}' WHERE keyword='tlsbindport';
    " 2>/dev/null || true

    mysql_exec -e "
      UPDATE kvstore_Sipsettings SET val='${SIP_PORT}' WHERE \`key\` IN ('udpport-0.0.0.0', 'tcpport-0.0.0.0');
      UPDATE kvstore_Sipsettings SET val='${SIPS_PORT}' WHERE \`key\`='tlsport-0.0.0.0';
      REPLACE INTO kvstore_Sipsettings (\`key\`, \`val\`, \`type\`, \`id\`) VALUES
        ('rtpstart', '${RTP_START}', NULL, 'noid'),
        ('rtpend', '${RTP_FINISH}', NULL, 'noid');
    " 2>/dev/null || true
  fi

  # 2. Update /etc/amportal.conf and /data/amportal.conf
  local am_file
  for am_file in /etc/amportal.conf /data/amportal.conf; do
    if [ -f "${am_file}" ]; then
      sed -i -E "s/^[[:space:]]*ASTMANAGERPORT[[:space:]]*=.*/ASTMANAGERPORT=${ASTERISK_AMI_PORT}/" "${am_file}"
      sed -i -E "s/^[[:space:]]*ASTMANAGERHOST[[:space:]]*=.*/ASTMANAGERHOST=${ASTERISK_AMI_BINDADDR:-127.0.0.1}/" "${am_file}"
    fi
  done

  # 3. Update FreePBX BMO objects via PHP
  if [ -f /etc/freepbx.conf ]; then
    php <<'PHP'
<?php
$bootstrap_settings['freepbx_auth'] = false;
$bootstrap_settings['skip_astman'] = true;
if (!@include '/etc/freepbx.conf') {
    exit(0);
}
try {
    $sip_port = getenv('SIP_PORT') ?: '5060';
    $sips_port = getenv('SIPS_PORT') ?: '5061';
    $rtp_start = getenv('RTP_START') ?: '10000';
    $rtp_finish = getenv('RTP_FINISH') ?: '20000';
    $ami_port = getenv('ASTERISK_AMI_PORT') ?: '5038';
    $http_port = getenv('ASTERISK_HTTP_PORT') ?: '8088';
    $https_port = getenv('ASTERISK_HTTPS_PORT') ?: '8089';

    if (class_exists('FreePBX')) {
        if (method_exists('FreePBX', 'Sipsettings')) {
            $ss = \FreePBX::Sipsettings();
            $ss->setConfig('udpport-0.0.0.0', $sip_port);
            $ss->setConfig('tcpport-0.0.0.0', $sip_port);
            $ss->setConfig('tlsport-0.0.0.0', $sips_port);
            $ss->setConfig('rtpstart', $rtp_start);
            $ss->setConfig('rtpend', $rtp_finish);
        }
        if (method_exists('FreePBX', 'Config')) {
            $cfg = \FreePBX::Config();
            $cfg->set_conf_values([
                'ASTMANAGERPORT' => $ami_port,
                'HTTPBINDPORT' => $http_port,
                'HTTPTLSBINDPORT' => $https_port,
                'NODEJSENABLED' => '0',
            ], true, true);
        }
    }
} catch (\Throwable $e) {
    fwrite(STDERR, "[freepbx-sync] Port BMO sync notice: " . $e->getMessage() . "\n");
}
PHP
  fi

  # 4. Direct Asterisk config files
  mkdir -p /etc/asterisk

  if [ -f /etc/asterisk/manager.conf ]; then
    sed -i -E "s/^[[:space:]]*port[[:space:]]*=.*/port = ${ASTERISK_AMI_PORT}/" /etc/asterisk/manager.conf
    sed -i -E "s/^[[:space:]]*bindaddr[[:space:]]*=.*/bindaddr = ${ASTERISK_AMI_BINDADDR:-127.0.0.1}/" /etc/asterisk/manager.conf
    if ! grep -q "manager_general_custom.conf" /etc/asterisk/manager.conf; then
      sed -i '/\[general\]/a #include manager_general_custom.conf' /etc/asterisk/manager.conf
    fi
  fi

  cat > /etc/asterisk/rtp_custom.conf <<EOF_RTP
[general](+)
rtpstart = ${RTP_START}
rtpend = ${RTP_FINISH}
EOF_RTP

  cat > /etc/asterisk/http_custom.conf <<EOF_HTTP
[general](+)
bindport = ${ASTERISK_HTTP_PORT}
tlsbindaddr = 127.0.0.1:${ASTERISK_HTTPS_PORT}
EOF_HTTP

  cat > /etc/asterisk/iax_general_custom.conf <<EOF_IAX
bindport = ${ASTERISK_IAX_PORT}
EOF_IAX

  if [ -f /etc/asterisk/modules.conf ] && ! grep -q "noload = chan_unistim.so" /etc/asterisk/modules.conf; then
    echo "noload = chan_unistim.so" >> /etc/asterisk/modules.conf
  fi

  chown -R asterisk:asterisk \
    /etc/asterisk/rtp_custom.conf \
    /etc/asterisk/http_custom.conf \
    /etc/asterisk/iax_general_custom.conf 2>/dev/null || true
  chmod 640 \
    /etc/asterisk/rtp_custom.conf \
    /etc/asterisk/http_custom.conf \
    /etc/asterisk/iax_general_custom.conf 2>/dev/null || true
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

if [[ "${1:-}" == "ports" ]]; then
  sync_ports_and_network
  exit 0
fi

restore_core_module_file
normalize_incoming_routes
sync_ports_and_network
sync_astdb_from_database || true
ensure_blacklist_dest
refresh_core_signature || log "Core signature refresh failed."
