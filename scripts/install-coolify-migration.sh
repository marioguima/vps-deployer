#!/usr/bin/env bash
set -Eeuo pipefail

# One-time migration helper from VPS Deployer to Coolify.
# This script is intentionally standalone: if it fails, it exits back to the caller
# instead of terminating the interactive SSH/Termius session.

if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
  echo "Run as root: sudo ./scripts/install-coolify-migration.sh" >&2
  exit 1
fi

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/snap/bin"

log() { printf '\n== %s ==\n' "$*"; }
fail() { echo "ERRO: $*" >&2; exit 1; }

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

command -v curl >/dev/null || fail "curl is required"
command -v docker >/dev/null || fail "Docker Engine is required"
command -v nginx >/dev/null || fail "Nginx is required on this VPS"

if command -v snap >/dev/null && snap list docker >/dev/null 2>&1; then
  fail "Docker installed via Snap is not supported by Coolify"
fi

DOCKER_MAJOR="$(docker version --format '{{.Server.Version}}' 2>/dev/null | cut -d. -f1 || true)"
[[ "$DOCKER_MAJOR" =~ ^[0-9]+$ ]] || fail "could not determine Docker server version"
(( DOCKER_MAJOR >= 24 )) || fail "Coolify requires Docker Engine 24+; found $(docker version --format '{{.Server.Version}}')"

docker compose version >/dev/null || fail "Docker Compose plugin is required"

for port in 8000 6001 6002; do
  if ss -ltnH "sport = :$port" 2>/dev/null | grep -q .; then
    echo "Port $port is already in use:" >&2
    ss -ltnp "sport = :$port" >&2 || true
    fail "free port $port before installing Coolify"
  fi
done

nginx -t

MEM_MB="$(awk '/MemTotal:/ {print int($2/1024)}' /proc/meminfo)"
FREE_GB="$(df -Pk / | awk 'NR==2 {print int($4/1024/1024)}')"
echo "RAM: ${MEM_MB} MB"
echo "Free disk on /: ${FREE_GB} GB"
if (( MEM_MB < 1900 )); then
  echo "AVISO: Coolify recommends at least 2 GB RAM."
fi
if (( FREE_GB < 25 )); then
  echo "AVISO: Coolify recommends about 30 GB free disk for a comfortable setup."
fi

echo "Docker: $(docker version --format '{{.Server.Version}}')"
echo "Compose: $(docker compose version --short)"

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

log "Resolve Coolify admin email"
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

if [[ -z "$ADMIN_EMAIL" || "$ADMIN_EMAIL" != *@*.* ]]; then
  cat >&2 <<'EOF'
Could not determine a valid admin email automatically.
Run again with:
  sudo COOLIFY_ADMIN_EMAIL='your-email@example.com' ./scripts/install-coolify-migration.sh
EOF
  exit 2
fi

ADMIN_USERNAME="RootUser"
ADMIN_PASSWORD="Aa1!$(openssl rand -hex 20)"
CREDS=/root/coolify-admin.txt
umask 077
cat >"$CREDS" <<EOF
URL=http://136.248.109.197:8000
EMAIL=$ADMIN_EMAIL
USERNAME=$ADMIN_USERNAME
PASSWORD=$ADMIN_PASSWORD
EOF
chmod 600 "$CREDS"
echo "Admin credentials saved in $CREDS"

log "Install Coolify"
INSTALL_LOG="/root/coolify-install-${STAMP}.log"

# Official Coolify quick installer. Root user is created during installation so
# the public registration page is never needed.
env \
  ROOT_USERNAME="$ADMIN_USERNAME" \
  ROOT_USER_EMAIL="$ADMIN_EMAIL" \
  ROOT_USER_PASSWORD="$ADMIN_PASSWORD" \
  bash -c 'curl -fsSL https://cdn.coollabs.io/coolify/install.sh | bash' \
  2>&1 | tee "$INSTALL_LOG"

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
  echo "Unexpected coolify-proxy container detected during installation." >&2
  echo "Stopping it to protect the existing Nginx on ports 80/443." >&2
  docker stop coolify-proxy >/dev/null || true
  FAILED=1
fi

nginx -t

for _ in $(seq 1 60); do
  if curl -fsS http://127.0.0.1:8000 >/dev/null 2>&1; then
    break
  fi
  sleep 2
done
curl -fsS http://127.0.0.1:8000 >/dev/null || FAILED=1

if ! systemctl is-active --quiet vps-deployer 2>/dev/null; then
  echo "AVISO: vps-deployer is not active. It was not intentionally stopped by this script."
else
  echo "vps-deployer remains active until Coolify deploy is proven."
fi

if (( FAILED != 0 )); then
  echo
  echo "COOLIFY_CORE_VALIDATION_FAILED"
  echo "Install log: $INSTALL_LOG"
  exit 1
fi

echo
echo "COOLIFY_CORE_OK"
echo "Dashboard: http://136.248.109.197:8000"
echo "Credentials: $CREDS"
echo "Install log: $INSTALL_LOG"
echo "Existing Nginx remains responsible for ports 80/443."
echo "Do NOT remove VPS Deployer yet; remove it only after TrackPixel deploys successfully through Coolify."
