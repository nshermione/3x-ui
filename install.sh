#!/usr/bin/env bash
set -euo pipefail

# Default panel credentials
XUI_USERNAME="${XUI_USERNAME:-admin}"
XUI_PASSWORD="${XUI_PASSWORD:-admin123}"

INSTALL_DIR="${INSTALL_DIR:-$HOME/3x-ui}"
COMPOSE_FILE="${INSTALL_DIR}/docker-compose.yml"

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

need_root_or_sudo() {
  if [[ "${EUID}" -ne 0 ]]; then
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

install_docker() {
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
  if docker compose version >/dev/null 2>&1; then
    COMPOSE_CMD="docker compose"
  elif command -v docker-compose >/dev/null 2>&1; then
    COMPOSE_CMD="docker-compose"
  else
    log "Docker Compose not found. Installing compose plugin..."
    ${SUDO} apt-get update -y >/dev/null 2>&1 || true
    ${SUDO} apt-get install -y docker-compose-plugin >/dev/null 2>&1 || true
    if docker compose version >/dev/null 2>&1; then
      COMPOSE_CMD="docker compose"
    else
      echo "Failed to install Docker Compose." >&2
      exit 1
    fi
  fi

  # Allow current user to run docker without sudo (best-effort)
  if [[ "${EUID}" -ne 0 ]] && ! groups | grep -qw docker; then
    ${SUDO} usermod -aG docker "$USER" || true
    log "Added $USER to docker group. You may need to re-login for it to take effect."
    # Use sudo for compose in this session
    COMPOSE_CMD="${SUDO} ${COMPOSE_CMD}"
  elif [[ "${EUID}" -ne 0 ]] && ! docker info >/dev/null 2>&1; then
    COMPOSE_CMD="${SUDO} ${COMPOSE_CMD}"
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
  (
    cd "${INSTALL_DIR}"
    ${COMPOSE_CMD} up -d
  )
}

wait_for_container() {
  local retries=30
  local i=1
  log "Waiting for container 3x-ui to become ready ..."
  while (( i <= retries )); do
    if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx '3x-ui' \
      || ${SUDO} docker ps --format '{{.Names}}' 2>/dev/null | grep -qx '3x-ui'; then
      # Give the app a moment to initialize DB
      sleep 3
      return 0
    fi
    sleep 2
    ((i++))
  done
  echo "Container 3x-ui did not start in time." >&2
  exit 1
}

set_credentials() {
  # Official image does not support username/password via env;
  # set them with the built-in CLI after startup.
  local docker_bin="docker"
  if ! docker ps >/dev/null 2>&1; then
    docker_bin="${SUDO} docker"
  fi

  log "Setting panel credentials (user=${XUI_USERNAME}) ..."
  ${docker_bin} exec 3x-ui /app/x-ui setting -username "${XUI_USERNAME}" -password "${XUI_PASSWORD}" \
    || ${docker_bin} exec 3x-ui /usr/local/x-ui/x-ui setting -username "${XUI_USERNAME}" -password "${XUI_PASSWORD}"

  ${docker_bin} restart 3x-ui >/dev/null
  log "Credentials applied and container restarted."
}

print_summary() {
  local ip
  ip="$(curl -fsSL https://ifconfig.me 2>/dev/null || hostname -I 2>/dev/null | awk '{print $1}' || echo '<server-ip>')"

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

main() {
  need_root_or_sudo
  install_docker
  create_compose_project
  start_stack
  wait_for_container
  set_credentials
  print_summary
}

main "$@"
