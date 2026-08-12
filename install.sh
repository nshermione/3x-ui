#!/bin/sh
set -eu

# Default panel credentials
XUI_USERNAME="${XUI_USERNAME:-admin}"
XUI_PASSWORD="${XUI_PASSWORD:-admin123}"

INSTALL_DIR="${INSTALL_DIR:-$HOME/3x-ui}"
COMPOSE_FILE="${INSTALL_DIR}/docker-compose.yml"
SUDO=""
COMPOSE_CMD=""

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

need_root_or_sudo() {
  if [ "$(id -u)" -ne 0 ]; then
    if command -v sudo >/dev/null 2>&1; then
      SUDO="sudo"
    else
      echo "This script needs root privileges (or sudo)." >&2
      exit 1
    fi
  else
    SUDO=""
  fi
}

prepare_apt_deps() {
  if ! command -v apt-get >/dev/null 2>&1; then
    return 0
  fi

  log "Installing apt prerequisites (apt-utils, ca-certificates, curl) ..."
  export DEBIAN_FRONTEND=noninteractive
  ${SUDO} apt-get update -y
  ${SUDO} apt-get install -y apt-utils ca-certificates curl
}

install_docker() {
  prepare_apt_deps

  if command -v docker >/dev/null 2>&1; then
    log "Docker already installed: $(docker --version)"
  else
    log "Installing Docker via get.docker.com ..."
    curl -fsSL https://get.docker.com | ${SUDO} sh
  fi

  # Ensure docker daemon is running
  if command -v systemctl >/dev/null 2>&1; then
    ${SUDO} systemctl enable --now docker >/dev/null 2>&1 || true
  fi

  # Prefer docker compose plugin; fall back to docker-compose binary if present
  if docker compose version >/dev/null 2>&1 || ${SUDO} docker compose version >/dev/null 2>&1; then
    COMPOSE_CMD="docker compose"
  elif command -v docker-compose >/dev/null 2>&1; then
    COMPOSE_CMD="docker-compose"
  else
    log "Docker Compose not found. Installing compose plugin..."
    ${SUDO} apt-get update -y >/dev/null 2>&1 || true
    ${SUDO} apt-get install -y docker-compose-plugin >/dev/null 2>&1 || true
    if docker compose version >/dev/null 2>&1 || ${SUDO} docker compose version >/dev/null 2>&1; then
      COMPOSE_CMD="docker compose"
    else
      echo "Failed to install Docker Compose." >&2
      exit 1
    fi
  fi

  # Allow current user to run docker without sudo (best-effort)
  if [ "$(id -u)" -ne 0 ]; then
    if ! groups | grep -qw docker; then
      ${SUDO} usermod -aG docker "$USER" || true
      log "Added $USER to docker group. You may need to re-login for it to take effect."
      COMPOSE_CMD="${SUDO} ${COMPOSE_CMD}"
    elif ! docker info >/dev/null 2>&1; then
      COMPOSE_CMD="${SUDO} ${COMPOSE_CMD}"
    fi
  fi

  log "Using compose command: ${COMPOSE_CMD}"
}

create_compose_project() {
  log "Creating project directory: ${INSTALL_DIR}"
  mkdir -p "${INSTALL_DIR}/db" "${INSTALL_DIR}/cert"

  log "Writing docker-compose.yml"
  cat > "${COMPOSE_FILE}" <<'EOF'
services:
  3x-ui:
    image: ghcr.io/mhsanaei/3x-ui:latest
    container_name: 3x-ui
    hostname: 3x-ui
    volumes:
      - ./db/:/etc/x-ui/
      - ./cert/:/root/cert/
    environment:
      XRAY_VMESS_AEAD_FORCED: "false"
    tty: true
    restart: unless-stopped
    ports:
      - "20530:2053"
      - "443:443"
      - "80:80"
EOF
}

start_stack() {
  log "Starting 3x-ui with Docker Compose ..."
  # shellcheck disable=SC2086
  ( cd "${INSTALL_DIR}" && ${COMPOSE_CMD} up -d )
}

container_running() {
  docker ps --format '{{.Names}}' 2>/dev/null | grep -qx '3x-ui' \
    || ${SUDO} docker ps --format '{{.Names}}' 2>/dev/null | grep -qx '3x-ui'
}

wait_for_container() {
  retries=30
  i=1
  log "Waiting for container 3x-ui to become ready ..."
  while [ "$i" -le "$retries" ]; do
    if container_running; then
      # Give the app a moment to initialize DB
      sleep 3
      return 0
    fi
    sleep 2
    i=$((i + 1))
  done
  echo "Container 3x-ui did not start in time." >&2
  exit 1
}

set_credentials() {
  # Official image does not support username/password via env;
  # set them with the built-in CLI after startup.
  if docker ps >/dev/null 2>&1; then
    DOCKER_BIN="docker"
  else
    DOCKER_BIN="${SUDO} docker"
  fi

  log "Setting panel credentials (user=${XUI_USERNAME}) ..."
  # shellcheck disable=SC2086
  if ! ${DOCKER_BIN} exec 3x-ui /app/x-ui setting -username "${XUI_USERNAME}" -password "${XUI_PASSWORD}"; then
    # shellcheck disable=SC2086
    ${DOCKER_BIN} exec 3x-ui /usr/local/x-ui/x-ui setting -username "${XUI_USERNAME}" -password "${XUI_PASSWORD}"
  fi

  # shellcheck disable=SC2086
  ${DOCKER_BIN} restart 3x-ui >/dev/null
  log "Credentials applied and container restarted."
}

print_summary() {
  ip="$(curl -fsSL https://ifconfig.me 2>/dev/null || true)"
  if [ -z "$ip" ]; then
    ip="$(hostname -I 2>/dev/null | awk '{print $1}' || true)"
  fi
  if [ -z "$ip" ]; then
    ip="<server-ip>"
  fi

  cat <<EOF

========================================
3x-ui installed successfully
========================================
Directory : ${INSTALL_DIR}
Panel URL : http://${ip}:20530
Username  : ${XUI_USERNAME}
Password  : ${XUI_PASSWORD}
========================================

EOF
}

need_root_or_sudo
install_docker
create_compose_project
start_stack
wait_for_container
set_credentials
print_summary
