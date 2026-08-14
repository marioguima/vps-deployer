#!/usr/bin/env bash
set -Eeuo pipefail

# sudo commonly resets PATH to secure_path. Docker may live in /snap/bin on some
# hosts, so keep the adapter independent from the caller's inherited PATH.
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/snap/bin"

PROJECT_ID="${1:-}"
ENVIRONMENT="${2:-}"

: "${DEPLOY_REPOSITORY:?missing DEPLOY_REPOSITORY}"
: "${DEPLOY_BRANCH:?missing DEPLOY_BRANCH}"
: "${DEPLOY_SHA:?missing DEPLOY_SHA}"

[[ "$PROJECT_ID" =~ ^[a-z0-9][a-z0-9._-]*--[0-9a-f]{12}$ ]] || {
  echo "invalid project_id: $PROJECT_ID" >&2
  exit 2
}

case "$ENVIRONMENT" in
  homolog|production) ;;
  *) echo "environment must be homolog or production" >&2; exit 2 ;;
esac

EXPECTED_BRANCH="homolog"
[[ "$ENVIRONMENT" == "production" ]] && EXPECTED_BRANCH="main"
[[ "$DEPLOY_BRANCH" == "$EXPECTED_BRANCH" ]] || {
  echo "branch/environment mismatch: branch=$DEPLOY_BRANCH environment=$ENVIRONMENT" >&2
  exit 2
}

[[ "$DEPLOY_SHA" =~ ^[0-9a-fA-F]{40}$ ]] || {
  echo "DEPLOY_SHA must be a full 40-character SHA" >&2
  exit 2
}

for cmd in git python3 docker nginx certbot curl openssl getent vps-deployer-checkout; do
  command -v "$cmd" >/dev/null || { echo "$cmd is required" >&2; exit 2; }
done
docker compose version >/dev/null

WORKSPACE_ROOT="/var/lib/vps-deployer/workspaces/$PROJECT_ID/$ENVIRONMENT"
REPO_DIR="$WORKSPACE_ROOT/repo"
ENV_FILE="$WORKSPACE_ROOT/.env"
MANIFEST="$REPO_DIR/.vps-deployer.json"
NGINX_RENDERED="$WORKSPACE_ROOT/nginx.conf"
DOCKER_CONFIG="$WORKSPACE_ROOT/.docker"

install -d -o root -g vps-deployer -m 0750 \
  /var/lib/vps-deployer/workspaces \
  "/var/lib/vps-deployer/workspaces/$PROJECT_ID" \
  "$WORKSPACE_ROOT"

# The deployer service intentionally uses ProtectHome=true. A root process
# spawned through sudo therefore must not depend on /root/.docker. Keep Docker
# CLI/buildx state inside this project's writable workspace instead.
install -d -o root -g root -m 0700 "$DOCKER_CONFIG"
export DOCKER_CONFIG

vps-deployer-checkout "$REPO_DIR"
[[ -f "$MANIFEST" ]] || { echo "missing $MANIFEST" >&2; exit 2; }

mapfile -t CFG < <(python3 - "$MANIFEST" "$ENVIRONMENT" <<'PY'
import json, re, sys
from pathlib import Path

path = Path(sys.argv[1])
env_name = sys.argv[2]
data = json.loads(path.read_text(encoding="utf-8"))
if data.get("version") != 1:
    raise SystemExit("manifest version must be 1")
if data.get("adapter") != "trackpixel":
    raise SystemExit("manifest adapter must be trackpixel")
env = (data.get("environments") or {}).get(env_name)
if not isinstance(env, dict):
    raise SystemExit(f"manifest environment not found: {env_name}")
branch = env.get("branch")
endpoints = env.get("public_endpoints")
runtime = env.get("runtime") or {}
if not isinstance(endpoints, list):
    raise SystemExit("public_endpoints must be an array")
by_name = {e.get("name"): e for e in endpoints if isinstance(e, dict)}
track = by_name.get("track")
pixel = by_name.get("pixel")
if not track or not pixel:
    raise SystemExit("TrackPixel requires track and pixel endpoints")
host_re = re.compile(r"^(?=.{1,253}$)(?:[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$")
for ep in (track, pixel):
    if ep.get("base_path") != "/":
        raise SystemExit("TrackPixel endpoints must use base_path=/")
    if not isinstance(ep.get("host"), str) or not host_re.fullmatch(ep["host"]):
        raise SystemExit(f"invalid endpoint host: {ep.get('host')}")
api_port = runtime.get("api_port")
pixel_port = runtime.get("pixel_port")
compose_project = runtime.get("compose_project")
nginx_site = runtime.get("nginx_site")
for name, port in (("api_port", api_port), ("pixel_port", pixel_port)):
    if not isinstance(port, int) or not 1024 <= port <= 65535:
        raise SystemExit(f"invalid {name}")
name_re = re.compile(r"^[a-z0-9][a-z0-9_-]{1,62}$")
for name, value in (("compose_project", compose_project), ("nginx_site", nginx_site)):
    if not isinstance(value, str) or not name_re.fullmatch(value):
        raise SystemExit(f"invalid {name}")
print(branch)
print(track["host"])
print(pixel["host"])
print(api_port)
print(pixel_port)
print(compose_project)
print(nginx_site)
PY
)

[[ ${#CFG[@]} -eq 7 ]] || { echo "invalid TrackPixel manifest output" >&2; exit 2; }
MANIFEST_BRANCH="${CFG[0]}"
TRACK_DOMAIN="${CFG[1]}"
PIXEL_DOMAIN="${CFG[2]}"
API_PORT="${CFG[3]}"
PIXEL_PORT="${CFG[4]}"
COMPOSE_PROJECT="${CFG[5]}"
NGINX_SITE="${CFG[6]}"

[[ "$MANIFEST_BRANCH" == "$DEPLOY_BRANCH" ]] || {
  echo "manifest branch mismatch: manifest=$MANIFEST_BRANCH webhook=$DEPLOY_BRANCH" >&2
  exit 2
}

if [[ ! -f "$ENV_FILE" ]]; then
  umask 077
  POSTGRES_PASSWORD="$(openssl rand -hex 24)"
  IP_HASH_SECRET="$(openssl rand -hex 32)"
  PII_HASH_PEPPER="$(openssl rand -hex 32)"
  QUEUE_DASHBOARD_PASSWORD="$(openssl rand -hex 24)"
  cat >"$ENV_FILE" <<EOF
POSTGRES_PASSWORD=$POSTGRES_PASSWORD
IP_HASH_SECRET=$IP_HASH_SECRET
PII_HASH_PEPPER=$PII_HASH_PEPPER
ENCRYPTION_MASTER_KEY=
TRUST_PROXY=true
TRUST_CLOUDFLARE=false
CORS_DEFAULT_ORIGINS=
RATE_LIMIT_IP_PER_MINUTE=120
RATE_LIMIT_SITE_PER_MINUTE=10000
LOG_LEVEL=info
DEFAULT_META_API_VERSION=v25.0
META_PIXEL_ID=
META_ACCESS_TOKEN=
META_TEST_EVENT_CODE=
QUEUE_DASHBOARD_ENABLED=false
QUEUE_DASHBOARD_PATH=/admin/queues
QUEUE_DASHBOARD_USER=admin
QUEUE_DASHBOARD_PASSWORD=$QUEUE_DASHBOARD_PASSWORD
DEFAULT_SITE_ID=
DEFAULT_SITE_KEY=
CAKTO_WEBHOOK_SECRET=
CAKTO_CLIENT_ID=
CAKTO_CLIENT_SECRET=
CAKTO_API_BASE_URL=https://api.cakto.com.br
EOF
  chown root:root "$ENV_FILE"
  chmod 0600 "$ENV_FILE"
  echo "created environment secrets: $ENV_FILE"
else
  echo "preserving environment secrets: $ENV_FILE"
fi

require_configured() {
  local key="$1" value
  value="$(grep -E "^${key}=" "$ENV_FILE" | tail -n 1 | cut -d= -f2- || true)"
  [[ -n "$value" && "$value" != "CHANGE_ME" ]] || {
    echo "$key is not configured in $ENV_FILE" >&2
    exit 2
  }
}
require_configured POSTGRES_PASSWORD
require_configured IP_HASH_SECRET
require_configured PII_HASH_PEPPER

cd "$REPO_DIR"
export API_PORT PIXEL_PORT
export PUBLIC_TRACKING_BASE_URL="https://$TRACK_DOMAIN"
COMPOSE=(docker compose -p "$COMPOSE_PROJECT" --env-file "$ENV_FILE" -f docker-compose.yml -f docker-compose.prod.yml)

"${COMPOSE[@]}" build
"${COMPOSE[@]}" up -d postgres redis
"${COMPOSE[@]}" run --rm migrate
"${COMPOSE[@]}" up -d api worker pixel

install -d -m 0755 /var/www/certbot
SITE_AVAILABLE="/etc/nginx/sites-available/$NGINX_SITE.conf"
SITE_ENABLED="/etc/nginx/sites-enabled/$NGINX_SITE.conf"
CERT_DIR="/etc/letsencrypt/live/$TRACK_DOMAIN"

if [[ ! -f "$CERT_DIR/fullchain.pem" ]]; then
  sed \
    -e "s/__TRACK_DOMAIN__/$TRACK_DOMAIN/g" \
    -e "s/__PIXEL_DOMAIN__/$PIXEL_DOMAIN/g" \
    nginx/trackpixel.bootstrap.conf.template >"$NGINX_RENDERED"
  install -m 0644 "$NGINX_RENDERED" "$SITE_AVAILABLE"
  ln -sfn "$SITE_AVAILABLE" "$SITE_ENABLED"
  nginx -t
  systemctl reload nginx

  certbot certonly \
    --webroot -w /var/www/certbot \
    --non-interactive --agree-tos \
    --email "${VPS_DEPLOYER_CERTBOT_EMAIL:-marioguimaraes.nd@gmail.com}" \
    --cert-name "$TRACK_DOMAIN" \
    -d "$TRACK_DOMAIN" -d "$PIXEL_DOMAIN"
fi

sed \
  -e "s/__TRACK_DOMAIN__/$TRACK_DOMAIN/g" \
  -e "s/__PIXEL_DOMAIN__/$PIXEL_DOMAIN/g" \
  -e "s/__CERT_NAME__/$TRACK_DOMAIN/g" \
  -e "s/__API_PORT__/$API_PORT/g" \
  -e "s/__PIXEL_PORT__/$PIXEL_PORT/g" \
  nginx/trackpixel.conf.template >"$NGINX_RENDERED"
install -m 0644 "$NGINX_RENDERED" "$SITE_AVAILABLE"
ln -sfn "$SITE_AVAILABLE" "$SITE_ENABLED"
nginx -t
systemctl reload nginx

curl --retry 10 --retry-delay 2 --retry-connrefused -fsS "https://$TRACK_DOMAIN/health" >/dev/null
curl --retry 10 --retry-delay 2 --retry-connrefused -fsSI "https://$PIXEL_DOMAIN/pixel.js" >/dev/null
"${COMPOSE[@]}" ps

echo "deploy_ok project_id=$PROJECT_ID environment=$ENVIRONMENT repository=$DEPLOY_REPOSITORY sha=${DEPLOY_SHA:0:12} track=https://$TRACK_DOMAIN pixel=https://$PIXEL_DOMAIN/pixel.js"
