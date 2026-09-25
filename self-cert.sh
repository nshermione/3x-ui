#!/bin/sh
set -eu

domain="${1:-}"
if [ -z "${domain}" ]; then
  echo "Usage: $0 <protocol-domain>" >&2
  exit 1
fi

mkdir -p ./cert
openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
  -keyout ./cert/hysteria.key \
  -out ./cert/hysteria.crt \
  -subj "/CN=${domain}" \
  -addext "subjectAltName=DNS:${domain}"
chmod 600 ./cert/hysteria.key 2>/dev/null || true
