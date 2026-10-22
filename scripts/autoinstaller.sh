#!/usr/bin/env bash
# One-line installer: clone (or reuse) asterisk-docker and run install.sh.
#
#   curl -fsSL …/autoinstaller.sh | sudo bash -s -- --yes
#   ./scripts/autoinstaller.sh --dev
set -euo pipefail

REPO_URL="${REPO_URL:-https://github.com/Astrum-Studio/asterisk-docker.git}"
INSTALL_DIR="${INSTALL_DIR:-/opt/asterisk-docker}"
REF="main"
ARGS=()

usage() {
  cat <<EOF
Использование: $(basename "$0") [опции] [install.sh options…]

  --install-dir DIR   каталог установки (default: ${INSTALL_DIR})
  --ref REF           ветка или тег git (default: main)
  -h, --help          эта справка

Остальные аргументы передаются в install.sh (например --yes, --port, --dev).
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --install-dir)
      INSTALL_DIR="${2:-}"
      [[ -n "${INSTALL_DIR}" ]] || { echo "install-dir: пустой путь" >&2; exit 1; }
      shift 2
      ;;
    --ref|--version)
      REF="${2:-}"
      [[ -n "${REF}" ]] || { echo "ref: пустое значение" >&2; exit 1; }
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      ARGS+=("$1")
      shift
      ;;
  esac
done

if [[ ! -t 0 ]]; then
  has_yes=0
  for a in "${ARGS[@]}"; do
    [[ "$a" == "-y" || "$a" == "--yes" ]] && has_yes=1 && break
  done
  if [[ "${has_yes}" -eq 0 ]]; then
    ARGS+=(--yes)
  fi
fi

run_install() {
  local root="$1"
  shift
  cd "${root}"
  exec bash ./install.sh "$@"
}

# Invoked from a git clone: scripts/autoinstaller.sh
if [[ -n "${BASH_SOURCE[0]:-}" && "${BASH_SOURCE[0]}" != "bash" && "${BASH_SOURCE[0]}" != "-" ]]; then
  _SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  _REPO_FROM_SCRIPT="$(cd "${_SELF_DIR}/.." && pwd)"
  if [[ -f "${_REPO_FROM_SCRIPT}/install.sh" && -f "${_REPO_FROM_SCRIPT}/docker-compose.yml" ]]; then
    run_install "${_REPO_FROM_SCRIPT}" "${ARGS[@]}"
  fi
fi

CWD="$(pwd)"
if [[ -f "${CWD}/install.sh" && -f "${CWD}/docker-compose.yml" ]]; then
  run_install "${CWD}" "${ARGS[@]}"
fi

if [[ -f "${INSTALL_DIR}/install.sh" && -f "${INSTALL_DIR}/docker-compose.yml" ]]; then
  run_install "${INSTALL_DIR}" "${ARGS[@]}"
fi

need_cmd git
if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then
  echo "Нужен git и curl или wget для первой установки" >&2
  exit 1
fi

if [[ -d "${INSTALL_DIR}/.git" ]]; then
  echo "==> Обновление ${INSTALL_DIR} (ref ${REF})…"
  git -C "${INSTALL_DIR}" fetch --depth 1 origin "${REF}" 2>/dev/null \
    || git -C "${INSTALL_DIR}" fetch origin "${REF}"
  git -C "${INSTALL_DIR}" checkout -f "${REF}" 2>/dev/null \
    || git -C "${INSTALL_DIR}" checkout -f "origin/${REF}"
else
  echo "==> Клонирование ${REPO_URL} → ${INSTALL_DIR} (ref ${REF})…"
  if [[ -e "${INSTALL_DIR}" ]]; then
    echo "Каталог ${INSTALL_DIR} существует, но это не git-репозиторий" >&2
    exit 1
  fi
  parent="$(dirname "${INSTALL_DIR}")"
  mkdir -p "${parent}"
  git clone --branch "${REF}" --depth 1 "${REPO_URL}" "${INSTALL_DIR}" 2>/dev/null \
    || git clone --branch "${REF}" "${REPO_URL}" "${INSTALL_DIR}"
fi

run_install "${INSTALL_DIR}" "${ARGS[@]}"
