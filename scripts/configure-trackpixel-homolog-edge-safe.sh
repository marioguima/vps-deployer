#!/usr/bin/env bash
set -Eeuo pipefail

# Isolated TrackPixel homolog edge setup.
# This script ONLY creates/updates the TrackPixel homolog Nginx vhost.
# It does not modify, move, disable, or delete any other enabled site.

if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
  echo "Run as root: sudo bash $0" >&2
  exit 1
fi

TRACK_DOMAIN="track-homolog.intellifyads.com"
PIXEL_DOMAIN="pixel-homolog.intellifyads.com"
API_UPSTREAM="127.0.0.1:3100"
PIXEL_UPSTREAM="127.0.0.1:3101"
EXPECTED_IP="136.248.109.197"
SITE_NAME="trackpixel-homolog.conf"
SITE_AVAILABLE="/etc/nginx/sites-available/$SITE_NAME"
SITE_ENABLED="/etc/nginx/sites-enabled/$SITE_NAME"
CERT_NAME="trackpixel-homolog"
CERT_DIR="/etc/letsencrypt/live/$CERT_NAME"
ACME_ROOT="/var/www/certbot"
BACKUP_DIR="/root/trackpixel-edge-backups/$(date -u +%Y%m%dT%H%M%SZ)"
CREATED_SITE=0

log() { printf '\n===== %s =====\n' "$*"; }
fail() { echo "ERROR: $*" >&2; exit 1; }

for cmd in nginx certbot curl python3 ss systemctl grep; do
  command -v "$cmd" >/dev/null 2>&1 || fail "$cmd is required"
done

log "PREFLIGHT - TRACKPIXEL ONLY"
systemctl is-active --quiet nginx || fail "Nginx is not active"
nginx -t

# Fail before touching Nginx if Coolify has not published TrackPixel locally yet.
api_body="$(curl -fsS --connect-timeout 3 --max-time 5 "http://$API_UPSTREAM/health" 2>/dev/null || true)"
[[ "$api_body" == *"ok"* ]] || fail "TrackPixel API is not ready on http://$API_UPSTREAM/health. No Nginx changes were made."

pixel_body="$(curl -fsS --connect-timeout 3 --max-time 5 "http://$PIXEL_UPSTREAM/health" 2>/dev/null || true)"
[[ "$pixel_body" == *"ok"* ]] || fail "TrackPixel pixel service is not ready on http://$PIXEL_UPSTREAM/health. No Nginx changes were made."

echo "api_local=ok"
echo "pixel_local=ok"

resolve_cf() {
  curl -fsS "https://cloudflare-dns.com/dns-query?name=$1&type=A" -H 'accept: application/dns-json' |
    python3 -c 'import json,sys; d=json.load(sys.stdin); print("\n".join(str(x.get("data")) for x in d.get("Answer",[]) if x.get("type")==1))'
}

for host in "$TRACK_DOMAIN" "$PIXEL_DOMAIN"; do
  ips="$(resolve_cf "$host")"
  echo "$host -> $(tr '\n' ' ' <<<"$ips")"
  grep -Fxq "$EXPECTED_IP" <<<"$ips" || fail "$host does not resolve to $EXPECTED_IP. No Nginx changes were made."
done

mkdir -p "$BACKUP_DIR" "$ACME_ROOT"
chmod 700 "$BACKUP_DIR"

# Backup ONLY the TrackPixel vhost if it already exists.
if [[ -e "$SITE_AVAILABLE" || -L "$SITE_ENABLED" || -e "$SITE_ENABLED" ]]; then
  cp -a "$SITE_AVAILABLE" "$BACKUP_DIR/" 2>/dev/null || true
  cp -a "$SITE_ENABLED" "$BACKUP_DIR/sites-enabled-$SITE_NAME" 2>/dev/null || true
fi

rollback_trackpixel_only() {
  rc=$?
  trap - ERR INT TERM EXIT
  echo "TrackPixel edge setup failed; rolling back ONLY TrackPixel vhost." >&2
  rm -f "$SITE_ENABLED" "$SITE_AVAILABLE"
  if [[ -f "$BACKUP_DIR/$SITE_NAME" ]]; then
    cp -a "$BACKUP_DIR/$SITE_NAME" "$SITE_AVAILABLE"
  fi
  if [[ -e "$BACKUP_DIR/sites-enabled-$SITE_NAME" || -L "$BACKUP_DIR/sites-enabled-$SITE_NAME" ]]; then
    cp -a "$BACKUP_DIR/sites-enabled-$SITE_NAME" "$SITE_ENABLED"
  fi
  nginx -t >/dev/null 2>&1 && systemctl reload nginx || true
  exit "$rc"
}
trap rollback_trackpixel_only ERR INT TERM EXIT

log "BOOTSTRAP TRACKPIXEL VHOST"
cat > "$SITE_AVAILABLE" <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name $TRACK_DOMAIN;

    location /.well-known/acme-challenge/ {
        root $ACME_ROOT;
    }

    location / {
        proxy_pass http://$API_UPSTREAM;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}

server {
    listen 80;
    listen [::]:80;
    server_name $PIXEL_DOMAIN;

    location /.well-known/acme-challenge/ {
        root $ACME_ROOT;
    }

    location / {
        proxy_pass http://$PIXEL_UPSTREAM;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
EOF
ln -sfn "$SITE_AVAILABLE" "$SITE_ENABLED"
CREATED_SITE=1
nginx -t
systemctl reload nginx

log "TLS CERTIFICATE"
if [[ ! -s "$CERT_DIR/fullchain.pem" || ! -s "$CERT_DIR/privkey.pem" ]]; then
  certbot certonly \
    --webroot -w "$ACME_ROOT" \
    --cert-name "$CERT_NAME" \
    -d "$TRACK_DOMAIN" \
    -d "$PIXEL_DOMAIN" \
    --non-interactive \
    --agree-tos \
    --register-unsafely-without-email
else
  echo "Existing certificate found: $CERT_DIR"
fi

[[ -s "$CERT_DIR/fullchain.pem" && -s "$CERT_DIR/privkey.pem" ]] || fail "Certificate files not found after Certbot"

log "FINAL TRACKPIXEL VHOST"
cat > "$SITE_AVAILABLE" <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name $TRACK_DOMAIN $PIXEL_DOMAIN;

    location /.well-known/acme-challenge/ {
        root $ACME_ROOT;
    }

    location / {
        return 301 https://\$host\$request_uri;
    }
}

server {
    listen 443 ssl;
    listen [::]:443 ssl;
    server_name $TRACK_DOMAIN;

    ssl_certificate $CERT_DIR/fullchain.pem;
    ssl_certificate_key $CERT_DIR/privkey.pem;

    location / {
        proxy_pass http://$API_UPSTREAM;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
    }
}

server {
    listen 443 ssl;
    listen [::]:443 ssl;
    server_name $PIXEL_DOMAIN;

    ssl_certificate $CERT_DIR/fullchain.pem;
    ssl_certificate_key $CERT_DIR/privkey.pem;

    location / {
        proxy_pass http://$PIXEL_UPSTREAM;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
    }
}
EOF

nginx -t
systemctl reload nginx
sleep 2

log "VALIDATE TRACKPIXEL HOMOLOG"
track_body="$(curl --connect-timeout 5 --max-time 15 --resolve "$TRACK_DOMAIN:443:127.0.0.1" -fsS "https://$TRACK_DOMAIN/health")"
[[ "$track_body" == *"ok"* ]] || fail "TrackPixel API HTTPS validation failed"

pixel_code="$(curl --connect-timeout 5 --max-time 15 --resolve "$PIXEL_DOMAIN:443:127.0.0.1" -sS -o /dev/null -w '%{http_code}' "https://$PIXEL_DOMAIN/pixel.js")"
[[ "$pixel_code" == "200" ]] || fail "TrackPixel pixel.js HTTPS validation failed: HTTP $pixel_code"

# Confirm existing enabled sites are still present; this script never removes them.
echo "nginx=active"
echo "track=https://$TRACK_DOMAIN/health"
echo "pixel=https://$PIXEL_DOMAIN/pixel.js"
echo "trackpixel_vhost=$SITE_ENABLED"
echo "backup=$BACKUP_DIR"

trap - ERR INT TERM EXIT
echo
echo "TRACKPIXEL_HOMOLOG_EDGE_OK"
