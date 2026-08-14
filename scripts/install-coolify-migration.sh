#!/usr/bin/env bash
set -Eeuo pipefail

# One-time migration helper from VPS Deployer to Coolify.
# Runs as a standalone process so failures return to the caller's SSH shell.

if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
  echo "Run as root: sudo ./scripts/install-coolify-migration.sh" >&2
  exit 1
fi

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/snap/bin"

log() { printf '\n== %s ==\n' "$*"; }
fail() { echo "ERRO: $*" >&2; exit 1; }
port_busy() { ss -ltnH "sport = :$1" 2>/dev/null | grep -q .; }

log "Preflight"

[[ -r /etc/os-release ]] || fail "/etc/os-release not found"
# shellcheck disable=SC1091
. /etc/os-release

if [[ "${ID:-}" == "ubuntu" ]]; then
  case "${VERSION_ID:-}" in
    20.04|22.04|24.04) ;;
    *) fail "Ubuntu ${VERSION_ID:-unknown} is not supported by Coolify quick install; use manual installation" ;;
  esac
fi

for cmd in curl docker nginx ss python3 openssl; do
  command -v "$cmd" >/dev/null || fail "$cmd is required"
done

if command -v snap >/dev/null && snap list docker >/dev/null 2>&1; then
  fail "Docker installed via Snap is not supported by Coolify"
fi

DOCKER_MAJOR="$(docker version --format '{{.Server.Version}}' 2>/dev/null | cut -d. -f1 || true)"
[[ "$DOCKER_MAJOR" =~ ^[0-9]+$ ]] || fail "could not determine Docker server version"
(( DOCKER_MAJOR >= 24 )) || fail "Coolify requires Docker Engine 24+; found $(docker version --format '{{.Server.Version}}')"
docker compose version >/dev/null || fail "Docker Compose plugin is required"

# If Coolify already exists, reuse its published dashboard port and skip a second install.
EXISTING_COOLIFY=false
COOLIFY_APP_PORT=""
if docker inspect coolify >/dev/null 2>&1; then
  EXISTING_COOLIFY=true
  COOLIFY_APP_PORT="$(docker inspect -f '{{with (index (index .NetworkSettings.Ports "8080/tcp") 0)}}{{.HostPort}}{{end}}' coolify 2>/dev/null || true)"
  [[ "$COOLIFY_APP_PORT" =~ ^[0-9]+$ ]] || COOLIFY_APP_PORT=8000
  echo "Existing Coolify container detected; dashboard port=$COOLIFY_APP_PORT"
else
  REQUESTED_PORT="${COOLIFY_APP_PORT:-8000}"
  if [[ ! "$REQUESTED_PORT" =~ ^[0-9]+$ ]] || (( REQUESTED_PORT < 1024 || REQUESTED_PORT > 65535 )); then
    fail "COOLIFY_APP_PORT must be an integer between 1024 and 65535"
  fi

  COOLIFY_APP_PORT="$REQUESTED_PORT"
  if port_busy "$COOLIFY_APP_PORT"; then
    echo "Port $COOLIFY_APP_PORT is already in use; preserving the existing service."
    docker ps --filter "publish=$COOLIFY_APP_PORT" --format '  container={{.Names}} ports={{.Ports}}' || true

    if [[ -n "${COOLIFY_APP_PORT_EXPLICIT:-}" ]]; then
      fail "requested Coolify port $COOLIFY_APP_PORT is already in use"
    fi

    FOUND=""
    for candidate in $(seq 8001 8099); do
      if ! port_busy "$candidate"; then
        FOUND="$candidate"
        break
      fi
    done
    [[ -n "$FOUND" ]] || fail "no free Coolify dashboard port found between 8001 and 8099"
    COOLIFY_APP_PORT="$FOUND"
    echo "Coolify dashboard will use free port: $COOLIFY_APP_PORT"
  fi
fi

# These are currently fixed host ports in Coolify's production compose stack.
for port in 6001 6002; do
  if port_busy "$port"; then
    # Existing Coolify is allowed to own them.
    if [[ "$EXISTING_COOLIFY" == true ]] && docker ps --filter "name=coolify-realtime" --format '{{.Ports}}' | grep -q "$port"; then
      continue
    fi
    echo "Port $port is already in use:" >&2
    ss -ltnp "sport = :$port" >&2 || true
    fail "port $port must be free for Coolify realtime/terminal"
  fi
done

nginx -t

MEM_MB="$(awk '/MemTotal:/ {print int($2/1024)}' /proc/meminfo)"
FREE_GB="$(df -Pk / | awk 'NR==2 {print int($4/1024/1024)}')"
echo "RAM: ${MEM_MB} MB"
echo "Free disk on /: ${FREE_GB} GB"
(( MEM_MB >= 1900 )) || echo "AVISO: Coolify recommends at least 2 GB RAM."
(( FREE_GB >= 25 )) || echo "AVISO: Coolify recommends about 30 GB free disk for a comfortable setup."
echo "Docker: $(docker version --format '{{.Server.Version}}')"
echo "Compose: $(docker compose version --short)"
echo "Coolify dashboard port: $COOLIFY_APP_PORT"
echo "Existing running containers:"
docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}' || true

log "Backup"
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="/root/pre-coolify-${STAMP}.tar.gz"
BACKUP_ITEMS=()
for item in \
  /etc/nginx \
  /etc/letsencrypt \
  /etc/vps-deployer \
  /opt/vps-deployer \
  /var/lib/vps-deployer \
  /etc/systemd/system/vps-deployer.service; do
  [[ -e "$item" ]] && BACKUP_ITEMS+=("${item#/}")
done

if (( ${#BACKUP_ITEMS[@]} > 0 )); then
  tar -C / -czf "$BACKUP" "${BACKUP_ITEMS[@]}"
  chmod 600 "$BACKUP"
  echo "Backup created: $BACKUP"
else
  echo "No VPS Deployer files found to back up."
fi

TRACKPIXEL_ENV="$(find /var/lib/vps-deployer/workspaces -path '*/homolog/.env' -type f -print -quit 2>/dev/null || true)"
if [[ -n "$TRACKPIXEL_ENV" ]]; then
  install -o root -g root -m 0600 "$TRACKPIXEL_ENV" /root/trackpixel-homolog.env
  echo "TrackPixel homolog env preserved: /root/trackpixel-homolog.env"
fi

log "Resolve Coolify admin"
ADMIN_EMAIL="${COOLIFY_ADMIN_EMAIL:-}"
if [[ -z "$ADMIN_EMAIL" && -r /etc/vps-deployer/env ]]; then
  ADMIN_EMAIL="$(sed -n 's/^VPS_DEPLOYER_CERTBOT_EMAIL=//p' /etc/vps-deployer/env | tail -n1 | tr -d '\r' || true)"
fi
if [[ -z "$ADMIN_EMAIL" ]]; then
  ADMIN_EMAIL="$(python3 - <<'PY'
import glob, json
for path in glob.glob('/etc/letsencrypt/accounts/**/regr.json', recursive=True):
    try:
        with open(path, encoding='utf-8') as f:
            data=json.load(f)
        for value in (data.get('body', {}).get('contact') or []):
            if isinstance(value, str) and value.startswith('mailto:'):
                print(value[7:])
                raise SystemExit
    except Exception:
        pass
PY
)"
fi
[[ -n "$ADMIN_EMAIL" && "$ADMIN_EMAIL" == *@*.* ]] || fail "could not determine a valid Coolify admin email"

ADMIN_USERNAME="RootUser"
ADMIN_PASSWORD="Aa1!$(openssl rand -hex 20)"
CREDS=/root/coolify-admin.txt
umask 077
cat >"$CREDS" <<EOF
URL=http://136.248.109.197:${COOLIFY_APP_PORT}
EMAIL=$ADMIN_EMAIL
USERNAME=$ADMIN_USERNAME
PASSWORD=$ADMIN_PASSWORD
EOF
chmod 600 "$CREDS"
echo "Admin credentials saved in $CREDS"

if [[ "$EXISTING_COOLIFY" != true ]]; then
  log "Prepare Coolify custom dashboard port"
  # The official installer preserves keys already present in .env when merging
  # its production defaults. Pre-seeding APP_PORT avoids touching the existing
  # service that owns port 8000.
  install -d -m 0700 /data/coolify/source
  touch /data/coolify/source/.env
  if grep -q '^APP_PORT=' /data/coolify/source/.env; then
    sed -i "s/^APP_PORT=.*/APP_PORT=${COOLIFY_APP_PORT}/" /data/coolify/source/.env
  else
    printf 'APP_PORT=%s\n' "$COOLIFY_APP_PORT" >> /data/coolify/source/.env
  fi

  log "Install Coolify"
  INSTALL_LOG="/root/coolify-install-${STAMP}.log"
  env \
    ROOT_USERNAME="$ADMIN_USERNAME" \
    ROOT_USER_EMAIL="$ADMIN_EMAIL" \
    ROOT_USER_PASSWORD="$ADMIN_PASSWORD" \
    bash -c 'curl -fsSL https://cdn.coollabs.io/coolify/install.sh | bash' \
    2>&1 | tee "$INSTALL_LOG"
else
  INSTALL_LOG="existing-installation"
fi

log "Validate Coolify core"
EXPECTED=(coolify coolify-db coolify-redis coolify-realtime)
FAILED=0
for name in "${EXPECTED[@]}"; do
  if ! docker inspect "$name" >/dev/null 2>&1; then
    echo "MISSING: $name" >&2
    FAILED=1
    continue
  fi
  STATE="$(docker inspect -f '{{.State.Status}}' "$name")"
  HEALTH="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}n/a{{end}}' "$name")"
  echo "$name: state=$STATE health=$HEALTH"
  [[ "$STATE" == "running" ]] || FAILED=1
done

if docker inspect coolify-proxy >/dev/null 2>&1; then
  echo "Unexpected coolify-proxy container detected during migration." >&2
  echo "Stopping it to protect the existing Nginx on ports 80/443." >&2
  docker stop coolify-proxy >/dev/null || true
  FAILED=1
fi

nginx -t
for _ in $(seq 1 60); do
  if curl -fsS "http://127.0.0.1:${COOLIFY_APP_PORT}" >/dev/null 2>&1; then
    break
  fi
  sleep 2
done
curl -fsS "http://127.0.0.1:${COOLIFY_APP_PORT}" >/dev/null || FAILED=1

if systemctl is-active --quiet vps-deployer 2>/dev/null; then
  echo "vps-deployer remains active until Coolify deploy is proven."
else
  echo "AVISO: vps-deployer is not active. It was not intentionally stopped by this script."
fi

if (( FAILED != 0 )); then
  echo
  echo "COOLIFY_CORE_VALIDATION_FAILED"
  echo "Install log: $INSTALL_LOG"
  exit 1
fi

echo
echo "COOLIFY_CORE_OK"
echo "Dashboard: http://136.248.109.197:${COOLIFY_APP_PORT}"
echo "Credentials: $CREDS"
echo "Install log: $INSTALL_LOG"
echo "Existing Nginx remains responsible for ports 80/443."
echo "Do NOT remove VPS Deployer yet; remove it only after TrackPixel deploys successfully through Coolify."
