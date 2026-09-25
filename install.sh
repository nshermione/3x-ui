#!/bin/sh
set -eu

# Default panel credentials (prompted unless --no-prompt. Enter keeps default.)
DEFAULT_USERNAME="admin"
DEFAULT_PASSWORD="admin123"
XUI_USERNAME="${XUI_USERNAME:-$DEFAULT_USERNAME}"
XUI_PASSWORD="${XUI_PASSWORD:-$DEFAULT_PASSWORD}"
PROTOCOL_DOMAIN="${PROTOCOL_DOMAIN:-}"
DEFAULT_PANEL_PORT="20530"
DEFAULT_PROTOCOL_PORT="443"
PANEL_PORT="${PANEL_PORT:-$DEFAULT_PANEL_PORT}"
PROTOCOL_PORT="${PROTOCOL_PORT:-$DEFAULT_PROTOCOL_PORT}"
EXTRA_PORTS="${EXTRA_PORTS:-}"
NO_PROMPT="${NO_PROMPT:-0}"

INSTALL_DIR="${INSTALL_DIR:-$HOME/3x-ui}"
COMPOSE_FILE="${INSTALL_DIR}/docker-compose.yml"
API_TOKEN_FILE="${INSTALL_DIR}/api-token.txt"
API_TOKEN=""
SUDO=""
COMPOSE_CMD=""
DOCKER_BIN="docker"
XUI_BIN="/app/x-ui"

usage() {
  cat <<'EOF'
Usage:
  curl -fsSL <install.sh-url> | sh
  curl -fsSL <install.sh-url> | sh -s -- --username USER --password PASS --protocol-domain example.com
  curl -fsSL <install.sh-url> | sh -s -- --no-prompt --protocol-domain example.com
  curl -fsSL <install.sh-url> | sh -s -- --no-prompt --username USER --password PASS --protocol-domain example.com
  curl -fsSL <install.sh-url> | XUI_USERNAME=USER XUI_PASSWORD=PASS PROTOCOL_DOMAIN=example.com sh
  curl -fsSL <install.sh-url> | sh -s -- --no-prompt --protocol-domain example.com --panel-port 20530 --protocol-port 443 --publish 8443:8443/tcp

By default the script prompts for panel username/password, the protocol domain, and ports.
Press Enter to keep the default username/password (admin / admin123) and ports (20530, 443).
The protocol domain has no default; --no-prompt requires --protocol-domain or PROTOCOL_DOMAIN.
Flags and env vars pre-fill those defaults; empty input still uses them.

--no-prompt skips all prompts and uses flags, env vars, or defaults.

The protocol domain is the TLS name shared by inbounds (Hysteria2, Trojan, VLESS, VMess, TUIC).
It is separate from the panel. A self-signed certificate is written to
<install-dir>/cert/hysteria.crt and hysteria.key.

Published ports in docker-compose.yml:
  PANEL_PORT:2053                 panel (default host port 20530)
  PROTOCOL_PORT/tcp and /udp      shared protocol port (default 443)
  --publish HOST:CONTAINER[/tcp|udp]   extra mappings, repeatable

Env vars:
  XUI_USERNAME      Panel username (default: admin)
  XUI_PASSWORD      Panel password (default: admin123)
  PROTOCOL_DOMAIN   Protocol TLS domain, cert CN/SAN (required)
  PANEL_PORT        Host port for the panel (default: 20530)
  PROTOCOL_PORT     Host and container port for protocols, TCP and UDP (default: 443)
  EXTRA_PORTS       Space-separated extra mappings, same form as --publish
  INSTALL_DIR       Install directory (default: $HOME/3x-ui)
  NO_PROMPT         Set to 1 to skip prompts (same as --no-prompt)
EOF
}

parse_args() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      -u|--username)
        [ "$#" -ge 2 ] || { echo "Missing value for $1" >&2; exit 1; }
        XUI_USERNAME="$2"
        shift 2
        ;;
      -p|--password)
        [ "$#" -ge 2 ] || { echo "Missing value for $1" >&2; exit 1; }
        XUI_PASSWORD="$2"
        shift 2
        ;;
      -d|--protocol-domain)
        [ "$#" -ge 2 ] || { echo "Missing value for $1" >&2; exit 1; }
        PROTOCOL_DOMAIN="$2"
        shift 2
        ;;
      --panel-port)
        [ "$#" -ge 2 ] || { echo "Missing value for $1" >&2; exit 1; }
        PANEL_PORT="$2"
        shift 2
        ;;
      --protocol-port)
        [ "$#" -ge 2 ] || { echo "Missing value for $1" >&2; exit 1; }
        PROTOCOL_PORT="$2"
        shift 2
        ;;
      --publish)
        [ "$#" -ge 2 ] || { echo "Missing value for $1" >&2; exit 1; }
        EXTRA_PORTS="${EXTRA_PORTS}${EXTRA_PORTS:+ }$2"
        shift 2
        ;;
      --install-dir)
        [ "$#" -ge 2 ] || { echo "Missing value for $1" >&2; exit 1; }
        INSTALL_DIR="$2"
        COMPOSE_FILE="${INSTALL_DIR}/docker-compose.yml"
        API_TOKEN_FILE="${INSTALL_DIR}/api-token.txt"
        shift 2
        ;;
      --no-prompt)
        NO_PROMPT=1
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        echo "Unknown argument: $1" >&2
        usage >&2
        exit 1
        ;;
    esac
  done
}

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

read_tty() {
  IFS= read -r "$1" < /dev/tty || true
}

prompt_credentials() {
  if [ ! -r /dev/tty ] || [ ! -w /dev/tty ]; then
    log "No TTY; using default credentials (user=${XUI_USERNAME})"
    return 0
  fi

  input=""
  printf 'Panel username [%s]: ' "${XUI_USERNAME}" > /dev/tty
  read_tty input
  if [ -n "${input}" ]; then
    XUI_USERNAME="${input}"
  fi

  input=""
  printf 'Panel password [%s]: ' "${XUI_PASSWORD}" > /dev/tty
  if stty -echo < /dev/tty 2>/dev/null; then
    trap 'stty echo < /dev/tty 2>/dev/null || true' INT TERM
    read_tty input
    stty echo < /dev/tty 2>/dev/null || true
    trap - INT TERM
    printf '\n' > /dev/tty
  else
    read_tty input
  fi
  if [ -n "${input}" ]; then
    XUI_PASSWORD="${input}"
  fi
  unset input

  log "Using panel username: ${XUI_USERNAME}"
}

require_protocol_domain() {
  if [ -z "${PROTOCOL_DOMAIN}" ]; then
    echo "Protocol domain is required. Pass --protocol-domain or set PROTOCOL_DOMAIN." >&2
    exit 1
  fi
  if ! printf '%s' "${PROTOCOL_DOMAIN}" | grep -Eq '^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)+$'; then
    echo "Invalid protocol domain: ${PROTOCOL_DOMAIN}" >&2
    exit 1
  fi
}

prompt_protocol_domain() {
  if [ ! -r /dev/tty ] || [ ! -w /dev/tty ]; then
    require_protocol_domain
    log "No TTY; using protocol domain: ${PROTOCOL_DOMAIN}"
    return 0
  fi

  input=""
  if [ -n "${PROTOCOL_DOMAIN}" ]; then
    printf 'Protocol domain [%s]: ' "${PROTOCOL_DOMAIN}" > /dev/tty
  else
    printf 'Protocol domain: ' > /dev/tty
  fi
  read_tty input
  if [ -n "${input}" ]; then
    PROTOCOL_DOMAIN="${input}"
  fi
  unset input
  require_protocol_domain
  log "Using protocol domain: ${PROTOCOL_DOMAIN}"
}

validate_port_number() {
  label="$1"
  value="$2"
  if ! printf '%s' "${value}" | grep -Eq '^[1-9][0-9]{0,4}$' || [ "${value}" -gt 65535 ]; then
    echo "Invalid ${label}: ${value}" >&2
    exit 1
  fi
}

claim_host_port() {
  proto="$1"
  host="$2"
  case "${proto}" in
    tcp)
      case "${tcp_used}" in
        *" ${host} "*)
          echo "Host TCP port ${host} is already published." >&2
          exit 1
          ;;
      esac
      tcp_used="${tcp_used}${host} "
      ;;
    udp)
      case "${udp_used}" in
        *" ${host} "*)
          echo "Host UDP port ${host} is already published." >&2
          exit 1
          ;;
      esac
      udp_used="${udp_used}${host} "
      ;;
  esac
}

require_ports() {
  validate_port_number "panel port" "${PANEL_PORT}"
  validate_port_number "protocol port" "${PROTOCOL_PORT}"
  if [ "${PANEL_PORT}" = "${PROTOCOL_PORT}" ]; then
    echo "Panel port and protocol port must be different." >&2
    exit 1
  fi

  tcp_used=" ${PANEL_PORT} ${PROTOCOL_PORT} "
  udp_used=" ${PROTOCOL_PORT} "
  rest_specs="${EXTRA_PORTS}"
  while [ -n "${rest_specs}" ]; do
    spec="${rest_specs%% *}"
    case "${rest_specs}" in
      *" "*) rest_specs="${rest_specs#* }" ;;
      *) rest_specs="" ;;
    esac
    [ -n "${spec}" ] || continue
    case "${spec}" in
      *:*) ;;
      *)
        echo "Invalid --publish ${spec}. Use HOST:CONTAINER or HOST:CONTAINER/tcp|udp." >&2
        exit 1
        ;;
    esac
    host="${spec%%:*}"
    rest="${spec#*:}"
    case "${rest}" in
      */tcp)
        container="${rest%/tcp}"
        proto="tcp"
        ;;
      */udp)
        container="${rest%/udp}"
        proto="udp"
        ;;
      */*)
        echo "Invalid --publish ${spec}. Protocol must be tcp or udp." >&2
        exit 1
        ;;
      *)
        container="${rest}"
        proto="tcp"
        ;;
    esac
    validate_port_number "publish host port" "${host}"
    validate_port_number "publish container port" "${container}"
    claim_host_port "${proto}" "${host}"
  done
}

prompt_ports() {
  if [ ! -r /dev/tty ] || [ ! -w /dev/tty ]; then
    require_ports
    log "No TTY; using panel port ${PANEL_PORT} and protocol port ${PROTOCOL_PORT}"
    return 0
  fi

  input=""
  printf 'Panel port [%s]: ' "${PANEL_PORT}" > /dev/tty
  read_tty input
  if [ -n "${input}" ]; then
    PANEL_PORT="${input}"
  fi

  input=""
  printf 'Protocol port [%s]: ' "${PROTOCOL_PORT}" > /dev/tty
  read_tty input
  if [ -n "${input}" ]; then
    PROTOCOL_PORT="${input}"
  fi
  unset input
  require_ports
  log "Using panel port ${PANEL_PORT} and protocol port ${PROTOCOL_PORT}/tcp+udp"
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

  log "Installing apt prerequisites (apt-utils, ca-certificates, curl, openssl) ..."
  export DEBIAN_FRONTEND=noninteractive
  ${SUDO} apt-get update -y
  ${SUDO} apt-get install -y apt-utils ca-certificates curl openssl
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

  require_ports
  ports_block="      - \"${PANEL_PORT}:2053\"
      - \"${PROTOCOL_PORT}:${PROTOCOL_PORT}/tcp\"
      - \"${PROTOCOL_PORT}:${PROTOCOL_PORT}/udp\""
  rest_specs="${EXTRA_PORTS}"
  while [ -n "${rest_specs}" ]; do
    spec="${rest_specs%% *}"
    case "${rest_specs}" in
      *" "*) rest_specs="${rest_specs#* }" ;;
      *) rest_specs="" ;;
    esac
    [ -n "${spec}" ] || continue
    ports_block="${ports_block}
      - \"${spec}\""
  done

  log "Writing docker-compose.yml (panel ${PANEL_PORT}->2053, protocol ${PROTOCOL_PORT}/tcp+udp)"
  cat > "${COMPOSE_FILE}" <<EOF
services:
  3x-ui:
    image: ghcr.io/mhsanaei/3x-ui:v3.7.0
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
${ports_block}
EOF
}

generate_self_cert() {
  require_protocol_domain
  if ! command -v openssl >/dev/null 2>&1; then
    if command -v apt-get >/dev/null 2>&1; then
      log "Installing openssl ..."
      export DEBIAN_FRONTEND=noninteractive
      ${SUDO} apt-get update -y
      ${SUDO} apt-get install -y openssl
    else
      echo "openssl is required to generate the certificate." >&2
      exit 1
    fi
  fi

  cert_dir="${INSTALL_DIR}/cert"
  mkdir -p "${cert_dir}"
  log "Generating self-signed certificate for protocol domain ${PROTOCOL_DOMAIN} ..."
  openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
    -keyout "${cert_dir}/hysteria.key" \
    -out "${cert_dir}/hysteria.crt" \
    -subj "/CN=${PROTOCOL_DOMAIN}" \
    -addext "subjectAltName=DNS:${PROTOCOL_DOMAIN}"
  chmod 600 "${cert_dir}/hysteria.key" 2>/dev/null || true
  log "Certificate written to ${cert_dir}/hysteria.crt"
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

resolve_docker_bin() {
  if docker ps >/dev/null 2>&1; then
    DOCKER_BIN="docker"
  else
    DOCKER_BIN="${SUDO} docker"
  fi
}

resolve_xui_bin() {
  # shellcheck disable=SC2086
  if ${DOCKER_BIN} exec 3x-ui test -x /app/x-ui; then
    XUI_BIN="/app/x-ui"
  elif ${DOCKER_BIN} exec 3x-ui test -x /usr/local/x-ui/x-ui; then
    XUI_BIN="/usr/local/x-ui/x-ui"
  else
    echo "x-ui binary not found inside container." >&2
    exit 1
  fi
}

xui_exec() {
  # shellcheck disable=SC2086
  ${DOCKER_BIN} exec 3x-ui "${XUI_BIN}" "$@"
}

set_credentials() {
  # Official image does not support username/password via env;
  # set them with the built-in CLI after startup.
  resolve_docker_bin
  resolve_xui_bin

  log "Setting panel credentials (user=${XUI_USERNAME}) ..."
  xui_exec setting -username "${XUI_USERNAME}" -password "${XUI_PASSWORD}"

  # shellcheck disable=SC2086
  ${DOCKER_BIN} restart 3x-ui >/dev/null
  log "Credentials applied and container restarted."
}

create_api_token() {
  resolve_docker_bin
  resolve_xui_bin

  log "Creating API token ..."
  # Fresh DB: -getApiToken creates a token named "install" and prints plaintext once.
  token_output="$(xui_exec setting -getApiToken true 2>/dev/null || xui_exec setting -getApiToken 2>/dev/null || true)"
  API_TOKEN="$(printf '%s\n' "$token_output" | sed -n 's/^[[:space:]]*apiToken:[[:space:]]*//p' | head -n 1 | tr -d '\r')"

  if [ -z "$API_TOKEN" ]; then
    log "WARN: Could not create/read API token via CLI."
    log "WARN: Create one manually in Panel → Settings → API Tokens."
    return 0
  fi

  umask 077
  printf '%s\n' "$API_TOKEN" > "${API_TOKEN_FILE}"
  chmod 600 "${API_TOKEN_FILE}" 2>/dev/null || true
  log "API token saved to ${API_TOKEN_FILE}"
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
Panel URL : http://${ip}:${PANEL_PORT}
Username  : ${XUI_USERNAME}
Password  : ${XUI_PASSWORD}
Protocol domain : ${PROTOCOL_DOMAIN}
Protocol port   : ${PROTOCOL_PORT}/tcp+udp
Extra ports     : ${EXTRA_PORTS:-<none>}
Cert      : ${INSTALL_DIR}/cert/hysteria.crt
Key       : ${INSTALL_DIR}/cert/hysteria.key
API Token : ${API_TOKEN:-<not created>}
Token File: ${API_TOKEN_FILE}
========================================

EOF
}

parse_args "$@"
need_root_or_sudo
if [ "${NO_PROMPT}" = "1" ] || [ "${NO_PROMPT}" = "true" ] || [ "${NO_PROMPT}" = "yes" ]; then
  require_protocol_domain
  require_ports
  log "No-prompt mode; using credentials (user=${XUI_USERNAME}), protocol domain ${PROTOCOL_DOMAIN}, panel port ${PANEL_PORT}, protocol port ${PROTOCOL_PORT}"
else
  prompt_credentials
  prompt_protocol_domain
  prompt_ports
fi
install_docker
create_compose_project
generate_self_cert
start_stack
wait_for_container
set_credentials
wait_for_container
create_api_token
print_summary
