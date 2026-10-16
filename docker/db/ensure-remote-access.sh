#!/usr/bin/env bash
set -euo pipefail

db_user="${MYSQL_USER:?MYSQL_USER is required}"
db_pass="${MYSQL_PASSWORD:?MYSQL_PASSWORD is required}"
db_name="${MYSQL_DATABASE:?MYSQL_DATABASE is required}"
cdr_db_name="${FREEPBX_CDR_DB_NAME:-asteriskcdrdb}"
root_pass="${MYSQL_ROOT_PASSWORD:?MYSQL_ROOT_PASSWORD is required}"

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

CREATE USER IF NOT EXISTS '${db_user}'@'%' IDENTIFIED BY '${db_pass}';
CREATE USER IF NOT EXISTS '${db_user}'@'localhost' IDENTIFIED BY '${db_pass}';

ALTER USER '${db_user}'@'%' IDENTIFIED BY '${db_pass}';
ALTER USER '${db_user}'@'localhost' IDENTIFIED BY '${db_pass}';

GRANT ALL PRIVILEGES ON \`${db_name}\`.* TO '${db_user}'@'%';
GRANT ALL PRIVILEGES ON \`${cdr_db_name}\`.* TO '${db_user}'@'%';
GRANT ALL PRIVILEGES ON \`${db_name}\`.* TO '${db_user}'@'localhost';
GRANT ALL PRIVILEGES ON \`${cdr_db_name}\`.* TO '${db_user}'@'localhost';

FLUSH PRIVILEGES;
SQL
