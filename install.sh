#!/usr/bin/env bash
# FreePBX + Asterisk — one-shot installer.
#
#   ./install.sh
#   ./install.sh --yes
#   ./install.sh --tag 1.2.3 --port 8081
#   ./install.sh --dev --skip-build

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${SCRIPT_DIR}"

# shellcheck source=scripts/lib/common.sh
source "${REPO_ROOT}/scripts/lib/common.sh"

TOTAL_STEPS=4
ENV_FILE="${REPO_ROOT}/.env"

# ---------- Параметры по умолчанию ------------------------------------------
ASSUME_YES=0
SKIP_DOCKER=0
NO_START=0
FORCE_ENV=0
USE_DEV=0
USE_SG_DOCKER=0
SKIP_BUILD="${SKIP_BUILD:-0}"
PROJECT_NAME=""
PROJECT_NAME_FROM_CLI=0
PORT_FROM_CLI=0
TAG_FROM_CLI=0
DB_PORT_FROM_CLI=0
SIP_PORT_FROM_CLI=0
SIPS_PORT_FROM_CLI=0
SIP_LEGACY_PORT_FROM_CLI=0
AMI_PORT_FROM_CLI=0
AST_HTTP_PORT_FROM_CLI=0
AST_HTTPS_PORT_FROM_CLI=0
RTP_START_FROM_CLI=0
RTP_FINISH_FROM_CLI=0

IMAGE_TAG="latest"
HTTP_PORT="${DEFAULT_PORT}"
FREEPBX_DB_PORT="3307"
SIP_PORT="5060"
SIPS_PORT="5061"
SIP_LEGACY_PORT="5160"
ASTERISK_AMI_PORT="5038"
ASTERISK_HTTP_PORT="8088"
ASTERISK_HTTPS_PORT="8089"
RTP_START="10000"
RTP_FINISH="20000"

# ---------- Секреты и значения из .env ---------------------------------------
seed_env_secret() {
  local key="$1"
  shift
  local placeholders=("$@")
  local current=""

  current="$(env_get "${ENV_FILE}" "${key}" || true)"

  if [[ -n "${current}" ]]; then
    for ph in "${placeholders[@]}"; do
      if [[ "${current}" == "${ph}" ]]; then
        current=""
        break
      fi
    done
  fi

  if [[ -z "${current}" ]]; then
    env_set "${ENV_FILE}" "${key}" "$(gen_password 32)"
    log_ok "Сгенерирован ${key}"
  fi
}

resolve_env_config() {
  local env_port env_tag env_proj

  env_proj="$(env_get "${ENV_FILE}" COMPOSE_PROJECT_NAME || true)"
  env_port="$(env_get "${ENV_FILE}" HTTP_PORT || true)"
  env_tag="$(env_get "${ENV_FILE}" FREEPBX_IMAGE_TAG || true)"

  if [[ "${PROJECT_NAME_FROM_CLI}" -eq 1 ]]; then
    env_set "${ENV_FILE}" COMPOSE_PROJECT_NAME "${PROJECT_NAME}"
    log_ok "COMPOSE_PROJECT_NAME · ${PROJECT_NAME} (--name)"
  elif [[ -n "${env_proj}" ]]; then
    PROJECT_NAME="${env_proj}"
    log_ok "COMPOSE_PROJECT_NAME · ${PROJECT_NAME} (из .env)"
  else
    env_set "${ENV_FILE}" COMPOSE_PROJECT_NAME "${PLANNED_PROJECT_NAME}"
    PROJECT_NAME="${PLANNED_PROJECT_NAME}"
    log_ok "COMPOSE_PROJECT_NAME · ${PROJECT_NAME} (по умолчанию)"
  fi

  if [[ "${PORT_FROM_CLI}" -eq 1 ]]; then
    env_set "${ENV_FILE}" HTTP_PORT "${HTTP_PORT}"
    log_ok "HTTP_PORT · ${HTTP_PORT} (--port)"
  elif [[ -n "${env_port}" ]]; then
    HTTP_PORT="${env_port}"
    log_ok "HTTP_PORT · ${HTTP_PORT} (из .env)"
  else
    env_set "${ENV_FILE}" HTTP_PORT "${DEFAULT_PORT}"
    HTTP_PORT="${DEFAULT_PORT}"
    log_ok "HTTP_PORT · ${HTTP_PORT} (по умолчанию)"
  fi

  if [[ "${DB_PORT_FROM_CLI}" -eq 1 ]]; then
    env_set "${ENV_FILE}" FREEPBX_DB_PORT "${FREEPBX_DB_PORT}"
    log_ok "FREEPBX_DB_PORT · ${FREEPBX_DB_PORT} (--db-port)"
  fi

  if [[ "${SIP_PORT_FROM_CLI}" -eq 1 ]]; then
    env_set "${ENV_FILE}" SIP_PORT "${SIP_PORT}"
    log_ok "SIP_PORT · ${SIP_PORT} (--sip-port)"
  fi

  if [[ "${SIPS_PORT_FROM_CLI}" -eq 1 ]]; then
    env_set "${ENV_FILE}" SIPS_PORT "${SIPS_PORT}"
    log_ok "SIPS_PORT · ${SIPS_PORT} (--sips-port)"
  fi

  if [[ "${SIP_LEGACY_PORT_FROM_CLI}" -eq 1 ]]; then
    env_set "${ENV_FILE}" SIP_LEGACY_PORT "${SIP_LEGACY_PORT}"
    log_ok "SIP_LEGACY_PORT · ${SIP_LEGACY_PORT} (--sip-legacy-port)"
  fi

  if [[ "${AMI_PORT_FROM_CLI}" -eq 1 ]]; then
    env_set "${ENV_FILE}" ASTERISK_AMI_PORT "${ASTERISK_AMI_PORT}"
    log_ok "ASTERISK_AMI_PORT · ${ASTERISK_AMI_PORT} (--ami-port)"
  fi

  if [[ "${AST_HTTP_PORT_FROM_CLI}" -eq 1 ]]; then
    env_set "${ENV_FILE}" ASTERISK_HTTP_PORT "${ASTERISK_HTTP_PORT}"
    log_ok "ASTERISK_HTTP_PORT · ${ASTERISK_HTTP_PORT} (--ast-http-port)"
  fi

  if [[ "${AST_HTTPS_PORT_FROM_CLI}" -eq 1 ]]; then
    env_set "${ENV_FILE}" ASTERISK_HTTPS_PORT "${ASTERISK_HTTPS_PORT}"
    log_ok "ASTERISK_HTTPS_PORT · ${ASTERISK_HTTPS_PORT} (--ast-https-port)"
  fi

  if [[ "${RTP_START_FROM_CLI}" -eq 1 ]]; then
    env_set "${ENV_FILE}" RTP_START "${RTP_START}"
    log_ok "RTP_START · ${RTP_START} (--rtp-start)"
  fi

  if [[ "${RTP_FINISH_FROM_CLI}" -eq 1 ]]; then
    env_set "${ENV_FILE}" RTP_FINISH "${RTP_FINISH}"
    log_ok "RTP_FINISH · ${RTP_FINISH} (--rtp-finish)"
  fi

  if [[ "${TAG_FROM_CLI}" -eq 1 ]]; then
    env_set "${ENV_FILE}" FREEPBX_IMAGE_TAG "${IMAGE_TAG}"
    log_ok "FREEPBX_IMAGE_TAG · ${IMAGE_TAG} (--tag)"
  elif [[ -n "${env_tag}" ]]; then
    IMAGE_TAG="${env_tag}"
    log_ok "FREEPBX_IMAGE_TAG · ${IMAGE_TAG} (из .env)"
  else
    IMAGE_TAG="${IMAGE_TAG:-latest}"
    env_set "${ENV_FILE}" FREEPBX_IMAGE_TAG "${IMAGE_TAG}"
    log_ok "FREEPBX_IMAGE_TAG · ${IMAGE_TAG} (по умолчанию)"
  fi

  export FREEPBX_IMAGE_TAG="${IMAGE_TAG}"
  export COMPOSE_PROJECT_NAME="${PROJECT_NAME}"
}

# ---------- Чтение аргументов -----------------------------------------------
usage() {
  print_banner
  cat <<EOF
  ${C_BOLD}Установщик ${PRODUCT_NAME}${C_RESET}

  ${C_DIM}Использование:${C_RESET}  $(basename "$0") [опции]

  ${C_BLUE}-y, --yes${C_RESET}              без вопросов
  ${C_BLUE}--skip-docker${C_RESET}         Docker уже есть
  ${C_BLUE}--no-start${C_RESET}            только env, без контейнеров
  ${C_BLUE}--force-env${C_RESET}           перегенерировать секреты в .env
  ${C_BLUE}--dev${C_RESET}                 локальная сборка (docker-compose.dev.yml)
  ${C_BLUE}--tag${C_RESET} TAG             тег GHCR (default: из .env или latest)
  ${C_BLUE}--name${C_RESET} NAME           имя проекта / контейнера (default: freepbx)
  ${C_BLUE}--port${C_RESET} PORT           хост-порт веб-интерфейса (default: из .env или ${DEFAULT_PORT})
  ${C_BLUE}--db-port${C_RESET} PORT        хост-порт MariaDB (default: из .env или 3307)
  ${C_BLUE}--sip-port${C_RESET} PORT       порт PJSIP UDP/TCP (default: из .env или 5060)
  ${C_BLUE}--sips-port${C_RESET} PORT      порт PJSIP TLS (default: из .env или 5061)
  ${C_BLUE}--sip-legacy-port${C_RESET} P   порт chan_sip UDP (default: из .env или 5160)
  ${C_BLUE}--ami-port${C_RESET} PORT       порт Asterisk AMI (default: из .env или 5038)
  ${C_BLUE}--ast-http-port${C_RESET} PORT  порт Asterisk HTTP (default: из .env или 8088)
  ${C_BLUE}--ast-https-port${C_RESET} PORT порт Asterisk HTTPS/WSS (default: из .env или 8089)
  ${C_BLUE}--rtp-start${C_RESET} PORT      начало диапазона RTP (default: из .env или 10000)
  ${C_BLUE}--rtp-finish${C_RESET} PORT     конец диапазона RTP (default: из .env или 20000)
  ${C_BLUE}--skip-build${C_RESET}          пропустить build/pull (только запуск контейнеров)
  ${C_BLUE}-h, --help${C_RESET}             эта справка

  ${C_DIM}Шаги:${C_RESET}  проверка хоста → Docker → .env → pull/build & up

  ${C_DIM}Образ:${C_RESET}  ${GHCR_IMAGE}

  ${C_DIM}Без клона (one-liner):${C_RESET}
    curl -fsSL https://raw.githubusercontent.com/Astrum-Studio/asterisk-docker/main/scripts/autoinstaller.sh \\
      | sudo bash -s -- --yes

  ${C_DIM}Значения HTTP_PORT и FREEPBX_IMAGE_TAG из .env сохраняются,
  если не переданы явно через --port / --tag.${C_RESET}
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -y|--yes) ASSUME_YES=1; shift ;;
    --skip-docker) SKIP_DOCKER=1; shift ;;
    --no-start) NO_START=1; shift ;;
    --force-env) FORCE_ENV=1; shift ;;
    --dev) USE_DEV=1; shift ;;
    --tag) IMAGE_TAG="${2:-}"; TAG_FROM_CLI=1; shift 2 ;;
    --name|--project-name) PROJECT_NAME="${2:-}"; PROJECT_NAME_FROM_CLI=1; shift 2 ;;
    --port) HTTP_PORT="${2:-}"; PORT_FROM_CLI=1; shift 2 ;;
    --db-port) FREEPBX_DB_PORT="${2:-}"; DB_PORT_FROM_CLI=1; shift 2 ;;
    --sip-port) SIP_PORT="${2:-}"; SIP_PORT_FROM_CLI=1; shift 2 ;;
    --sips-port) SIPS_PORT="${2:-}"; SIPS_PORT_FROM_CLI=1; shift 2 ;;
    --sip-legacy-port) SIP_LEGACY_PORT="${2:-}"; SIP_LEGACY_PORT_FROM_CLI=1; shift 2 ;;
    --ami-port) ASTERISK_AMI_PORT="${2:-}"; AMI_PORT_FROM_CLI=1; shift 2 ;;
    --ast-http-port) ASTERISK_HTTP_PORT="${2:-}"; AST_HTTP_PORT_FROM_CLI=1; shift 2 ;;
    --ast-https-port) ASTERISK_HTTPS_PORT="${2:-}"; AST_HTTPS_PORT_FROM_CLI=1; shift 2 ;;
    --rtp-start) RTP_START="${2:-}"; RTP_START_FROM_CLI=1; shift 2 ;;
    --rtp-finish) RTP_FINISH="${2:-}"; RTP_FINISH_FROM_CLI=1; shift 2 ;;
    --skip-build) SKIP_BUILD=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "Неизвестная опция: $1 (см. --help)" ;;
  esac
done

print_banner
print_meta

# ---------- Preflight (до Docker и записи .env) ------------------------------
log_step 1 "${TOTAL_STEPS}" "Проверка хоста"

PLANNED_PROJECT_NAME="$(env_planned COMPOSE_PROJECT_NAME "${PROJECT_NAME}" "${PROJECT_NAME_FROM_CLI}" "$(basename "${REPO_ROOT}")" "${ENV_FILE}")"
PLANNED_HTTP="$(env_planned HTTP_PORT "${HTTP_PORT}" "${PORT_FROM_CLI}" "${DEFAULT_PORT}" "${ENV_FILE}")"
PLANNED_DB="$(env_planned FREEPBX_DB_PORT "${FREEPBX_DB_PORT}" "${DB_PORT_FROM_CLI}" "3307" "${ENV_FILE}")"
PLANNED_AMI_PORT="$(env_planned ASTERISK_AMI_PORT "${ASTERISK_AMI_PORT}" "${AMI_PORT_FROM_CLI}" "5038" "${ENV_FILE}")"
PLANNED_AMI_ENABLED="$(env_planned ASTERISK_AMI_ENABLED "" 0 "1" "${ENV_FILE}")"
PLANNED_SIP_PORT="$(env_planned SIP_PORT "${SIP_PORT}" "${SIP_PORT_FROM_CLI}" "5060" "${ENV_FILE}")"
PLANNED_SIPS_PORT="$(env_planned SIPS_PORT "${SIPS_PORT}" "${SIPS_PORT_FROM_CLI}" "5061" "${ENV_FILE}")"
PLANNED_SIP_LEGACY_PORT="$(env_planned SIP_LEGACY_PORT "${SIP_LEGACY_PORT}" "${SIP_LEGACY_PORT_FROM_CLI}" "5160" "${ENV_FILE}")"
PLANNED_AST_HTTP_PORT="$(env_planned ASTERISK_HTTP_PORT "${ASTERISK_HTTP_PORT}" "${AST_HTTP_PORT_FROM_CLI}" "8088" "${ENV_FILE}")"
PLANNED_AST_HTTPS_PORT="$(env_planned ASTERISK_HTTPS_PORT "${ASTERISK_HTTPS_PORT}" "${AST_HTTPS_PORT_FROM_CLI}" "8089" "${ENV_FILE}")"
PLANNED_RTP_START="$(env_planned RTP_START "${RTP_START}" "${RTP_START_FROM_CLI}" "10000" "${ENV_FILE}")"
PLANNED_RTP_FINISH="$(env_planned RTP_FINISH "${RTP_FINISH}" "${RTP_FINISH_FROM_CLI}" "20000" "${ENV_FILE}")"
PLANNED_TAG="$(env_planned FREEPBX_IMAGE_TAG "${IMAGE_TAG}" "${TAG_FROM_CLI}" "latest" "${ENV_FILE}")"

PROJECT_NAME="${PLANNED_PROJECT_NAME}"
HTTP_PORT="${PLANNED_HTTP}"
FREEPBX_DB_PORT="${PLANNED_DB}"
SIP_PORT="${PLANNED_SIP_PORT}"
SIPS_PORT="${PLANNED_SIPS_PORT}"
SIP_LEGACY_PORT="${PLANNED_SIP_LEGACY_PORT}"
ASTERISK_AMI_PORT="${PLANNED_AMI_PORT}"
ASTERISK_HTTP_PORT="${PLANNED_AST_HTTP_PORT}"
ASTERISK_HTTPS_PORT="${PLANNED_AST_HTTPS_PORT}"
RTP_START="${PLANNED_RTP_START}"
RTP_FINISH="${PLANNED_RTP_FINISH}"
IMAGE_TAG="${PLANNED_TAG}"

run_install_preflight \
  "${REPO_ROOT}" \
  "${ENV_FILE}" \
  "${USE_DEV}" \
  "${PLANNED_PROJECT_NAME}" \
  "${PLANNED_HTTP}" \
  "${PLANNED_DB}" \
  "${PLANNED_AMI_ENABLED}" \
  "${PLANNED_AMI_PORT}" \
  "${PLANNED_SIP_PORT}" \
  "${PLANNED_SIPS_PORT}" \
  "${PLANNED_SIP_LEGACY_PORT}" \
  "${PLANNED_RTP_START}" \
  "${PLANNED_RTP_FINISH}" \
  "${PLANNED_AST_HTTP_PORT}" \
  "${PLANNED_AST_HTTPS_PORT}" \
  "${PLANNED_TAG}"

# ---------- Шаг 2: Docker ---------------------------------------------------
log_step 2 "${TOTAL_STEPS}" "Docker Engine"

if [[ "${SKIP_DOCKER}" -eq 1 ]]; then
  has_docker || die "Docker не найден (--skip-docker)"
  has_compose || die "docker compose не найден (--skip-docker)"
  log_ok "Используем существующий Docker"
elif docker_usable && has_compose; then
  log_ok "Docker готов · $(docker --version | sed 's/Docker version //;s/,.*//')"
  log_ok "Compose · $(docker compose version --short 2>/dev/null || echo ok)"
else
  if has_docker && ! docker_usable; then
    log_warn "Docker есть, но нет доступа (группа docker / sudo)"
  fi
  if ! ask_yes "Установить Docker Engine + Compose?"; then
    die "Без Docker установка невозможна"
  fi
  bash "${REPO_ROOT}/scripts/install-docker.sh" --yes

  if ! docker_usable; then
    if [[ "${EUID}" -ne 0 ]] && command -v sg >/dev/null 2>&1 \
      && sg docker -c "docker info" >/dev/null 2>&1; then
      USE_SG_DOCKER=1
      log_ok "Доступ к Docker через группу docker"
    else
      die "Нет доступа к Docker. Выполните: newgrp docker  и снова ./install.sh --skip-docker"
    fi
  fi
fi

# ---------- Шаг 3: Environment (создание .env и секретов) -------------------
log_step 3 "${TOTAL_STEPS}" "Конфигурация"

if [[ ! -f "${ENV_FILE}" ]]; then
  if [[ ! -f "${REPO_ROOT}/.env.example" ]]; then
    die ".env.example не найден"
  fi
  cp "${REPO_ROOT}/.env.example" "${ENV_FILE}"
  log_ok "Создан .env из .env.example"
else
  log_ok ".env уже существует"
fi

if [[ "${FORCE_ENV}" -eq 1 ]]; then
  log_info "Принудительная перегенерация секретов"
  for key in MYSQL_ROOT_PASSWORD FREEPBX_DB_PASS ASTERISK_AMI_PASSWORD; do
    sed -i.bak "/^${key}=/d" "${ENV_FILE}"
    rm -f "${ENV_FILE}.bak"
  done
fi

seed_env_secret MYSQL_ROOT_PASSWORD "change-this-root-password" "freepbx-root"
seed_env_secret FREEPBX_DB_PASS "change-this-password" "freepbx"
seed_env_secret ASTERISK_AMI_PASSWORD "change-this-ami-password"

resolve_env_config

if [[ "${NO_START}" -eq 1 ]]; then
  log_ok "Конфигурация завершена (--no-start)"
  printf "  ${C_DIM}Дальше:${C_RESET} docker compose pull && docker compose up -d\n\n"
  exit 0
fi

# ---------- Шаг 4: Pull/Build и запуск --------------------------------------
log_step 4 "${TOTAL_STEPS}" "Образы и запуск"

cd "${REPO_ROOT}"

log_info "Создание каталогов для данных"
mkdir -p \
  data \
  www \
  mysql \
  asterisk \
  sounds/custom \
  recordings \
  voicemail \
  certs \
  logs
touch sounds/custom/.gitkeep

if [[ "${USE_DEV}" -eq 1 ]]; then
  COMPOSE_FILE="docker-compose.dev.yml"
  MODE="разработка (локальная сборка)"
else
  COMPOSE_FILE="docker-compose.yml"
  MODE="production (образ из GHCR)"
fi

COMPOSE_CMD="docker compose -f ${COMPOSE_FILE}"

log_info "Режим: ${MODE}"

if ! ask_yes "Запустить стек в режиме ${MODE}?"; then
  log_warn "Запуск пропущен"
  printf "  ${C_DIM}Чтобы запустить позже:${C_RESET} ${COMPOSE_CMD} up -d\n\n"
  exit 0
fi

if [[ "${SKIP_BUILD}" -ne 1 ]]; then
  if [[ "${USE_DEV}" -eq 1 ]]; then
    log_info "Сборка образов (может занять 20–40 минут)..."
    if run_spinner "Сборка..." -- ${COMPOSE_CMD} build; then
      log_ok "Сборка завершена"
    else
      die "Ошибка сборки"
    fi
  else
    log_info "Загрузка образа ${GHCR_IMAGE}:${IMAGE_TAG}..."
    if run_spinner "Pull..." -- ${COMPOSE_CMD} pull freepbx; then
      log_ok "Образ загружен"
    else
      die "Ошибка pull"
    fi
  fi
else
  log_info "Пропуск сборки/pull (--skip-build)"
fi

log_info "Запуск контейнеров..."
if run_spinner "Запуск..." -- ${COMPOSE_CMD} up -d; then
  log_ok "Контейнеры запущены"
else
  die "Ошибка запуска контейнеров"
fi

secure_mariadb_firewall "${PLANNED_DB}"

HOST_IP="$(detect_public_host)"

if wait_http "Ожидание FreePBX на порту ${HTTP_PORT}..." "http://127.0.0.1:${HTTP_PORT}/admin/" 120; then
  log_ok "FreePBX доступен"
else
  log_warn "Порт ${HTTP_PORT} ещё не отвечает — проверьте логи: ${COMPOSE_CMD} logs -f freepbx"
fi

print_success_card "${HOST_IP}" "${HTTP_PORT}" "${IMAGE_TAG}" "${COMPOSE_CMD}" "${MODE}"
