#!/usr/bin/env bash
set -Eeuo pipefail

# Transitional public bootstrap for TrackPixel host edge while Coolify owns
# application deploys and host Nginx owns 80/443.
# Before vps-deployer is removed, move this script to the permanent infra repo.

if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
  echo "Run as root: sudo env CERTBOT_EMAIL=you@example.com bash configure-trackpixel-edge.sh <homolog|production> [expected-public-ip]" >&2
  exit 1
fi

ENVIRONMENT="${1:-}"
EXPECTED_IP="${2:-}"
CERTBOT_EMAIL="${CERTBOT_EMAIL:-}"

case "$ENVIRONMENT" in
  homolog)
    TRACK_DOMAIN="track-homolog.intellifyads.com"
    PIXEL_DOMAIN="pixel-homolog.intellifyads.com"
    API_PORT=3100
    PIXEL_PORT=3101
    NGINX_SITE="trackpixel-homolog"
    ;;
  production)
    TRACK_DOMAIN="track.intellifyads.com"
    PIXEL_DOMAIN="pixel.intellifyads.com"
    API_PORT=3000
    PIXEL_PORT=3001
    NGINX_SITE="trackpixel-production"
    ;;
  *)
    echo "Environment must be homolog or production" >&2
    exit 2
    ;;
esac

[[ -n "$CERTBOT_EMAIL" && "$CERTBOT_EMAIL" == *@*.* ]] || {
  echo "CERTBOT_EMAIL must be set" >&2
  exit 2
}

log() { printf '\n== %s ==\n' "$*"; }
fail() { echo "ERROR: $*" >&2; exit 1; }

log "Dependencies"
[[ -r /etc/os-release ]] || fail "/etc/os-release not found"
# shellcheck disable=SC1091
. /etc/os-release
missing=()
for cmd in nginx certbot curl python3 openssl; do
  command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
done
if ((${#missing[@]})); then
  [[ "${ID:-}" == "ubuntu" || "${ID:-}" == "debian" ]] || fail "Automatic package install supports Debian/Ubuntu only"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y nginx certbot curl python3 openssl
fi
systemctl enable --now nginx
nginx -t
install -d -m 0755 /var/www/certbot /etc/nginx/sites-available /etc/nginx/sites-enabled

log "Application readiness"
curl -fsS "http://127.0.0.1:${API_PORT}/health" >/dev/null || fail "API not healthy on 127.0.0.1:${API_PORT}"
curl -fsS "http://127.0.0.1:${PIXEL_PORT}/health" >/dev/null || fail "Pixel not healthy on 127.0.0.1:${PIXEL_PORT}"
echo "Local API and Pixel health checks passed"

resolve_a() {
  curl -fsS "https://cloudflare-dns.com/dns-query?name=$1&type=A" -H 'accept: application/dns-json' |
    python3 -c 'import json,sys; d=json.load(sys.stdin); print("\n".join(str(x.get("data")) for x in d.get("Answer",[]) if x.get("type")==1))'
}

log "Public DNS"
TRACK_IPS="$(resolve_a "$TRACK_DOMAIN")"
PIXEL_IPS="$(resolve_a "$PIXEL_DOMAIN")"
[[ -n "$TRACK_IPS" ]] || fail "No A record for $TRACK_DOMAIN"
[[ -n "$PIXEL_IPS" ]] || fail "No A record for $PIXEL_DOMAIN"
printf '%s -> %s\n' "$TRACK_DOMAIN" "$(tr '\n' ' ' <<<"$TRACK_IPS")"
printf '%s -> %s\n' "$PIXEL_DOMAIN" "$(tr '\n' ' ' <<<"$PIXEL_IPS")"
if [[ -n "$EXPECTED_IP" ]]; then
  grep -Fxq "$EXPECTED_IP" <<<"$TRACK_IPS" || fail "$TRACK_DOMAIN does not resolve to $EXPECTED_IP"
  grep -Fxq "$EXPECTED_IP" <<<"$PIXEL_IPS" || fail "$PIXEL_DOMAIN does not resolve to $EXPECTED_IP"
fi

SITE_AVAILABLE="/etc/nginx/sites-available/${NGINX_SITE}.conf"
SITE_ENABLED="/etc/nginx/sites-enabled/${NGINX_SITE}.conf"
CERT_DIR="/etc/letsencrypt/live/$TRACK_DOMAIN"
TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT

cert_ok() {
  [[ -f "$CERT_DIR/fullchain.pem" ]] || return 1
  openssl x509 -in "$CERT_DIR/fullchain.pem" -noout -checkend 86400 >/dev/null 2>&1 || return 1
  local san
  san="$(openssl x509 -in "$CERT_DIR/fullchain.pem" -noout -ext subjectAltName 2>/dev/null || true)"
  grep -Fq "DNS:$TRACK_DOMAIN" <<<"$san" && grep -Fq "DNS:$PIXEL_DOMAIN" <<<"$san"
}

log "Nginx + TLS"
if ! cert_ok; then
  cat >"$TMP" <<EOF
server {
  listen 80;
  server_name $TRACK_DOMAIN $PIXEL_DOMAIN;
  location /.well-known/acme-challenge/ { root /var/www/certbot; }
  location / { return 200 'TrackPixel TLS bootstrap'; add_header Content-Type text/plain; }
}
EOF
  install -m 0644 "$TMP" "$SITE_AVAILABLE"
  ln -sfn "$SITE_AVAILABLE" "$SITE_ENABLED"
  nginx -t
  systemctl reload nginx
  certbot certonly --webroot -w /var/www/certbot --non-interactive --agree-tos \
    --email "$CERTBOT_EMAIL" --cert-name "$TRACK_DOMAIN" \
    -d "$TRACK_DOMAIN" -d "$PIXEL_DOMAIN"
else
  echo "Existing certificate is valid for both domains"
fi

cat >"$TMP" <<EOF
server {
  listen 80;
  server_name $TRACK_DOMAIN $PIXEL_DOMAIN;
  location /.well-known/acme-challenge/ { root /var/www/certbot; }
  location / { return 301 https://\$host\$request_uri; }
}
server {
  listen 443 ssl;
  server_name $TRACK_DOMAIN;
  ssl_certificate /etc/letsencrypt/live/$TRACK_DOMAIN/fullchain.pem;
  ssl_certificate_key /etc/letsencrypt/live/$TRACK_DOMAIN/privkey.pem;
  location / {
    proxy_pass http://127.0.0.1:$API_PORT;
    proxy_set_header Host \$host;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto \$scheme;
  }
}
server {
  listen 443 ssl;
  server_name $PIXEL_DOMAIN;
  ssl_certificate /etc/letsencrypt/live/$TRACK_DOMAIN/fullchain.pem;
  ssl_certificate_key /etc/letsencrypt/live/$TRACK_DOMAIN/privkey.pem;
  location / {
    proxy_pass http://127.0.0.1:$PIXEL_PORT;
    proxy_set_header Host \$host;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto \$scheme;
  }
}
EOF
install -m 0644 "$TMP" "$SITE_AVAILABLE"
ln -sfn "$SITE_AVAILABLE" "$SITE_ENABLED"
nginx -t
systemctl reload nginx

log "HTTPS validation"
if [[ -n "$EXPECTED_IP" ]]; then
  curl --retry 10 --retry-delay 2 --retry-connrefused --resolve "$TRACK_DOMAIN:443:$EXPECTED_IP" -fsS "https://$TRACK_DOMAIN/health" >/dev/null
  curl --retry 10 --retry-delay 2 --retry-connrefused --resolve "$PIXEL_DOMAIN:443:$EXPECTED_IP" -fsSI "https://$PIXEL_DOMAIN/pixel.js" >/dev/null
else
  curl --retry 10 --retry-delay 2 --retry-connrefused -fsS "https://$TRACK_DOMAIN/health" >/dev/null
  curl --retry 10 --retry-delay 2 --retry-connrefused -fsSI "https://$PIXEL_DOMAIN/pixel.js" >/dev/null
fi

echo
echo "TRACKPIXEL_EDGE_OK environment=$ENVIRONMENT track=https://$TRACK_DOMAIN pixel=https://$PIXEL_DOMAIN/pixel.js"
