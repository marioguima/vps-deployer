#!/usr/bin/env bash
set -Eeuo pipefail

if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
  echo "Run as root: sudo bash ./scripts/repair-coolify-env.sh" >&2
  exit 1
fi

ENV_FILE=/data/coolify/source/.env
CREDS=/root/coolify-admin.txt
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="${ENV_FILE}.broken-${STAMP}"

[[ -f "$ENV_FILE" ]] || { echo "ERRO: $ENV_FILE not found" >&2; exit 1; }
docker inspect coolify >/dev/null 2>&1 || { echo "ERRO: coolify container not found" >&2; exit 1; }

cp -a "$ENV_FILE" "$BACKUP"
echo "Backup: $BACKUP"

ADMIN_EMAIL=""
if [[ -f "$CREDS" ]]; then
  ADMIN_EMAIL="$(sed -n 's/^EMAIL=//p' "$CREDS" | tail -n1 | tr -d '\r' || true)"
fi
if [[ -z "$ADMIN_EMAIL" && -f /etc/vps-deployer/env ]]; then
  ADMIN_EMAIL="$(sed -n 's/^VPS_DEPLOYER_CERTBOT_EMAIL=//p' /etc/vps-deployer/env | tail -n1 | tr -d '\r' || true)"
fi
[[ "$ADMIN_EMAIL" == *@*.* ]] || ADMIN_EMAIL="admin@intellifyads.com"

ADMIN_USERNAME="RootUser"
# Avoid ! because the original corruption happened while a command was pasted
# into an interactive shell with history expansion enabled.
ADMIN_PASSWORD="Aa1-$(openssl rand -hex 24)"

python3 - "$ENV_FILE" "$ADMIN_USERNAME" "$ADMIN_EMAIL" "$ADMIN_PASSWORD" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
username, email, password = sys.argv[2:5]
lines = path.read_text(encoding="utf-8").splitlines()
clean = []
removed = []
for line in lines:
    stripped = line.strip()
    if stripped.startswith(("ROOT_USERNAME=", "ROOT_USER_EMAIL=", "ROOT_USER_PASSWORD=")):
        removed.append(line)
        continue
    if "openssl rand -hex 20" in line or stripped.startswith("Aa1EMAIL="):
        removed.append(line)
        continue
    clean.append(line)

clean += [
    f"ROOT_USERNAME={username}",
    f"ROOT_USER_EMAIL={email}",
    f"ROOT_USER_PASSWORD={password}",
]
path.write_text("\n".join(clean) + "\n", encoding="utf-8")
print(f"Removed corrupted/root lines: {len(removed)}")
PY

chmod 600 "$ENV_FILE"

cat >"$CREDS" <<EOF
URL=http://136.248.109.197:8000
EMAIL=$ADMIN_EMAIL
USERNAME=$ADMIN_USERNAME
PASSWORD=$ADMIN_PASSWORD
EOF
chmod 600 "$CREDS"

echo "Restarting only Coolify application container..."
docker restart coolify >/dev/null

# Wait until Laravel can parse the repaired env. We intentionally test the
# health endpoint before touching any other container.
READY=0
for _ in $(seq 1 45); do
  CODE="$(curl -sS -o /tmp/coolify-health-body -w '%{http_code}' http://127.0.0.1:8000/api/health 2>/dev/null || true)"
  if [[ "$CODE" == "200" ]]; then
    READY=1
    break
  fi
  sleep 2
done

if (( READY == 0 )); then
  echo "ERRO: Coolify still does not return HTTP 200 after env repair" >&2
  docker logs --tail 80 coolify >&2 || true
  exit 1
fi

echo "Coolify health endpoint is responding. Ensuring root user exists..."
SEED_OUTPUT="$(docker exec coolify php artisan db:seed --class=RootUserSeeder --force 2>&1)" || {
  echo "$SEED_OUTPUT" >&2
  exit 1
}
printf '%s\n' "$SEED_OUTPUT"

# A healthy app is the hard success criterion. DB and realtime containers were
# already healthy before this repair and are intentionally left untouched.
HEALTH="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' coolify)"
HTTP_CODE="$(curl -sS -o /dev/null -w '%{http_code}' http://127.0.0.1:8000/api/health)"

echo "coolify_container_health=$HEALTH"
echo "coolify_http_health=$HTTP_CODE"
echo "credentials=$CREDS"

if [[ "$HTTP_CODE" == "200" ]]; then
  echo "COOLIFY_ENV_REPAIR_OK"
else
  echo "COOLIFY_ENV_REPAIR_FAILED" >&2
  exit 1
fi
