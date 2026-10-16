#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ENV_FILE="${ROOT_DIR}/.env"
TEMPLATE="${ROOT_DIR}/docker/fail2ban/jail.d/asterisk-freepbx.conf.template"
LOGROTATE_TEMPLATE="${ROOT_DIR}/docker/fail2ban/logrotate-asterisk.conf"
JAIL_TARGET="/etc/fail2ban/jail.d/asterisk-freepbx.conf"
LOGROTATE_TARGET="/etc/logrotate.d/asterisk-freepbx"

log() {
  printf '[fail2ban-install] %s\n' "$*"
}

die() {
  printf '[fail2ban-install] ERROR: %s\n' "$*" >&2
  exit 1
}

if [ "$(id -u)" -ne 0 ]; then
  die "Run as root: sudo $0"
fi

if ! command -v fail2ban-client >/dev/null 2>&1; then
  die "fail2ban is not installed. On Debian/Ubuntu: apt-get install -y fail2ban"
fi

IGNORE_IP="127.0.0.1/8 ::1"
if [ -f "${ENV_FILE}" ]; then
  # shellcheck disable=SC1090
  set -a
  source "${ENV_FILE}"
  set +a
  if [ -n "${FAIL2BAN_IGNORE_IP:-}" ]; then
    IGNORE_IP="${FAIL2BAN_IGNORE_IP}"
  fi
fi

ASTERISK_LOG_PATH="${ROOT_DIR}/logs/asterisk/full"
mkdir -p "$(dirname "${ASTERISK_LOG_PATH}")"
chmod 755 "$(dirname "${ASTERISK_LOG_PATH}")" 2>/dev/null || true
touch "${ASTERISK_LOG_PATH}"

sed \
  -e "s|__ASTERISK_LOG_PATH__|${ASTERISK_LOG_PATH}|g" \
  -e "s|__FAIL2BAN_IGNORE_IP__|${IGNORE_IP}|g" \
  "${TEMPLATE}" > "${JAIL_TARGET}"

sed \
  -e "s|__ASTERISK_LOG_PATH__|${ASTERISK_LOG_PATH}|g" \
  "${LOGROTATE_TEMPLATE}" > "${LOGROTATE_TARGET}"

chmod 644 "${JAIL_TARGET}" "${LOGROTATE_TARGET}"

if ! fail2ban-client -t >/dev/null 2>&1; then
  die "fail2ban config test failed. Check ${JAIL_TARGET}"
fi

systemctl enable fail2ban >/dev/null 2>&1 || true
systemctl restart fail2ban

for _ in $(seq 1 15); do
  if fail2ban-client ping >/dev/null 2>&1; then
    break
  fi
  sleep 1
done

if ! fail2ban-client ping >/dev/null 2>&1; then
  die "fail2ban did not start. Check: systemctl status fail2ban"
fi

log "Installed jail: ${JAIL_TARGET}"
log "Installed logrotate: ${LOGROTATE_TARGET}"
log "Asterisk log: ${ASTERISK_LOG_PATH}"
log "Ignored IPs: ${IGNORE_IP}"

fail2ban-client status asterisk-freepbx || fail2ban-client status

cat <<EOF

fail2ban is active for SIP brute-force protection.

Useful commands:
  fail2ban-client status asterisk-freepbx
  fail2ban-client set asterisk-freepbx unbanip <IP>
  fail2ban-regex ${ASTERISK_LOG_PATH} /etc/fail2ban/filter.d/asterisk.conf

Add trusted subnets to ${ENV_FILE}:
  FAIL2BAN_IGNORE_IP=127.0.0.1/8,::1,10.0.0.0/8

Then rerun:
  sudo ${ROOT_DIR}/docker/fail2ban/install.sh

EOF
