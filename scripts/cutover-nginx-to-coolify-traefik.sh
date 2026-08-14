#!/usr/bin/env bash
set -Eeuo pipefail

# One-time, rollback-safe cutover for sales-oci:
#   public :80/:443 -> Coolify Traefik
#   existing host Nginx -> internal legacy backend on :8080/:8443
#   TrackPixel homolog -> Traefik Docker labels from the repository
#
# The legacy sites remain served by their current Nginx configuration through
# Traefik. They can be migrated to native Coolify resources later, one by one.

if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
  echo "Run as root: sudo bash $0" >&2
  exit 1
fi

TRACKPIXEL_UUID="6b0kjkl407ufjocxoucpsgq1"
TRACK_DOMAIN="track-homolog.intellifyads.com"
PIXEL_DOMAIN="pixel-homolog.intellifyads.com"
EXPECTED_IP="136.248.109.197"
PROXY_PATH="/data/coolify/proxy"
BACKUP_ROOT="/root/traefik-cutover-backups"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
BACKUP_DIR="$BACKUP_ROOT/$STAMP"
NGINX_BACKUP="$BACKUP_DIR/nginx.tar.gz"
PROXY_BACKUP="$BACKUP_DIR/proxy.tar.gz"
MUTATED=0
SUCCESS=0

log() { printf '\n===== %s =====\n' "$*"; }
fail() { echo "ERROR: $*" >&2; return 1; }

legacy_domains=(
  agoraentendi.com.br
  www.agoraentendi.com.br
  angelicfortunes.com
  www.angelicfortunes.com
  app.agoraentendi.com.br
  app.angelicfortunes.com
  app.meninacomproposito.com.br
  firaz.com.br
  www.firaz.com.br
  meninacomproposito.com.br
  www.meninacomproposito.com.br
)

set_coolify_proxy_type() {
  local type="$1"
  docker exec coolify php artisan tinker --execute="\$s=App\\Models\\Server::find(0); \$s->changeProxy('${type}', false);" >/dev/null
}

restore_nginx() {
  [[ -f "$NGINX_BACKUP" ]] || return 0
  echo "Restoring Nginx configuration from $NGINX_BACKUP"
  rm -rf /etc/nginx
  tar -xzf "$NGINX_BACKUP" -C /
}

rollback() {
  local rc=$?
  trap - ERR INT TERM EXIT
  if [[ "$SUCCESS" -eq 1 || "$MUTATED" -eq 0 ]]; then
    exit "$rc"
  fi

  echo
  echo "!!! CUTOVER FAILED - AUTOMATIC ROLLBACK !!!" >&2
  docker rm -f coolify-proxy >/dev/null 2>&1 || true
  set_coolify_proxy_type NONE >/dev/null 2>&1 || true
  restore_nginx || true
  nginx -t >/dev/null 2>&1 || true
  systemctl restart nginx || true
  echo "Rollback completed. Host Nginx should own public 80/443 again." >&2
  echo "Backup: $BACKUP_DIR" >&2
  exit "$rc"
}
trap rollback ERR INT TERM EXIT

log "PREFLIGHT"
for cmd in docker nginx systemctl python3 curl tar ss; do
  command -v "$cmd" >/dev/null 2>&1 || fail "$cmd is required"
done

docker inspect coolify >/dev/null 2>&1 || fail "Coolify container not found"
docker inspect coolify-db >/dev/null 2>&1 || fail "Coolify DB container not found"
systemctl is-active --quiet nginx || fail "Nginx is not active"
nginx -t

current_proxy="$(docker exec coolify php artisan tinker --execute='echo App\\Models\\Server::find(0)->proxyType();' 2>/dev/null | tr -d '\r\n[:space:]' || true)"
echo "coolify_proxy_type=${current_proxy:-unknown}"
if [[ "${current_proxy^^}" != "NONE" ]]; then
  fail "Expected Coolify proxy type NONE before cutover; got ${current_proxy:-unknown}"
fi

for port in 80 443; do
  ss -ltnp "sport = :$port" | grep -q nginx || fail "Nginx is not the current owner of TCP $port"
done

log "WAIT FOR TRACKPIXEL HOMOLOG DEPLOY"
deadline=$((SECONDS + 600))
while true; do
  api_container="$(docker ps --format '{{.Names}}' | grep -E "^api-${TRACKPIXEL_UUID}-" | head -n1 || true)"
  pixel_container="$(docker ps --format '{{.Names}}' | grep -E "^pixel-${TRACKPIXEL_UUID}-" | head -n1 || true)"

  ready=0
  if [[ -n "$api_container" && -n "$pixel_container" ]]; then
    api_labels="$(docker inspect -f '{{json .Config.Labels}}' "$api_container" 2>/dev/null || true)"
    pixel_labels="$(docker inspect -f '{{json .Config.Labels}}' "$pixel_container" 2>/dev/null || true)"
    if [[ "$api_labels" == *"Host(\`$TRACK_DOMAIN\`)"* && "$pixel_labels" == *"Host(\`$PIXEL_DOMAIN\`)"* && "$api_labels" != *'${'* && "$pixel_labels" != *'${'* ]]; then
      ready=1
    fi
  fi

  if [[ "$ready" -eq 1 ]]; then
    echo "TrackPixel containers have concrete Traefik labels."
    echo "api=$api_container"
    echo "pixel=$pixel_container"
    break
  fi

  if (( SECONDS >= deadline )); then
    fail "Timed out waiting for the homolog deployment with interpolated Traefik labels"
  fi
  echo "Waiting for latest Coolify homolog deployment..."
  sleep 10
done

api_health="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$api_container")"
pixel_health="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$pixel_container")"
[[ "$api_health" == "healthy" ]] || fail "API container health is $api_health"
[[ "$pixel_health" == "healthy" ]] || fail "Pixel container health is $pixel_health"

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

log "BACKUP"
mkdir -p "$BACKUP_DIR"
tar -czf "$NGINX_BACKUP" /etc/nginx
if [[ -d "$PROXY_PATH" ]]; then
  tar -czf "$PROXY_BACKUP" "$PROXY_PATH"
fi
chmod 700 "$BACKUP_DIR"
echo "backup=$BACKUP_DIR"

log "PREPARE LEGACY TRAEFIK ROUTES"
mkdir -p "$PROXY_PATH/dynamic"
http_rule=""
tcp_rule=""
for host in "${legacy_domains[@]}"; do
  if [[ -n "$http_rule" ]]; then
    http_rule+=" || "
    tcp_rule+=" || "
  fi
  http_rule+="Host(\`$host\`)"
  tcp_rule+="HostSNI(\`$host\`)"
done

cat > "$PROXY_PATH/dynamic/legacy-nginx.yaml" <<EOF
http:
  routers:
    legacy-nginx-http:
      rule: '$http_rule'
      entryPoints:
        - http
      service: legacy-nginx-http
      priority: 1
  services:
    legacy-nginx-http:
      loadBalancer:
        passHostHeader: true
        servers:
          - url: 'http://host.docker.internal:8080'

tcp:
  routers:
    legacy-nginx-https:
      rule: '$tcp_rule'
      entryPoints:
        - https
      service: legacy-nginx-https
      tls:
        passthrough: true
  services:
    legacy-nginx-https:
      loadBalancer:
        servers:
          - address: 'host.docker.internal:8443'
EOF
chmod 600 "$PROXY_PATH/dynamic/legacy-nginx.yaml"

log "MOVE HOST NGINX TO INTERNAL PORTS"
MUTATED=1
mapfile -t nginx_targets < <(
  for link in /etc/nginx/sites-enabled/*; do
    [[ -e "$link" ]] || continue
    readlink -f "$link"
  done | sort -u
)

python3 - "${nginx_targets[@]}" <<'PY'
import pathlib, re, sys
for name in sys.argv[1:]:
    path = pathlib.Path(name)
    text = path.read_text()
    out = []
    changed = False
    for line in text.splitlines(keepends=True):
        if re.match(r'^\s*listen\s+', line):
            new = re.sub(r'(?<!\d)443(?!\d)', '8443', line)
            new = re.sub(r'(?<!\d)80(?!\d)', '8080', new)
            changed |= new != line
            line = new
        out.append(line)
    if changed:
        path.write_text(''.join(out))
        print(f'updated {path}')
PY

nginx -t
systemctl reload nginx
sleep 2

ss -ltn "sport = :8080" | grep -q ':8080' || fail "Nginx did not start on 8080"
ss -ltn "sport = :8443" | grep -q ':8443' || fail "Nginx did not start on 8443"
if ss -ltnH "sport = :80" | grep -q .; then fail "Port 80 is still occupied after Nginx move"; fi
if ss -ltnH "sport = :443" | grep -q .; then fail "Port 443 is still occupied after Nginx move"; fi

log "START COOLIFY TRAEFIK"
set_coolify_proxy_type TRAEFIK

for _ in $(seq 1 60); do
  if docker inspect coolify-proxy >/dev/null 2>&1 && [[ "$(docker inspect -f '{{.State.Running}}' coolify-proxy 2>/dev/null || true)" == "true" ]]; then
    break
  fi
  sleep 2
done

docker inspect coolify-proxy >/dev/null 2>&1 || fail "coolify-proxy was not created"
[[ "$(docker inspect -f '{{.State.Running}}' coolify-proxy)" == "true" ]] || fail "coolify-proxy is not running"

docker network connect "$TRACKPIXEL_UUID" coolify-proxy >/dev/null 2>&1 || true

for _ in $(seq 1 30); do
  if ss -ltnH "sport = :80" | grep -q . && ss -ltnH "sport = :443" | grep -q .; then
    break
  fi
  sleep 1
done
ss -ltnp "sport = :80" | grep -Eq 'docker-proxy|traefik' || fail "Traefik/Docker is not listening on public 80"
ss -ltnp "sport = :443" | grep -Eq 'docker-proxy|traefik' || fail "Traefik/Docker is not listening on public 443"

log "VALIDATE LEGACY SITES"
for host in "${legacy_domains[@]}"; do
  code="$(curl -k --connect-timeout 5 --max-time 15 --resolve "$host:443:127.0.0.1" -sS -o /dev/null -w '%{http_code}' "https://$host/" || true)"
  echo "$host https=$code"
  [[ "$code" != "000" && -n "$code" ]] || fail "Legacy HTTPS routing failed for $host"
done

log "VALIDATE TRACKPIXEL HOMOLOG HTTPS"
track_ok=0
for _ in $(seq 1 45); do
  if curl --connect-timeout 5 --max-time 15 --resolve "$TRACK_DOMAIN:443:127.0.0.1" -fsS "https://$TRACK_DOMAIN/health" | grep -q 'ok'; then
    track_ok=1
    break
  fi
  sleep 4
done
[[ "$track_ok" -eq 1 ]] || fail "TrackPixel API HTTPS did not become healthy"

pixel_ok=0
for _ in $(seq 1 30); do
  code="$(curl --connect-timeout 5 --max-time 15 --resolve "$PIXEL_DOMAIN:443:127.0.0.1" -sS -o /dev/null -w '%{http_code}' "https://$PIXEL_DOMAIN/pixel.js" || true)"
  if [[ "$code" == "200" ]]; then
    pixel_ok=1
    break
  fi
  sleep 4
done
[[ "$pixel_ok" -eq 1 ]] || fail "TrackPixel pixel.js HTTPS did not become healthy"

log "FINAL STATE"
docker ps --filter name='^/coolify-proxy$' --format 'name={{.Names}} status={{.Status}} ports={{.Ports}}'
printf 'track=https://%s/health\n' "$TRACK_DOMAIN"
printf 'pixel=https://%s/pixel.js\n' "$PIXEL_DOMAIN"
printf 'legacy_nginx=http://host:8080 + tcp://host:8443\n'
printf 'backup=%s\n' "$BACKUP_DIR"

SUCCESS=1
trap - ERR INT TERM EXIT
echo
echo "TRAEFIK_CUTOVER_OK"
