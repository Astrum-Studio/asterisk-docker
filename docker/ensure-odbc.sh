#!/usr/bin/env bash
# Configure unixODBC DSN for Asterisk CDR/CEL adaptive ODBC backends.

ensure_odbc_config() {
  export FREEPBX_DB_HOST="${FREEPBX_DB_HOST:-127.0.0.1}"
  export FREEPBX_DB_PORT="${FREEPBX_DB_PORT:-3307}"
  export FREEPBX_CDR_DB_NAME="${FREEPBX_CDR_DB_NAME:-asteriskcdrdb}"
  export FREEPBX_DB_USER="${FREEPBX_DB_USER:-freepbx}"
  export FREEPBX_DB_PASS="${FREEPBX_DB_PASS:-freepbx}"

  local driver_path setup_path
  driver_path="$(find /usr/lib -name 'libmaodbc.so' 2>/dev/null | head -n 1)"
  setup_path="$(find /usr/lib -name 'libodbcmyS.so' 2>/dev/null | head -n 1)"

  if [ -z "${driver_path}" ]; then
    echo "[ensure-odbc] MariaDB ODBC driver not found; install odbc-mariadb." >&2
    return 1
  fi

  mkdir -p /etc

  cat > /etc/odbcinst.ini <<EOF_ODBCINST
[MySQL]
Description=ODBC for MariaDB
Driver=${driver_path}
EOF_ODBCINST

  if [ -n "${setup_path}" ]; then
    printf 'Setup=%s\nFileUsage=1\n' "${setup_path}" >> /etc/odbcinst.ini
  else
    printf 'FileUsage=1\n' >> /etc/odbcinst.ini
  fi

  cat > /etc/odbc.ini <<EOF_ODBC
[MySQL-asteriskcdrdb]
Description=MySQL connection to '${FREEPBX_CDR_DB_NAME}' database
Driver=MySQL
Server=${FREEPBX_DB_HOST}
Port=${FREEPBX_DB_PORT}
Database=${FREEPBX_CDR_DB_NAME}
Username=${FREEPBX_DB_USER}
Password=${FREEPBX_DB_PASS}
Option=3
EOF_ODBC

  chmod 644 /etc/odbc.ini /etc/odbcinst.ini
}

reload_asterisk_odbc() {
  if command -v asterisk >/dev/null 2>&1 \
    && /usr/sbin/asterisk -rx "core show version" >/dev/null 2>&1; then
    /usr/sbin/asterisk -rx "module reload res_odbc.so" >/dev/null 2>&1 || true
    /usr/sbin/asterisk -rx "module reload cdr_adaptive_odbc.so" >/dev/null 2>&1 || true
    /usr/sbin/asterisk -rx "module reload cel_odbc.so" >/dev/null 2>&1 || true
  fi
}
