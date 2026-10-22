#!/usr/bin/env bash
# Shared helpers and TUI for the FreePBX + Asterisk Docker installer.

set -euo pipefail

if [[ -z "${REPO_ROOT:-}" ]]; then
  _SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  REPO_ROOT="$(cd "${_SCRIPT_DIR}/../.." && pwd)"
fi

PRODUCT_NAME="FreePBX + Asterisk"
PRODUCT_SLUG="asterisk-docker"
GHCR_IMAGE="ghcr.io/astrum-studio/asterisk-docker"
DEFAULT_PORT="8080"

# ─── Colors (Astrum brand #2653F2) ───────────────────────────
_astrum_color_ok() {
  [[ "${NO_COLOR:-}" == "1" && -z "${FORCE_COLOR:-}" ]] && return 1
  [[ -t 1 ]] || [[ -n "${FORCE_COLOR:-}" ]] || return 1
  [[ "${TERM:-dumb}" == "dumb" ]] && return 1
  return 0
}

if _astrum_color_ok; then
  C_RESET='\033[0m'
  C_BOLD='\033[1m'
  C_DIM='\033[2m'
  C_BLUE='\033[38;5;27m'
  C_BLUE_H='\033[38;5;69m'
  C_WHITE='\033[38;5;255m'
  C_GREEN='\033[38;5;79m'
  C_YELLOW='\033[38;5;220m'
  C_RED='\033[38;5;203m'
  C_CYAN='\033[38;5;117m'
else
  C_RESET='' C_BOLD='' C_DIM='' C_BLUE='' C_BLUE_H='' C_WHITE=''
  C_GREEN='' C_YELLOW='' C_RED='' C_CYAN=''
fi

log_info()  { printf "  ${C_BLUE}›${C_RESET}  %s\n" "$*"; }
log_ok()    { printf "  ${C_GREEN}✔${C_RESET}  %s\n" "$*"; }
log_warn()  { printf "  ${C_YELLOW}⚠${C_RESET}  %s\n" "$*"; }
log_err()   { printf "  ${C_RED}✖${C_RESET}  %s\n" "$*" >&2; }

die() {
  log_err "$*"
  exit 1
}

log_step() {
  local current="$1" total="$2" title="$3"
  local i
  printf "\n  "
  for ((i = 1; i <= total; i++)); do
    if [[ "$i" -lt "$current" ]]; then
      printf "${C_GREEN}●${C_RESET} "
    elif [[ "$i" -eq "$current" ]]; then
      printf "${C_BLUE}●${C_RESET} "
    else
      printf "${C_DIM}○${C_RESET} "
    fi
  done
  printf " ${C_DIM}%d/%d${C_RESET}  ${C_BOLD}%s${C_RESET}\n" "${current}" "${total}" "${title}"
  printf "  ${C_DIM}────────────────────────────────────────────${C_RESET}\n"
}

ask_yes() {
  local prompt="$1"
  if [[ "${ASSUME_YES:-0}" -eq 1 ]]; then
    return 0
  fi
  printf "  ${C_BLUE}?${C_RESET}  %s ${C_DIM}[Y/n]${C_RESET} " "${prompt}" >&2
  read -r answer || true
  case "${answer:-Y}" in
    y|Y|yes|YES|'') return 0 ;;
    *) return 1 ;;
  esac
}

run_spinner() {
  local msg="$1"
  shift
  [[ "${1:-}" == "--" ]] && shift

  if [[ ! -t 1 ]] || [[ "${NO_COLOR:-}" == "1" ]]; then
    log_info "${msg}"
    "$@"
    return $?
  fi

  local frames=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
  local logfile
  logfile="$(mktemp)"
  "$@" >"${logfile}" 2>&1 &
  local pid=$!
  local i=0

  while kill -0 "${pid}" 2>/dev/null; do
    printf "\r  ${C_BLUE}%s${C_RESET}  %s" "${frames[i % ${#frames[@]}]}" "${msg}"
    i=$((i + 1))
    sleep 0.08
  done

  local rc=0
  wait "${pid}" || rc=$?

  if [[ $rc -eq 0 ]]; then
    printf "\r  ${C_GREEN}✔${C_RESET}  %s\033[K\n" "${msg}"
  else
    printf "\r  ${C_RED}✖${C_RESET}  %s\033[K\n" "${msg}"
    cat "${logfile}" >&2 || true
  fi
  rm -f "${logfile}"
  return $rc
}

# Poll an HTTP URL until it responds or timeout.
wait_http() {
  local msg="$1"
  local url="$2"
  local max_sec="${3:-120}"
  local frames=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
  local i=0
  local start
  start="$(date +%s)"

  while true; do
    if curl -fsS -o /dev/null --max-time 3 "${url}" 2>/dev/null; then
      if [[ -t 1 ]]; then
        printf "\r  ${C_GREEN}✔${C_RESET}  %s\033[K\n" "${msg}"
      else
        log_ok "${msg}"
      fi
      return 0
    fi
    local now
    now="$(date +%s)"
    if [[ $((now - start)) -ge $max_sec ]]; then
      if [[ -t 1 ]]; then
        printf "\r  ${C_YELLOW}⚠${C_RESET}  %s\033[K\n" "${msg}"
      else
        log_warn "${msg}"
      fi
      return 1
    fi
    if [[ -t 1 ]]; then
      printf "\r  ${C_BLUE}%s${C_RESET}  %s" "${frames[i % ${#frames[@]}]}" "${msg}"
    fi
    i=$((i + 1))
    sleep 0.5
  done
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Команда не найдена: $1"
}

gen_password() {
  local len="${1:-32}"
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -base64 48 | tr -d '/+=' | head -c "${len}"
    return
  fi
  if [[ -r /dev/urandom ]]; then
    tr -dc 'A-Za-z0-9' </dev/urandom | head -c "${len}"
    return
  fi
  die "Не удалось сгенерировать секрет (нужен openssl или /dev/urandom)"
}

detect_os_family() {
  if [[ -f /etc/os-release ]]; then
    # shellcheck source=/dev/null
    . /etc/os-release
    case "${ID,,}" in
      ubuntu|debian|linuxmint|pop|elementary) echo debian ;;
      rhel|centos|rocky|almalinux|ol) echo rhel ;;
      fedora) echo fedora ;;
      amzn) echo amzn ;;
      arch|manjaro|endeavouros) echo arch ;;
      *)
        case "${ID_LIKE,,}" in
          *debian*) echo debian ;;
          *rhel*|*fedora*) echo rhel ;;
          *arch*) echo arch ;;
          *) echo unknown ;;
        esac
        ;;
    esac
    return
  fi
  echo unknown
}

os_pretty_name() {
  if [[ -f /etc/os-release ]]; then
    # shellcheck source=/dev/null
    . /etc/os-release
    echo "${PRETTY_NAME:-$ID}"
    return
  fi
  uname -s
}

has_docker() { command -v docker >/dev/null 2>&1; }
has_compose() { docker compose version >/dev/null 2>&1; }
docker_usable() { has_docker && docker info >/dev/null 2>&1; }

detect_public_host() {
  local ip
  ip="$(hostname -I 2>/dev/null | awk '{print $1}' || true)"
  if [[ -n "${ip}" && "${ip}" != "127.0.0.1" ]]; then
    printf '%s' "${ip}"
    return
  fi
  ip="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i=1;i<=NF;i++) if ($i=="src") {print $(i+1); exit}}' || true)"
  if [[ -n "${ip}" ]]; then
    printf '%s' "${ip}"
    return
  fi
  printf '127.0.0.1'
}

require_root_or_sudo() {
  if [[ "${EUID}" -eq 0 ]]; then
    SUDO=""
    return
  fi
  if command -v sudo >/dev/null 2>&1; then
    SUDO="sudo"
    return
  fi
  die "Нужны права root или sudo для установки Docker"
}

env_set() {
  local file="$1" key="$2" value="$3"
  if grep -qE "^${key}=" "${file}"; then
    local escaped
    escaped="$(printf '%s' "${value}" | sed -e 's/[\/&]/\\&/g')"
    sed -i.bak -E "s|^${key}=.*|${key}=${escaped}|" "${file}"
    rm -f "${file}.bak"
  else
    printf '\n%s=%s\n' "${key}" "${value}" >>"${file}"
  fi
}

env_get() {
  local file="$1" key="$2"
  grep -E "^${key}=" "${file}" 2>/dev/null | head -1 | cut -d= -f2-
}

# Planned value: CLI override > existing .env > default.
env_planned() {
  local key="$1" cli_value="$2" cli_set="$3" default="$4" env_file="${5:-}"
  if [[ "${cli_set}" -eq 1 && -n "${cli_value}" ]]; then
    printf '%s' "${cli_value}"
    return
  fi
  if [[ -n "${env_file}" && -f "${env_file}" ]]; then
    local from_env
    from_env="$(env_get "${env_file}" "${key}" || true)"
    if [[ -n "${from_env}" ]]; then
      printf '%s' "${from_env}"
      return
    fi
  fi
  printf '%s' "${default}"
}

detect_arch() {
  local arch
  arch="$(uname -m)"
  case "${arch}" in
    x86_64|amd64) echo x86_64 ;;
    aarch64|arm64) echo aarch64 ;;
    *) echo "${arch}" ;;
  esac
}

arch_supported() {
  case "$(detect_arch)" in
    x86_64|aarch64) return 0 ;;
    *) return 1 ;;
  esac
}

arch_ghcr_compatible() {
  [[ "$(detect_arch)" == "x86_64" ]]
}

print_kv() {
  local pad=$((22 - ${#1}))
  ((pad < 1)) && pad=1
  printf "  ${C_DIM}%s%*s${C_RESET} %b" "$1" "${pad}" "" "$2"
  [[ -n "${3:-}" ]] && printf "  ${C_DIM}%b${C_RESET}" "$3"
  printf '\n'
}

print_plan_header() {
  printf "\n  ${C_BOLD}План установки${C_RESET}\n"
  printf "  ${C_DIM}────────────────────────────────────────────${C_RESET}\n"
}

free_disk_gb() {
  local path="${1:-.}"
  local kb
  kb="$(df -Pk "${path}" 2>/dev/null | awk 'NR==2 {print $4}' || true)"
  [[ -z "${kb}" ]] && echo 0 && return
  echo $((kb / 1024 / 1024))
}

port_in_use_tcp() {
  local port="$1"
  if command -v ss >/dev/null 2>&1; then
    ss -ltn "( sport = :${port} )" 2>/dev/null | grep -q ":${port}" && return 0
    return 1
  fi
  if command -v lsof >/dev/null 2>&1; then
    lsof -iTCP:"${port}" -sTCP:LISTEN >/dev/null 2>&1 && return 0
  fi
  return 1
}

port_in_use_udp() {
  local port="$1"
  if command -v ss >/dev/null 2>&1; then
    ss -lun "( sport = :${port} )" 2>/dev/null | grep -q ":${port}" && return 0
    return 1
  fi
  if command -v lsof >/dev/null 2>&1; then
    lsof -iUDP:"${port}" >/dev/null 2>&1 && return 0
  fi
  return 1
}

rtp_range_listener_count() {
  local start="$1" finish="$2"
  local count=0
  if command -v ss >/dev/null 2>&1; then
    count="$(ss -lun 2>/dev/null | awk -v s="${start}" -v f="${finish}" '
      $5 ~ /:[0-9]+$/ {
        split($5, a, ":");
        p = a[length(a)];
        if (p >= s && p <= f) c++
      }
      END { print c+0 }
    ')"
    printf '%s' "${count:-0}"
    return
  fi
  printf '0'
}

freepbx_stack_running() {
  if ! docker_usable; then
    return 1
  fi
  docker ps --format '{{.Names}}' 2>/dev/null | grep -qx 'freepbx' \
    || docker ps --format '{{.Names}}' 2>/dev/null | grep -qx 'freepbx-db'
}

# Preflight before Docker install and .env writes. Exits on hard failures.
run_install_preflight() {
  local repo_root="$1"
  local env_file="$2"
  local use_dev="$3"
  local http_port="$4"
  local db_port="$5"
  local ami_enabled="$6"
  local ami_port="$7"
  local rtp_start="$8"
  local rtp_finish="$9"
  local image_tag="${10}"

  local family disk_gb upgrade=0
  family="$(detect_os_family)"

  if [[ "${family}" == "unknown" ]]; then
    die "ОС не поддерживается автоустановкой Docker. Установите Docker вручную: https://docs.docker.com/engine/install/"
  fi
  log_ok "$(os_pretty_name) · $(detect_arch)"

  if ! arch_supported; then
    die "Архитектура $(uname -m) не поддерживается (нужны x86_64 или aarch64)."
  fi

  if [[ "${use_dev}" -eq 0 ]] && ! arch_ghcr_compatible; then
    die "Образ GHCR собран только для linux/amd64. На этой машине используйте ./install.sh --dev (локальная сборка)."
  fi
  if [[ "${use_dev}" -eq 1 ]] && ! arch_ghcr_compatible; then
    log_warn "GHCR-образ только amd64 — для этой архитектуры будет локальная сборка (--dev)"
  fi

  disk_gb="$(free_disk_gb "${repo_root}")"
  if [[ "${disk_gb}" -lt 8 ]]; then
    die "Мало свободного места: ${disk_gb} ГБ (нужно минимум 8 ГБ в ${repo_root})."
  fi
  if [[ "${use_dev}" -eq 1 && "${disk_gb}" -lt 15 ]]; then
    log_warn "Для локальной сборки рекомендуется ≥15 ГБ свободно (сейчас ~${disk_gb} ГБ)"
  else
    log_ok "Диск · ~${disk_gb} ГБ свободно"
  fi

  if freepbx_stack_running; then
    upgrade=1
    log_ok "Обнаружен запущенный стек freepbx (обновление / повторный запуск)"
  fi

  local proto p
  for p in 5060 5061; do
    if [[ "${upgrade}" -eq 0 ]]; then
      for proto in tcp udp; do
        if [[ "${proto}" == "tcp" ]] && port_in_use_tcp "${p}"; then
          die "Порт SIP ${p}/tcp занят. Остановите другой SIP-сервер или освободите порт."
        fi
        if [[ "${proto}" == "udp" ]] && port_in_use_udp "${p}"; then
          die "Порт SIP ${p}/udp занят. Остановите другой SIP-сервер или освободите порт."
        fi
      done
    fi
  done

  if [[ "${ami_enabled}" != "0" && "${upgrade}" -eq 0 ]] && port_in_use_tcp "${ami_port}"; then
    die "Порт AMI ${ami_port}/tcp занят. Измените ASTERISK_AMI_PORT в .env или освободите порт."
  fi

  if [[ "${upgrade}" -eq 0 ]] && port_in_use_tcp "${http_port}"; then
    if [[ "${ASSUME_YES:-0}" -eq 1 ]]; then
      die "Порт HTTP ${http_port}/tcp занят. Укажите другой: ./install.sh --port N"
    fi
    log_warn "Порт HTTP ${http_port}/tcp уже слушается"
    ask_yes "Продолжить с портом ${http_port}?" || die "Отменено. Укажите свободный порт: --port N"
  fi

  if [[ "${upgrade}" -eq 0 ]] && port_in_use_tcp "${db_port}"; then
    if [[ "${ASSUME_YES:-0}" -eq 1 ]]; then
      die "Порт MariaDB ${db_port}/tcp занят. Измените FREEPBX_DB_PORT в .env."
    fi
    log_warn "Порт MariaDB ${db_port}/tcp уже слушается"
    ask_yes "Продолжить с портом ${db_port}?" || die "Отменено. Измените FREEPBX_DB_PORT в .env."
  fi

  local rtp_listeners
  rtp_listeners="$(rtp_range_listener_count "${rtp_start}" "${rtp_finish}")"
  if [[ "${rtp_listeners}" -gt 0 ]]; then
    log_warn "В диапазоне RTP ${rtp_start}-${rtp_finish} уже есть ~${rtp_listeners} UDP-слушателей"
  fi

  local mode_label
  if [[ "${use_dev}" -eq 1 ]]; then
    mode_label="разработка (локальная сборка)"
  else
    mode_label="production (GHCR ${image_tag})"
  fi

  print_plan_header
  print_kv "Каталог" "${repo_root}"
  print_kv "Режим" "${mode_label}"
  print_kv "HTTP" "${http_port}/tcp"
  print_kv "MariaDB" "${db_port}/tcp (bind из .env)"
  print_kv "SIP" "5060–5061 tcp+udp"
  if [[ "${ami_enabled}" != "0" ]]; then
    print_kv "AMI" "${ami_port}/tcp"
  else
    print_kv "AMI" "отключён"
  fi
  print_kv "RTP" "${rtp_start}-${rtp_finish}/udp"
  printf '\n'

  ask_yes "Продолжить установку?" || {
    log_warn "Отменено — система не изменена"
    exit 0
  }
}

print_banner() {
  printf '\n'
  printf "  ${C_BLUE}      ╱╲${C_RESET}\n"
  printf "  ${C_BLUE}     ╱  ╲${C_RESET}      ${C_WHITE}${C_BOLD}astrum${C_RESET}\n"
  printf "  ${C_BLUE}    ╱────╲${C_RESET}          ${C_DIM}AGENCY${C_RESET}\n"
  printf "\n"
  printf "  ${C_BLUE}──────────────────────────────────────────${C_RESET}\n"
  printf "  ${C_BOLD}${C_WHITE}${PRODUCT_NAME}${C_RESET}\n"
  printf "  ${C_DIM}FreePBX · Asterisk · Docker · open source${C_RESET}\n"
  printf "  ${C_DIM}by${C_RESET} ${C_BLUE}Astrum Agency${C_RESET}  ${C_DIM}astrum.agency${C_RESET}\n"
  printf "  ${C_BLUE}──────────────────────────────────────────${C_RESET}\n\n"
}

print_meta() {
  local os docker_v
  os="$(os_pretty_name)"
  if has_docker; then
    docker_v="$(docker --version 2>/dev/null | sed 's/Docker version //;s/,.*//')"
  else
    docker_v="не установлен"
  fi
  printf "  ${C_DIM}┌────────────────────────────────────────────┐${C_RESET}\n"
  printf "  ${C_DIM}│${C_RESET}  ${C_DIM}OS${C_RESET}       ${C_WHITE}%-32s${C_RESET}${C_DIM}│${C_RESET}\n" "${os:0:32}"
  printf "  ${C_DIM}│${C_RESET}  ${C_DIM}Docker${C_RESET}   ${C_WHITE}%-32s${C_RESET}${C_DIM}│${C_RESET}\n" "${docker_v:0:32}"
  printf "  ${C_DIM}│${C_RESET}  ${C_DIM}Path${C_RESET}     ${C_WHITE}%-32s${C_RESET}${C_DIM}│${C_RESET}\n" "${REPO_ROOT:0:32}"
  printf "  ${C_DIM}└────────────────────────────────────────────┘${C_RESET}\n"
}

print_success_card() {
  local host="$1" port="$2" image_tag="$3" compose_cmd="$4" mode="$5"
  printf "\n"
  printf "  ${C_GREEN}╭────────────────────────────────────────────────╮${C_RESET}\n"
  printf "  ${C_GREEN}│${C_RESET}  ${C_BOLD}✔  ${PRODUCT_NAME} установлен и запущен.${C_RESET}    ${C_GREEN}│${C_RESET}\n"
  printf "  ${C_GREEN}╰────────────────────────────────────────────────╯${C_RESET}\n"
  printf "\n"
  printf "  ${C_BOLD}Веб-интерфейс${C_RESET}  ${C_CYAN}http://%s:%s/admin${C_RESET}\n" "${host}" "${port}"
  printf "  ${C_BOLD}Режим${C_RESET}         ${C_DIM}%s${C_RESET}\n" "${mode}"
  printf "  ${C_BOLD}Образ${C_RESET}         ${C_DIM}%s:%s${C_RESET}\n" "${GHCR_IMAGE}" "${image_tag}"
  printf "\n"
  printf "  ${C_BOLD}Полезные команды:${C_RESET}\n"
  printf "    ${C_DIM}%s logs -f freepbx${C_RESET}\n" "${compose_cmd}"
  printf "    ${C_DIM}%s ps${C_RESET}\n" "${compose_cmd}"
  printf "    ${C_DIM}%s exec freepbx asterisk -rvvv${C_RESET}\n" "${compose_cmd}"
  printf "\n"
  printf "  ${C_BOLD}Сброс при ошибке:${C_RESET}\n"
  printf "    ${C_DIM}%s down${C_RESET}\n" "${compose_cmd}"
  printf "    ${C_DIM}sudo rm -rf mysql/* asterisk/* www/* data/*${C_RESET}\n"
  printf "    ${C_DIM}./install.sh${C_RESET}\n"
  printf "\n"
  printf "  ${C_BLUE}✦${C_RESET}  ${C_DIM}Astrum Agency · https://astrum.agency${C_RESET}\n\n"
}
