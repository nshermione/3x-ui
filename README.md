# 3x-ui
3x-ui-node

Interactive (prompts for username/password, protocol domain, and ports; Enter keeps `admin` / `admin123`, panel `20530`, protocol `443`):

```
curl -fsSL https://raw.githubusercontent.com/nshermione/3x-ui/refs/heads/main/install.sh | sh
```

Non-interactive with defaults (`admin` / `admin123`). `--protocol-domain` is required:

```
curl -fsSL https://raw.githubusercontent.com/nshermione/3x-ui/refs/heads/main/install.sh \
  | sh -s -- --no-prompt --protocol-domain example.com
```

Non-interactive with custom credentials:

```
curl -fsSL https://raw.githubusercontent.com/nshermione/3x-ui/refs/heads/main/install.sh \
  | sh -s -- --no-prompt --username admin --password 'admin123' --protocol-domain example.com

curl -fsSL https://raw.githubusercontent.com/nshermione/3x-ui/refs/heads/main/install.sh \
  | XUI_USERNAME=admin XUI_PASSWORD='admin123' PROTOCOL_DOMAIN=example.com sh -s -- --no-prompt
```

Flags / env (without `--no-prompt`) only pre-fill the prompt defaults:

```
curl -fsSL https://raw.githubusercontent.com/nshermione/3x-ui/refs/heads/main/install.sh \
  | XUI_USERNAME=admin XUI_PASSWORD='admin123' PROTOCOL_DOMAIN=example.com sh

curl -fsSL https://raw.githubusercontent.com/nshermione/3x-ui/refs/heads/main/install.sh \
  | sh -s -- --username admin --password 'admin123' --protocol-domain example.com
```

`--protocol-domain` is the TLS name shared by inbounds (Hysteria2, Trojan, VLESS, VMess, TUIC). It is separate from the panel. The script writes a self-signed certificate to `cert/hysteria.crt` and `cert/hysteria.key`.

Ports written into `docker-compose.yml` (Enter keeps the defaults):

- `--panel-port` / `PANEL_PORT` — host port for the panel, mapped to container `2053` (default `20530`)
- `--protocol-port` / `PROTOCOL_PORT` — protocol port, published as TCP and UDP (default `443`)
- `--publish HOST:CONTAINER[/tcp|udp]` — extra mappings, repeatable. `EXTRA_PORTS` is the same list, space-separated.

```
curl -fsSL https://raw.githubusercontent.com/nshermione/3x-ui/refs/heads/main/install.sh \
  | sh -s -- --no-prompt --protocol-domain example.com \
      --panel-port 20530 --protocol-port 443 --publish 8443:8443/tcp
```
