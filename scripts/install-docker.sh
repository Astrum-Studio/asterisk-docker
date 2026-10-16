#!/usr/bin/env bash
# Install Docker Engine + Compose plugin for supported Linux distributions.
#
# Usage:
#   ./scripts/install-docker.sh
#   ./scripts/install-docker.sh --yes   # non-interactive

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

ASSUME_YES=0

usage() {
  cat <<EOF
Использование: $(basename "$0") [опции]

Устанавливает Docker Engine и плагин Compose (v2) под вашу ОС.

Опции:
  -y, --yes     Без подтверждений
  -h, --help    Справка

Поддерживаемые ОС: Debian/Ubuntu, RHEL/Rocky/Alma, Fedora, Amazon Linux, Arch.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -y|--yes) ASSUME_YES=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "Неизвестная опция: $1" ;;
  esac
done

if has_docker && has_compose; then
  log_ok "Docker и Compose уже установлены: $(docker --version)"
  docker compose version
  exit 0
fi

FAMILY="$(detect_os_family)"
PRETTY="$(os_pretty_name)"

log_info "Обнаружена ОС: ${PRETTY} (${FAMILY})"

if [[ "${FAMILY}" == "unknown" ]]; then
  die "Автоустановка Docker не поддерживается для этой ОС.
Установите Docker вручную: https://docs.docker.com/engine/install/"
fi

if [[ "${ASSUME_YES}" -ne 1 ]]; then
  printf "Установить Docker Engine + Compose? [Y/n] "
  read -r answer || true
  case "${answer:-Y}" in
    y|Y|yes|YES|'') ;;
    *) log_warn "Отменено"; exit 1 ;;
  esac
fi

require_root_or_sudo

install_debian() {
  # shellcheck source=/dev/null
  . /etc/os-release
  local docker_distro="${ID}"
  case "${ID}" in
    linuxmint|pop|elementary) docker_distro=ubuntu ;;
  esac

  log_info "Установка Docker (Debian/Ubuntu)…"
  ${SUDO} apt-get update -qq
  ${SUDO} apt-get install -y -qq ca-certificates curl
  ${SUDO} install -m 0755 -d /etc/apt/keyrings
  if [[ ! -f /etc/apt/keyrings/docker.asc ]]; then
    ${SUDO} curl -fsSL "https://download.docker.com/linux/${docker_distro}/gpg" -o /etc/apt/keyrings/docker.asc
    ${SUDO} chmod a+r /etc/apt/keyrings/docker.asc
  fi
  echo \
    "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/${docker_distro} ${VERSION_CODENAME} stable" \
    | ${SUDO} tee /etc/apt/sources.list.d/docker.list >/dev/null
  ${SUDO} apt-get update -qq
  ${SUDO} apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
}

install_rhel() {
  log_info "Установка Docker (RHEL/CentOS/Rocky/Alma)…"
  ${SUDO} dnf -y install dnf-plugins-core
  ${SUDO} dnf config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
  ${SUDO} dnf -y install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
}

install_fedora() {
  log_info "Установка Docker (Fedora)…"
  ${SUDO} dnf -y install dnf-plugins-core
  ${SUDO} dnf config-manager --add-repo https://download.docker.com/linux/fedora/docker-ce.repo
  ${SUDO} dnf -y install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
}

install_amzn() {
  log_info "Установка Docker (Amazon Linux)…"
  ${SUDO} dnf -y install docker
  # Compose plugin via official convenience or pip fallback
  if ! ${SUDO} dnf -y install docker-compose-plugin 2>/dev/null; then
    log_warn "docker-compose-plugin недоступен в репозитории — ставим compose standalone"
    local arch
    arch="$(uname -m)"
    case "${arch}" in
      x86_64) arch=x86_64 ;;
      aarch64|arm64) arch=aarch64 ;;
    esac
    ${SUDO} curl -fsSL "https://github.com/docker/compose/releases/latest/download/docker-compose-linux-${arch}" \
      -o /usr/local/bin/docker-compose
    ${SUDO} chmod +x /usr/local/bin/docker-compose
    # shim for `docker compose`
    ${SUDO} mkdir -p /usr/local/lib/docker/cli-plugins
    ${SUDO} ln -sf /usr/local/bin/docker-compose /usr/local/lib/docker/cli-plugins/docker-compose
  fi
}

install_arch() {
  log_info "Установка Docker (Arch)…"
  ${SUDO} pacman -Sy --noconfirm docker docker-compose
}

case "${FAMILY}" in
  debian) install_debian ;;
  rhel) install_rhel ;;
  fedora) install_fedora ;;
  amzn) install_amzn ;;
  arch) install_arch ;;
  *) die "Неподдерживаемая ОС: ${FAMILY}" ;;
esac

${SUDO} systemctl enable --now docker 2>/dev/null || true

# Allow current user to use docker without sudo
if [[ "${EUID}" -ne 0 && -n "${SUDO}" ]]; then
  if getent group docker >/dev/null 2>&1; then
    ${SUDO} usermod -aG docker "${USER}"
    log_warn "Пользователь ${USER} добавлен в группу docker — перелогиньтесь или выполните: newgrp docker"
  fi
fi

has_docker || die "Docker не установился"
has_compose || die "Docker Compose plugin не установился"

log_ok "Docker установлен: $(docker --version)"
docker compose version
