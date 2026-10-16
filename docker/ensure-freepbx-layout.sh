#!/usr/bin/env bash
# FreePBX expects runtime files under /var/lib/asterisk/{bin,agi-bin}.
# The image only links /usr/sbin; without these paths fwconsole/reload and
# integrity checks fail and astdb is never rebuilt from MariaDB.

set -euo pipefail

FREEPBX_ROOT="${FREEPBX_ROOT:-/usr/src/freepbx}"
AMP_CONF="${FREEPBX_ROOT}/amp_conf"

ensure_dir_links() {
  local src_dir="$1"
  local dest_dir="$2"

  [ -d "${src_dir}" ] || return 0
  mkdir -p "${dest_dir}"
  for f in "${src_dir}"/*; do
    [ -f "${f}" ] || continue
    ln -sfn "${f}" "${dest_dir}/$(basename "${f}")"
  done
}

ensure_dir_links "${AMP_CONF}/bin" /var/lib/asterisk/bin
ensure_dir_links "${AMP_CONF}/agi-bin" /var/lib/asterisk/agi-bin
ensure_dir_links "${AMP_CONF}/bin" /usr/sbin
