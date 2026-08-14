#!/usr/bin/env bash
set -euo pipefail

if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
  echo "Run as root: sudo ./scripts/setup-ip-tls.sh <PUBLIC_IP> <EMAIL>" >&2
  exit 1
fi

PUBLIC_IP="${1:-}"
EMAIL="${2:-}"
[[ -n "$PUBLIC_IP" && -n "$EMAIL" ]] || { echo "Usage: sudo $0 <PUBLIC_IP> <EMAIL>" >&2; exit 1; }
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
command -v nginx >/dev/null || { echo "nginx is required" >&2; exit 1; }
command -v certbot >/dev/null || { echo "certbot >= 5.4 is required for IP certificates" >&2; exit 1; }
python3 - "$PUBLIC_IP" <<'PY'
import ipaddress, sys
ipaddress.ip_address(sys.argv[1])
PY
CERTBOT_VERSION="$(certbot --version 2>&1 | awk '{print $2}')"
if ! python3 - "$CERTBOT_VERSION" <<'PY'
import re, sys
m = re.match(r'^(\d+)\.(\d+)', sys.argv[1])
raise SystemExit(0 if m and (int(m.group(1)), int(m.group(2))) >= (5, 4) else 1)
PY
then
  echo "Detected Certbot $CERTBOT_VERSION at $(command -v certbot)" >&2
  echo "certbot >= 5.4 is required for webroot IP certificates" >&2
  echo >&2
  echo "No Nginx/TLS changes were made." >&2
  echo "Diagnose the current installation with:" >&2
  echo "  certbot --version" >&2
  echo "  command -v certbot" >&2
  echo "  snap list certbot 2>/dev/null || true" >&2
  echo "  dpkg -l | grep -E 'certbot|python3-certbot' || true" >&2
  echo >&2
  echo "Then follow docs/TROUBLESHOOTING.md#certbot-antigo-para-certificado-de-ip" >&2
  exit 2
fi

install -d -m 0755 /var/www/vps-deployer-acme
BOOTSTRAP=/etc/nginx/sites-available/vps-deployer-ip.conf
cat > "$BOOTSTRAP" <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name $PUBLIC_IP;
    location ^~ /.well-known/acme-challenge/ { root /var/www/vps-deployer-acme; }
    location / { return 404; }
}
EOF
ln -sfn "$BOOTSTRAP" /etc/nginx/sites-enabled/vps-deployer-ip.conf
nginx -t
systemctl reload nginx
certbot certonly --non-interactive --agree-tos --email "$EMAIL" --preferred-profile shortlived --webroot --webroot-path /var/www/vps-deployer-acme --ip-address "$PUBLIC_IP" --cert-name vps-deployer-ip
sed -e "s/__PUBLIC_IP__/$PUBLIC_IP/g" "$ROOT_DIR/nginx/vps-deployer-ip.conf.template" > "$BOOTSTRAP"
nginx -t
systemctl reload nginx
install -d -m 0755 /etc/letsencrypt/renewal-hooks/deploy
cat > /etc/letsencrypt/renewal-hooks/deploy/reload-nginx-vps-deployer.sh <<'EOF'
#!/usr/bin/env bash
set -eu
nginx -t && systemctl reload nginx
EOF
chmod 0755 /etc/letsencrypt/renewal-hooks/deploy/reload-nginx-vps-deployer.sh

echo "HTTPS webhook endpoint ready: https://$PUBLIC_IP/github"
echo "Health endpoint: https://$PUBLIC_IP/health"
echo "Ensure ports 80 and 443 are allowed by both VPS firewall and cloud/network security rules."
if systemctl list-timers --all 2>/dev/null | grep -qi certbot; then
  echo "Certbot renewal timer detected."
else
  echo "WARNING: no Certbot renewal timer detected. Configure automatic renewal before relying on IP TLS." >&2
fi