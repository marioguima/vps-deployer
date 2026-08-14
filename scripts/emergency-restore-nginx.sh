#!/usr/bin/env bash
set -Eeuo pipefail

if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
  echo "Run as root: sudo bash $0" >&2
  exit 1
fi

BACKUP_ROOT="/root/trackpixel-traefik-cutover"
LATEST_BACKUP="$(find "$BACKUP_ROOT" -mindepth 2 -maxdepth 2 -type f -name nginx.tar.gz -printf '%T@ %p\n' 2>/dev/null | sort -nr | awk 'NR==1{$1=""; sub(/^ /,""); print}')"

if [[ -z "$LATEST_BACKUP" || ! -f "$LATEST_BACKUP" ]]; then
  echo "ERROR: no nginx backup found under $BACKUP_ROOT" >&2
  exit 2
fi

echo "Using backup: $LATEST_BACKUP"

echo "Stopping Coolify Traefik if present..."
docker rm -f coolify-proxy >/dev/null 2>&1 || true

echo "Setting Coolify proxy back to NONE..."
docker exec coolify php artisan tinker --execute='$s=App\Models\Server::find(0); if ($s) { $s->proxy->set("type", "NONE"); $s->proxy->set("status", "exited"); $s->save(); }' >/dev/null 2>&1 || true

echo "Restoring /etc/nginx from pre-cutover backup..."
rm -rf /etc/nginx
tar -xzf "$LATEST_BACKUP" -C /

nginx -t
systemctl enable nginx >/dev/null 2>&1 || true
systemctl restart nginx
sleep 2

echo
echo "Listeners after restore:"
ss -ltnp 'sport = :80' || true
ss -ltnp 'sport = :443' || true

echo
echo "Enabled sites after restore:"
find /etc/nginx/sites-enabled -maxdepth 1 -mindepth 1 -printf '%f -> %l\n' 2>/dev/null | sort || true

ss -ltnp 'sport = :80' | grep -q nginx || { echo "ERROR: nginx is not listening on 80" >&2; exit 3; }
ss -ltnp 'sport = :443' | grep -q nginx || { echo "ERROR: nginx is not listening on 443" >&2; exit 4; }

echo
echo "NGINX_RESTORE_OK"
