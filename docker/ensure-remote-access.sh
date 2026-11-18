#!/usr/bin/env bash
# Ensure freepbx DB users for FreePBX (loopback) and same-host Docker clients.
# Private-net grants (10.% / 172.% / 192.168.%) are always enabled so a Connector
# container can use host.docker.internal without flipping a switch.
# FREEPBX_DB_ALLOW_REMOTE=1 additionally enables user@'%' (true remote; firewall it).
set -euo pipefail

db_user="${MYSQL_USER:?MYSQL_USER is required}"
db_pass="${MYSQL_PASSWORD:?MYSQL_PASSWORD is required}"
db_name="${MYSQL_DATABASE:?MYSQL_DATABASE is required}"
cdr_db_name="${FREEPBX_CDR_DB_NAME:-asteriskcdrdb}"
root_pass="${MYSQL_ROOT_PASSWORD:?MYSQL_ROOT_PASSWORD is required}"
allow_remote="${FREEPBX_DB_ALLOW_REMOTE:-0}"

for _ in $(seq 1 120); do
  if mariadb-admin ping -h127.0.0.1 -uroot -p"${root_pass}" --silent >/dev/null 2>&1; then
    break
  fi
  sleep 1
done

if ! mariadb-admin ping -h127.0.0.1 -uroot -p"${root_pass}" --silent >/dev/null 2>&1; then
  echo "MariaDB is not ready; skipping remote access setup." >&2
  exit 0
fi

mariadb -uroot -p"${root_pass}" <<SQL
CREATE DATABASE IF NOT EXISTS \`${cdr_db_name}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;

CREATE USER IF NOT EXISTS '${db_user}'@'localhost' IDENTIFIED BY '${db_pass}';
CREATE USER IF NOT EXISTS '${db_user}'@'127.0.0.1' IDENTIFIED BY '${db_pass}';
CREATE USER IF NOT EXISTS '${db_user}'@'172.%' IDENTIFIED BY '${db_pass}';
CREATE USER IF NOT EXISTS '${db_user}'@'10.%' IDENTIFIED BY '${db_pass}';
CREATE USER IF NOT EXISTS '${db_user}'@'192.168.%' IDENTIFIED BY '${db_pass}';

ALTER USER '${db_user}'@'localhost' IDENTIFIED BY '${db_pass}';
ALTER USER '${db_user}'@'127.0.0.1' IDENTIFIED BY '${db_pass}';
ALTER USER '${db_user}'@'172.%' IDENTIFIED BY '${db_pass}';
ALTER USER '${db_user}'@'10.%' IDENTIFIED BY '${db_pass}';
ALTER USER '${db_user}'@'192.168.%' IDENTIFIED BY '${db_pass}';

GRANT ALL PRIVILEGES ON \`${db_name}\`.* TO '${db_user}'@'localhost';
GRANT ALL PRIVILEGES ON \`${cdr_db_name}\`.* TO '${db_user}'@'localhost';
GRANT ALL PRIVILEGES ON \`${db_name}\`.* TO '${db_user}'@'127.0.0.1';
GRANT ALL PRIVILEGES ON \`${cdr_db_name}\`.* TO '${db_user}'@'127.0.0.1';
GRANT ALL PRIVILEGES ON \`${db_name}\`.* TO '${db_user}'@'172.%';
GRANT ALL PRIVILEGES ON \`${cdr_db_name}\`.* TO '${db_user}'@'172.%';
GRANT ALL PRIVILEGES ON \`${db_name}\`.* TO '${db_user}'@'10.%';
GRANT ALL PRIVILEGES ON \`${cdr_db_name}\`.* TO '${db_user}'@'10.%';
GRANT ALL PRIVILEGES ON \`${db_name}\`.* TO '${db_user}'@'192.168.%';
GRANT ALL PRIVILEGES ON \`${cdr_db_name}\`.* TO '${db_user}'@'192.168.%';

FLUSH PRIVILEGES;
SQL

case "${allow_remote}" in
  1|true|TRUE|yes|YES)
    mariadb -uroot -p"${root_pass}" <<SQL
CREATE USER IF NOT EXISTS '${db_user}'@'%' IDENTIFIED BY '${db_pass}';
ALTER USER '${db_user}'@'%' IDENTIFIED BY '${db_pass}';
GRANT ALL PRIVILEGES ON \`${db_name}\`.* TO '${db_user}'@'%';
GRANT ALL PRIVILEGES ON \`${cdr_db_name}\`.* TO '${db_user}'@'%';
FLUSH PRIVILEGES;
SQL
    echo "[ensure-remote-access] private-net grants + ${db_user}@% (FREEPBX_DB_ALLOW_REMOTE=1)"
    ;;
  *)
    mariadb -uroot -p"${root_pass}" <<SQL
DROP USER IF EXISTS '${db_user}'@'%';
FLUSH PRIVILEGES;
SQL
    echo "[ensure-remote-access] private-net grants enabled (${db_user}@localhost/127.0.0.1/10%/172%/192.168%)"
    ;;
esac
