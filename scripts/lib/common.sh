#!/usr/bin/env bash
# Shared helpers + Astrum TUI for FreePBX + Asterisk Docker installer.
# Style aligned with https://github.com/Astrum-Studio/bitrix24-converter-go

set -euo pipefail

if [[ -z "${REPO_ROOT:-}" ]]; then
  _SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  REPO_ROOT="$(cd "${_SCRIPT_DIR}/../.." && pwd)"
fi

PRODUCT_NAME="FreePBX + Asterisk"
PRODUCT_SLUG="bitrix24-asterisk-docker"
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
