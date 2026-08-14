#!/usr/bin/env bash
set -Eeuo pipefail

# Direct cutover for sales-oci:
# - stop/disable host Nginx so it no longer owns public 80/443
# - remove any intellifyads.com Nginx vhost files, if present
# - enable Coolify's native Traefik proxy
# - connect Traefik to TrackPixel homolog network
# - validate TrackPixel homolog HTTPS endpoints
#
# Existing non-TrackPixel Nginx sites are intentionally NOT migrated here.
# They may be unavailable until migrated to Coolify later.

if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
  echo "Run as root: sudo bash $0" >&2
  exit 1
fi

TRACKPIXEL_UUID="6b0kjkl407ufjocxoucpsgq1"
TRACK_DOMAIN="track-homolog.intellifyads.com"
PIXEL_DOMAIN="pixel-homolog.intellifyads.com"
EXPECTED_IP="136.248.109.197"
BACKUP_ROOT="/root/trackpixel-traefik-cutover"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
BACKUP_DIR="$BACKUP_ROOT/$STAMP"
SUCCESS=0
NGINX_WAS_ACTIVE=0

log() { printf '\n===== %s =====\n' "$*"; }
fail() { echo "ERROR: $*" >&2; return 1; }

set_proxy_type() {
  local type="$1"
  docker exec coolify php artisan tinker --execute="\$s=App\\Models\\Server::find(0); \$s->changeProxy('${type}', false);" >/dev/null
}

rollback() {
  local rc=$?
  trap - ERR INT TERM EXIT
  if [[ "$SUCCESS" -eq 1 ]]; then
    exit "$rc"
  fi

  echo
  echo "!!! CUTOVER FAILED - ROLLING BACK PUBLIC PROXY !!!" >&2
  docker rm -f coolify-proxy >/dev/null 2>&1 || true
  docker exec coolify php artisan tinker --execute='\$s=App\\Models\\Server::find(0); if (\$s) { \$s->proxy->set("type", "NONE"); \$s->proxy->set("status", "exited"); \$s->save(); }' >/dev/null 2>&1 || true

  if [[ -f "$BACKUP_DIR/nginx.tar.gz" ]]; then
    rm -rf /etc/nginx
    tar -xzf "$BACKUP_DIR/nginx.tar.gz" -C / || true
  fi

  if [[ "$NGINX_WAS_ACTIVE" -eq 1 ]]; then
    systemctl enable nginx >/dev/null 2>&1 || true
    systemctl restart nginx >/dev/null 2>&1 || true
  fi

  echo "Rollback finished. Backup: $BACKUP_DIR" >&2
  exit "$rc"
}
trap rollback ERR INT TERM EXIT

log "PREFLIGHT"
for cmd in docker curl python3 ss systemctl tar grep; do
  command -v "$cmd" >/dev/null 2>&1 || fail "$cmd is required"
done

docker inspect coolify >/dev/null 2>&1 || fail "Coolify container not found"
docker network inspect "$TRACKPIXEL_UUID" >/dev/null 2>&1 || fail "TrackPixel Coolify network $TRACKPIXEL_UUID not found"

if systemctl is-active --quiet nginx; then
  NGINX_WAS_ACTIVE=1
fi

current_proxy="$(docker exec coolify php artisan tinker --execute='echo App\\Models\\Server::find(0)->proxyType();' 2>/dev/null | tr -d '\r\n[:space:]' || true)"
echo "coolify_proxy_type=${current_proxy:-unknown}"

log "WAIT FOR CURRENT HOMOLOG DEPLOY"
deadline=$((SECONDS + 600))
while true; do
  api_container="$(docker ps --format '{{.Names}}' | grep -E "^api-${TRACKPIXEL_UUID}-" | head -n1 || true)"
  pixel_container="$(docker ps --format '{{.Names}}' | grep -E "^pixel-${TRACKPIXEL_UUID}-" | head -n1 || true)"

  if [[ -n "$api_container" && -n "$pixel_container" ]]; then
    api_labels="$(docker inspect -f '{{json .Config.Labels}}' "$api_container" 2>/dev/null || true)"
    pixel_labels="$(docker inspect -f '{{json .Config.Labels}}' "$pixel_container" 2>/dev/null || true)"
    if [[ "$api_labels" == *"Host(\`$TRACK_DOMAIN\`)"* && "$pixel_labels" == *"Host(\`$PIXEL_DOMAIN\`)"* && "$api_labels" != *'${'* && "$pixel_labels" != *'${'* ]]; then
      break
    fi
  fi

  if (( SECONDS >= deadline )); then
    fail "Timed out waiting for TrackPixel homolog containers with concrete Traefik labels"
  fi
  echo "Waiting for latest TrackPixel homolog deployment..."
  sleep 10
done

echo "api=$api_container"
echo "pixel=$pixel_container"
[[ "$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$api_container")" == "healthy" ]] || fail "API container is not healthy"
[[ "$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$pixel_container")" == "healthy" ]] || fail "Pixel container is not healthy"

log "PUBLIC DNS"
resolve_cf() {
  curl -fsS "https://cloudflare-dns.com/dns-query?name=$1&type=A" -H 'accept: application/dns-json' |
    python3 -c 'import json,sys; d=json.load(sys.stdin); print("\n".join(str(x.get("data")) for x in d.get("Answer",[]) if x.get("type")==1))'
}
for host in "$TRACK_DOMAIN" "$PIXEL_DOMAIN"; do
  ips="$(resolve_cf "$host")"
  echo "$host -> $(tr '\n' ' ' <<<"$ips")"
  grep -Fxq "$EXPECTED_IP" <<<"$ips" || fail "$host does not resolve to $EXPECTED_IP"
done

log "BACKUP NGINX"
mkdir -p "$BACKUP_DIR"
if [[ -d /etc/nginx ]]; then
  tar -czf "$BACKUP_DIR/nginx.tar.gz" /etc/nginx
fi
chmod 700 "$BACKUP_DIR"
echo "backup=$BACKUP_DIR"

log "REMOVE INTELLIFYADS NGINX CONFIG"
if [[ -d /etc/nginx ]]; then
  mapfile -t intellify_files < <(grep -RIl --include='*.conf' --include='*intellifyads*' 'intellifyads\.com' /etc/nginx/sites-enabled /etc/nginx/sites-available /etc/nginx/conf.d 2>/dev/null | sort -u || true)
  if ((${#intellify_files[@]})); then
    for f in "${intellify_files[@]}"; do
      echo "removing $f"
      rm -f "$f"
    done
  else
    echo "No intellifyads.com Nginx vhost files found."
  fi
fi

log "STOP HOST NGINX"
systemctl disable --now nginx >/dev/null 2>&1 || true
sleep 2
if ss -ltnH 'sport = :80' | grep -q .; then
  echo "Port 80 still in use:"
  ss -ltnp 'sport = :80' || true
  fail "Port 80 is still occupied"
fi
if ss -ltnH 'sport = :443' | grep -q .; then
  echo "Port 443 still in use:"
  ss -ltnp 'sport = :443' || true
  fail "Port 443 is still occupied"
fi

log "ENABLE COOLIFY TRAEFIK"
if docker inspect coolify-proxy >/dev/null 2>&1; then
  docker rm -f coolify-proxy >/dev/null 2>&1 || true
fi
set_proxy_type TRAEFIK

for _ in $(seq 1 60); do
  if docker inspect coolify-proxy >/dev/null 2>&1 && [[ "$(docker inspect -f '{{.State.Running}}' coolify-proxy 2>/dev/null || true)" == "true" ]]; then
    break
  fi
  sleep 2
done

docker inspect coolify-proxy >/dev/null 2>&1 || fail "Coolify Traefik container was not created"
[[ "$(docker inspect -f '{{.State.Running}}' coolify-proxy)" == "true" ]] || fail "Coolify Traefik is not running"

docker network connect "$TRACKPIXEL_UUID" coolify-proxy >/dev/null 2>&1 || true

for _ in $(seq 1 30); do
  if ss -ltnH 'sport = :80' | grep -q . && ss -ltnH 'sport = :443' | grep -q .; then
    break
  fi
  sleep 1
done
ss -ltnp 'sport = :80' | grep -Eq 'docker-proxy|traefik' || fail "Traefik is not listening on public port 80"
ss -ltnp 'sport = :443' | grep -Eq 'docker-proxy|traefik' || fail "Traefik is not listening on public port 443"

log "VALIDATE TRACKPIXEL HOMOLOG HTTPS"
track_ok=0
for _ in $(seq 1 60); do
  body="$(curl --connect-timeout 5 --max-time 15 --resolve "$TRACK_DOMAIN:443:127.0.0.1" -fsS "https://$TRACK_DOMAIN/health" 2>/dev/null || true)"
  if [[ "$body" == *'ok'* ]]; then
    track_ok=1
    break
  fi
  sleep 3
done
[[ "$track_ok" -eq 1 ]] || fail "TrackPixel API HTTPS did not become healthy"

pixel_ok=0
for _ in $(seq 1 60); do
  code="$(curl --connect-timeout 5 --max-time 15 --resolve "$PIXEL_DOMAIN:443:127.0.0.1" -sS -o /dev/null -w '%{http_code}' "https://$PIXEL_DOMAIN/pixel.js" 2>/dev/null || true)"
  if [[ "$code" == "200" ]]; then
    pixel_ok=1
    break
  fi
  sleep 3
done
[[ "$pixel_ok" -eq 1 ]] || fail "TrackPixel pixel.js HTTPS did not become healthy"

log "FINAL STATE"
echo "nginx=$(systemctl is-active nginx 2>/dev/null || true)"
echo "nginx_enabled=$(systemctl is-enabled nginx 2>/dev/null || true)"
docker ps --filter name='^/coolify-proxy$' --format 'name={{.Names}} status={{.Status}} ports={{.Ports}}'
echo "track=https://$TRACK_DOMAIN/health"
echo "pixel=https://$PIXEL_DOMAIN/pixel.js"
echo "backup=$BACKUP_DIR"

SUCCESS=1
trap - ERR INT TERM EXIT
echo
echo "TRACKPIXEL_TRAEFIK_OK"
