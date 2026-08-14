#!/usr/bin/env bash
set -Eeuo pipefail

# Read-only inventory for migrating public 80/443 from host Nginx to Coolify/Traefik.
# It deliberately avoids printing environment variables, file contents outside
# selected Nginx directives, certificate keys, application secrets or Coolify credentials.

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/snap/bin"
TRACKPIXEL_RESOURCE_UUID="6b0kjkl407ufjocxoucpsgq1"

section() { printf '\n===== %s =====\n' "$*"; }

section "HOST"
printf 'timestamp=%s\n' "$(date -Is)"
printf 'hostname=%s\n' "$(hostname -f 2>/dev/null || hostname)"
printf 'kernel=%s\n' "$(uname -sr)"

section "PUBLIC LISTENERS"
if command -v ss >/dev/null 2>&1; then
  ss -ltnp 2>/dev/null | awk 'NR==1 || $4 ~ /:(80|443|8000|6001|6002)$/ {print}' || true
else
  echo 'ss not found'
fi

section "NGINX STATUS"
if command -v nginx >/dev/null 2>&1; then
  nginx -v 2>&1 || true
  systemctl is-active nginx 2>/dev/null || true
  nginx -t 2>&1 || true
else
  echo 'nginx not found'
fi

section "NGINX ENABLED SITES"
if [[ -d /etc/nginx/sites-enabled ]]; then
  find /etc/nginx/sites-enabled -maxdepth 1 -mindepth 1 -printf '%f -> %l\n' 2>/dev/null | sort || true
else
  echo '/etc/nginx/sites-enabled not found'
fi

section "NGINX PUBLIC ROUTING DIRECTIVES"
if command -v nginx >/dev/null 2>&1; then
  # Preserve source-file markers and only routing-related directives. Do not dump
  # headers, auth values, maps or arbitrary config contents.
  nginx -T 2>&1 | awk '
    /^# configuration file / { file=$0; next }
    /^[[:space:]]*(listen|server_name|root|alias|proxy_pass|return|ssl_certificate)[[:space:]]/ {
      if (file != lastfile) { print file; lastfile=file }
      line=$0
      if (line ~ /^[[:space:]]*ssl_certificate_key[[:space:]]/) next
      print line
    }
  ' || true
fi

section "LETSENCRYPT CERT NAMES"
if [[ -d /etc/letsencrypt/live ]]; then
  find /etc/letsencrypt/live -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null | sort || true
else
  echo '/etc/letsencrypt/live not found'
fi

section "DOCKER CORE"
if command -v docker >/dev/null 2>&1; then
  docker version --format 'server={{.Server.Version}}' 2>/dev/null || true
  docker compose version 2>/dev/null || true
  echo '-- containers --'
  docker ps -a --format 'name={{.Names}} state={{.State}} status={{.Status}} ports={{.Ports}}' 2>/dev/null | sort || true
  echo '-- networks --'
  docker network ls --format 'name={{.Name}} driver={{.Driver}} scope={{.Scope}}' 2>/dev/null | sort || true
else
  echo 'docker not found'
fi

section "COOLIFY PROXY STATE"
if docker inspect coolify >/dev/null 2>&1; then
  docker exec coolify php artisan tinker --execute='App\Models\Server::query()->orderBy("id")->get()->each(function($s){ dump(["id"=>$s->id,"uuid"=>$s->uuid,"name"=>$s->name,"ip"=>$s->ip,"proxy_type"=>$s->proxyType(),"proxy_status"=>data_get($s,"proxy.status")]); });' 2>&1 || true
else
  echo 'coolify container not found'
fi

if docker inspect coolify-proxy >/dev/null 2>&1; then
  echo '-- coolify-proxy --'
  docker ps -a --filter name='^/coolify-proxy$' --format 'name={{.Names}} state={{.State}} status={{.Status}} ports={{.Ports}}' 2>/dev/null || true
else
  echo 'coolify-proxy container: absent'
fi

section "TRACKPIXEL COOLIFY CONTAINERS"
mapfile -t TP_CONTAINERS < <(
  docker ps -a --format '{{.Names}}' 2>/dev/null |
    grep -E "${TRACKPIXEL_RESOURCE_UUID}|^(api|pixel|worker|postgres|redis|migrate)-" || true
)
if ((${#TP_CONTAINERS[@]} == 0)); then
  echo 'No matching TrackPixel containers found'
else
  for c in "${TP_CONTAINERS[@]}"; do
    echo "-- $c --"
    docker inspect -f 'state={{.State.Status}} health={{if .State.Health}}{{.State.Health.Status}}{{else}}n/a{{end}} ports={{json .NetworkSettings.Ports}}' "$c" 2>/dev/null || true
    docker inspect -f '{{json .Config.Labels}}' "$c" 2>/dev/null |
      python3 -c 'import json,sys; d=json.load(sys.stdin) or {}; [print(f"{k}={d[k]}") for k in sorted(d) if k.startswith(("traefik.","coolify."))]' || true
  done
fi

section "TRACKPIXEL HOST PORT CHECK"
for port in 3100 3101; do
  if ss -ltnH "sport = :$port" 2>/dev/null | grep -q .; then
    echo "port_$port=LISTENING"
    ss -ltnp "sport = :$port" 2>/dev/null || true
  else
    echo "port_$port=not-listening"
  fi
done

section "DONE"
echo 'INVENTORY_OK'
