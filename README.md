# 3x-ui
3x-ui-node

Interactive (prompts for username/password; Enter keeps `admin` / `admin123`):

```
curl -fsSL https://raw.githubusercontent.com/nshermione/3x-ui/refs/heads/main/install.sh | sh
```

Non-interactive with defaults (`admin` / `admin123`):

```
curl -fsSL https://raw.githubusercontent.com/nshermione/3x-ui/refs/heads/main/install.sh \
  | sh -s -- --no-prompt
```

Non-interactive with custom credentials:

```
curl -fsSL https://raw.githubusercontent.com/nshermione/3x-ui/refs/heads/main/install.sh \
  | sh -s -- --no-prompt --username admin --password 'admin123'

curl -fsSL https://raw.githubusercontent.com/nshermione/3x-ui/refs/heads/main/install.sh \
  | XUI_USERNAME=admin XUI_PASSWORD='admin123' sh -s -- --no-prompt
```

Flags / env (without `--no-prompt`) only pre-fill the prompt defaults:

```
curl -fsSL https://raw.githubusercontent.com/nshermione/3x-ui/refs/heads/main/install.sh \
  | XUI_USERNAME=admin XUI_PASSWORD='admin123' sh

curl -fsSL https://raw.githubusercontent.com/nshermione/3x-ui/refs/heads/main/install.sh \
  | sh -s -- --username admin --password 'admin123'
```
