#!/usr/bin/env bash
# Write manager_custom.conf from environment and optionally reload Asterisk manager.

load_freepbx_db_config() {
  if [ ! -f /etc/freepbx.conf ]; then
    return 0
  fi

  local key value
  for key in AMPDBHOST AMPDBPORT AMPDBUSER AMPDBPASS AMPDBNAME; do
    value="$(grep -E "\\['${key}'\\]" /etc/freepbx.conf 2>/dev/null \
      | sed -n "s/.*= '\([^']*\)'.*/\1/p" \
      | head -n 1)"
    [ -n "${value}" ] || continue
    case "${key}" in
      AMPDBHOST) FREEPBX_DB_HOST="${value}" ;;
      AMPDBPORT) FREEPBX_DB_PORT="${value}" ;;
      AMPDBUSER) FREEPBX_DB_USER="${value}" ;;
      AMPDBPASS) FREEPBX_DB_PASS="${value}" ;;
      AMPDBNAME) FREEPBX_DB_NAME="${value}" ;;
    esac
  done
}

get_freepbx_db_setting() {
  local keyword="$1"

  load_freepbx_db_config

  mariadb \
    -h "${FREEPBX_DB_HOST:-127.0.0.1}" \
    -P "${FREEPBX_DB_PORT:-3307}" \
    -u "${FREEPBX_DB_USER:-freepbx}" \
    -p"${FREEPBX_DB_PASS:-freepbx}" \
    "${FREEPBX_DB_NAME:-asterisk}" \
    -N -e "SELECT value FROM freepbx_settings WHERE keyword='${keyword}' LIMIT 1;" \
    2>/dev/null || true
}

asterisk_manager_user_ready() {
  local user="$1"

  command -v asterisk >/dev/null 2>&1 \
    && /usr/sbin/asterisk -rx "core show version" >/dev/null 2>&1 \
    && /usr/sbin/asterisk -rx "manager show user ${user}" 2>/dev/null \
      | grep -q "Username:[[:space:]]*${user}"
}

manager_conf_matches_db() {
  local user="$1"
  local pass="$2"
  local current_user current_secret

  current_user="$(awk '
    function is_internal_user_header(line, header) {
      header = line
      sub(/^\[/, "", header)
      sub(/\]$/, "", header)
      return length(header) == 32 && header ~ /^[0-9a-f]+$/
    }

    is_internal_user_header($0) {
      header = $0
      sub(/^\[/, "", header)
      sub(/\]$/, "", header)
      print header
      exit
    }
  ' /etc/asterisk/manager.conf)"

  [ "${current_user}" = "${user}" ] || return 1

  current_secret="$(awk -v user="${user}" '
    function is_internal_user_header(line, header) {
      header = line
      sub(/^\[/, "", header)
      sub(/\]$/, "", header)
      return length(header) == 32 && header ~ /^[0-9a-f]+$/
    }

    is_internal_user_header($0) {
      current = $0
      sub(/^\[/, "", current)
      sub(/\]$/, "", current)
      if (current == user) {
        in_block = 1
      }
      next
    }
    in_block && /^\[/ { exit }
    in_block && /^secret = / {
      sub(/^secret = /, "", $0)
      print $0
      exit
    }
  ' /etc/asterisk/manager.conf)"

  [ "${current_secret}" = "${pass}" ]
}

sync_freepbx_manager_user() {
  if [ ! -f /etc/asterisk/manager.conf ] || [ ! -f /etc/freepbx.conf ]; then
    return 0
  fi

  local user pass tmp

  user="$(get_freepbx_db_setting AMPMGRUSER)"
  pass="$(get_freepbx_db_setting AMPMGRPASS)"

  [ -n "${user}" ] && [ -n "${pass}" ] || return 0

  if manager_conf_matches_db "${user}" "${pass}" \
    && asterisk_manager_user_ready "${user}"; then
    return 0
  fi

  tmp="$(mktemp)"
  awk -v user="${user}" -v secret="${pass}" '
    BEGIN { replaced = 0; skip_block = 0 }

    function print_user_block() {
      print "[" user "]"
      print "secret = " secret
      print "deny=0.0.0.0/0.0.0.0"
      print "permit=127.0.0.1/255.255.255.0"
      print "read = system,call,log,verbose,command,agent,user,config,command,dtmf,reporting,cdr,dialplan,originate,message"
      print "write = system,call,log,verbose,command,agent,user,config,command,dtmf,reporting,cdr,dialplan,originate,message"
      print "writetimeout = 5000"
    }

    function is_internal_user_header(line,    header) {
      header = line
      sub(/^\[/, "", header)
      sub(/\]$/, "", header)
      return length(header) == 32 && header ~ /^[0-9a-f]+$/
    }

    is_internal_user_header($0) {
      if (!replaced) {
        print_user_block()
        replaced = 1
      }
      skip_block = 1
      next
    }

    skip_block && (/^\[/ || /^#include/) {
      skip_block = 0
    }

    skip_block {
      next
    }

    {
      print
    }

    END {
      if (!replaced) {
        print ""
        print_user_block()
      }
    }
  ' /etc/asterisk/manager.conf > "${tmp}"

  mv "${tmp}" /etc/asterisk/manager.conf
  chmod 640 /etc/asterisk/manager.conf
  chown asterisk:asterisk /etc/asterisk/manager.conf 2>/dev/null || true
}

ensure_asterisk_ami() {
  if [ "${ASTERISK_AMI_ENABLED:-1}" != "1" ]; then
    return 0
  fi

  export ASTERISK_AMI_BINDADDR="${ASTERISK_AMI_BINDADDR:-127.0.0.1}"
  export ASTERISK_AMI_PORT="${ASTERISK_AMI_PORT:-5038}"
  export ASTERISK_AMI_USER="${ASTERISK_AMI_USER:-admin}"
  export ASTERISK_AMI_PASSWORD="${ASTERISK_AMI_PASSWORD:-admin}"
  export ASTERISK_AMI_PERMIT="${ASTERISK_AMI_PERMIT:-127.0.0.0/255.0.0.0}"

  mkdir -p /etc/asterisk

  local permit_lines=""
  local item

  IFS=',' read -ra permit_list <<< "${ASTERISK_AMI_PERMIT}"
  for item in "${permit_list[@]}"; do
    item="${item#"${item%%[![:space:]]*}"}"
    item="${item%"${item##*[![:space:]]}"}"
    [ -n "${item}" ] || continue
    permit_lines+="permit = ${item}"$'\n'
  done

  if [ -n "${ASTERISK_AMI_PERMIT_EXTRA:-}" ]; then
    IFS=',' read -ra extra_list <<< "${ASTERISK_AMI_PERMIT_EXTRA}"
    for item in "${extra_list[@]}"; do
      item="${item#"${item%%[![:space:]]*}"}"
      item="${item%"${item##*[![:space:]]}"}"
      [ -n "${item}" ] || continue
      permit_lines+="permit = ${item}"$'\n'
    done
  fi

  # Host-networked deployments often reach AMI via the server's public/LAN IP.
  # Skip docker0/br-* here — those are handled by ASTERISK_AMI_PERMIT_DOCKER.
  if [ "${ASTERISK_AMI_PERMIT_HOST_IPS:-1}" = "1" ]; then
    local ip iface
    while read -r iface ip; do
      case "${iface}" in
        lo|docker0|br-*) continue ;;
      esac
      [[ "${ip}" == 127.* ]] && continue
      permit_lines+="permit = ${ip}/255.255.255.255"$'\n'
    done < <(ip -o -4 addr show 2>/dev/null | awk '{iface=$2; gsub(/:$/,"",iface); ip=$4; sub(/\/.*/,"",ip); print iface, ip}')
  fi

  # Same-host Docker workers reach host AMI from compose bridge gateways.
  # Auto-permit docker0/br-* /24 subnets so ACL stays portable across hosts.
  if [ "${ASTERISK_AMI_PERMIT_DOCKER:-1}" = "1" ]; then
    local iface ip
    while read -r iface ip; do
      case "${iface}" in
        docker0|br-*)
          [ -n "${ip}" ] || continue
          # Convert x.y.z.g -> x.y.z.0/24 (compose bridges are /24 by default).
          permit_lines+="permit = ${ip%.*}.0/255.255.255.0"$'\n'
          ;;
      esac
    done < <(ip -o -4 addr show 2>/dev/null | awk '{iface=$2; gsub(/:$/,"",iface); ip=$4; sub(/\/.*/,"",ip); print iface, ip}')
  fi

  cat > /etc/asterisk/manager_custom.conf <<EOF_MANAGER_CUSTOM
[${ASTERISK_AMI_USER}]
secret = ${ASTERISK_AMI_PASSWORD}
deny = 0.0.0.0/0.0.0.0
${permit_lines}read = system,call,log,verbose,command,agent,user,config,dtmf,reporting,cdr,dialplan,originate,message
write = system,call,log,verbose,command,agent,user,config,dtmf,reporting,cdr,dialplan,originate,message
EOF_MANAGER_CUSTOM

  chmod 640 /etc/asterisk/manager_custom.conf
  chown asterisk:asterisk /etc/asterisk/manager_custom.conf 2>/dev/null || true

  # Keep AMI reachable from same-host Docker networks when bindaddr is widened.
  # FreePBX owns manager.conf; put bindaddr/port into the included custom file.
  cat > /etc/asterisk/manager_general_custom.conf <<EOF_MANAGER_GENERAL_CUSTOM
bindaddr = ${ASTERISK_AMI_BINDADDR}
port = ${ASTERISK_AMI_PORT}
EOF_MANAGER_GENERAL_CUSTOM
  chmod 640 /etc/asterisk/manager_general_custom.conf
  chown asterisk:asterisk /etc/asterisk/manager_general_custom.conf 2>/dev/null || true

  # FreePBX owns manager.conf after install; only seed it on first boot.
  if [ ! -f /data/.freepbx-installed ]; then
    touch \
      /etc/asterisk/manager_general_additional.conf \
      /etc/asterisk/manager_general_custom.conf \
      /etc/asterisk/manager_additional.conf

    cat > /etc/asterisk/manager.conf <<EOF_MANAGER
[general]
enabled = yes
port = ${ASTERISK_AMI_PORT}
bindaddr = ${ASTERISK_AMI_BINDADDR}
displayconnects = yes

#include manager_general_additional.conf
#include manager_general_custom.conf
#include manager_additional.conf
#include manager_custom.conf
EOF_MANAGER

    chmod 640 /etc/asterisk/manager.conf
  fi
}

reload_asterisk_ami() {
  if [ "${ASTERISK_AMI_ENABLED:-1}" != "1" ]; then
    return 0
  fi
  if command -v asterisk >/dev/null 2>&1 \
    && /usr/sbin/asterisk -rx "core show version" >/dev/null 2>&1; then
    /usr/sbin/asterisk -rx "manager reload" >/dev/null 2>&1 || true
  fi
}
