#!/usr/bin/env bash
set -euo pipefail

export TZ="${TZ:-Europe/Moscow}"
export HTTP_PORT="${HTTP_PORT:-8080}"
export FREEPBX_DB_HOST="${FREEPBX_DB_HOST:-127.0.0.1}"
export FREEPBX_DB_NAME="${FREEPBX_DB_NAME:-asterisk}"
export FREEPBX_CDR_DB_NAME="${FREEPBX_CDR_DB_NAME:-asteriskcdrdb}"
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

# shellcheck source=ensure-ami.sh
source /usr/local/bin/freepbx-ensure-ami
# shellcheck source=ensure-odbc.sh
source /usr/local/bin/freepbx-ensure-odbc
export RTP_START="${RTP_START:-10000}"
export RTP_FINISH="${RTP_FINISH:-20000}"
export LD_LIBRARY_PATH="/usr/lib/asterisk:${LD_LIBRARY_PATH:-}"

ensure_freepbx_sbin_links() {
  local bindir="/usr/src/freepbx/amp_conf/bin"
  if [ ! -d "${bindir}" ]; then
    return 0
  fi
  for f in "${bindir}"/*; do
    [ -f "${f}" ] || continue
    ln -sf "${f}" "/usr/sbin/$(basename "${f}")"
  done
}

ensure_freepbx_runtime_layout() {
  if [ -x /usr/local/bin/freepbx-ensure-layout ]; then
    /usr/local/bin/freepbx-ensure-layout
  else
    ensure_freepbx_sbin_links
  fi
}

ensure_freepbx_sbin_links

ensure_call_recording() {
  local monitor="/var/spool/asterisk/monitor/"
  mkdir -p "${monitor}"
  chown asterisk:asterisk "${monitor}" 2>/dev/null || true

  if command -v mariadb >/dev/null 2>&1; then
    mariadb -h127.0.0.1 -P"${FREEPBX_DB_PORT}" -u"${FREEPBX_DB_USER}" -p"${FREEPBX_DB_PASS}" "${FREEPBX_DB_NAME}" -e \
      "UPDATE freepbx_settings SET value='${monitor}' WHERE keyword='MIXMON_DIR' AND (value='' OR value IS NULL);" \
      2>/dev/null || true
  fi
}

ensure_call_recording

ln -snf "/usr/share/zoneinfo/${TZ}" /etc/localtime
echo "${TZ}" > /etc/timezone

mkdir -p \
  /run/php \
  /run/nginx \
  /data \
  /var/lib/php/sessions \
  /var/www/html \
  /var/log/asterisk \
  /var/log/asterisk/cdr-csv \
  /var/log/nginx \
  /var/log/supervisor \
  /var/lib/asterisk/sounds/custom \
  /var/spool/asterisk/monitor \
  /var/spool/asterisk/tmp \
  /var/spool/asterisk/voicemail

envsubst '${HTTP_PORT}' \
  < /etc/nginx/templates/freepbx.conf.template \
  > /etc/nginx/sites-enabled/freepbx.conf

if [ -f /data/freepbx.conf ] && [ ! -f /etc/freepbx.conf ]; then
  cp /data/freepbx.conf /etc/freepbx.conf
fi

if [ -f /data/amportal.conf ] && [ ! -f /etc/amportal.conf ]; then
  cp /data/amportal.conf /etc/amportal.conf
fi

chown asterisk:asterisk /etc/freepbx.conf /etc/amportal.conf /data/freepbx.conf /data/amportal.conf 2>/dev/null || true
chmod 640 /etc/freepbx.conf /etc/amportal.conf /data/freepbx.conf /data/amportal.conf 2>/dev/null || true

if [ ! -f /etc/asterisk/asterisk.conf ] && [ -d /usr/local/share/asterisk-config-defaults ]; then
  echo "Seeding default Asterisk configuration into /etc/asterisk..."
  cp -a /usr/local/share/asterisk-config-defaults/. /etc/asterisk/
fi

ensure_asterisk_ami
ensure_odbc_config || true

chown -R asterisk:asterisk \
  /etc/asterisk \
  /var/lib/php/sessions \
  /var/lib/asterisk \
  /var/log/asterisk \
  /var/spool/asterisk

chmod 1733 /var/lib/php/sessions

echo "Waiting for MariaDB at ${FREEPBX_DB_HOST}:${FREEPBX_DB_PORT}..."
until mysqladmin \
  --host="${FREEPBX_DB_HOST}" \
  --port="${FREEPBX_DB_PORT}" \
  --user="${FREEPBX_DB_USER}" \
  --password="${FREEPBX_DB_PASS}" \
  ping --silent; do
  sleep 2
done

if [ -f /data/.freepbx-installed ] && { [ ! -f /etc/freepbx.conf ] || [ ! -f /var/www/html/admin/config.php ]; }; then
  echo "FreePBX marker exists, but required web/config files are missing; reinstalling web/config files."
  rm -f /data/.freepbx-installed /data/.freepbx-core-installed
fi

if [ ! -f /data/.freepbx-installed ]; then
  echo "Running first-time FreePBX installation..."
  /usr/sbin/asterisk -U asterisk -G asterisk
  sleep 5

  cd /usr/src/freepbx
  install_status=0
  set +e
  ./install -n \
    --dbhost="${FREEPBX_DB_HOST}" \
    --dbport="${FREEPBX_DB_PORT}" \
    --dbname="${FREEPBX_DB_NAME}" \
    --cdrdbname="${FREEPBX_CDR_DB_NAME}" \
    --dbuser="${FREEPBX_DB_USER}" \
    --dbpass="${FREEPBX_DB_PASS}" \
    --user=asterisk \
    --group=asterisk \
    --webroot=/var/www/html
  install_status="$?"
  set -e

  ensure_freepbx_runtime_layout

  if [ "${install_status}" -ne 0 ]; then
    if [ -f /etc/freepbx.conf ] && [ -f /var/www/html/admin/config.php ] && [ -x /usr/sbin/fwconsole ]; then
      echo "FreePBX installer returned ${install_status}, but required files exist; continuing."
    else
      echo "FreePBX installer failed with exit code ${install_status}."
      exit "${install_status}"
    fi
  fi

  if [ -f /etc/freepbx.conf ]; then
    cp /etc/freepbx.conf /data/freepbx.conf
  fi

  if [ -f /etc/amportal.conf ]; then
    cp /etc/amportal.conf /data/amportal.conf
  fi

  chown asterisk:asterisk /etc/freepbx.conf /etc/amportal.conf /data/freepbx.conf /data/amportal.conf 2>/dev/null || true
  chmod 640 /etc/freepbx.conf /etc/amportal.conf /data/freepbx.conf /data/amportal.conf 2>/dev/null || true

  touch /data/.freepbx-installed

  ensure_asterisk_ami

  /usr/sbin/asterisk -rx "core stop now" || true
  sleep 3
fi

ensure_freepbx_runtime_layout

echo "Starting FreePBX services..."
exec "$@"
