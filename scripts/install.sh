#!/usr/bin/env bash
set -euo pipefail

if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
  echo "Run as root: sudo ./scripts/install.sh" >&2
  exit 1
fi

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR=/opt/vps-deployer/app
CONFIG_DIR=/etc/vps-deployer
STATE_DIR=/var/lib/vps-deployer
LOG_DIR=/var/log/vps-deployer
SCRIPT_DIR=/opt/vps-deployer/project-scripts
SERVICE_FILE=/etc/systemd/system/vps-deployer.service

command -v python3 >/dev/null || { echo "python3 is required" >&2; exit 1; }
PY_VERSION="$(python3 -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')"
python3 - <<'PY'
import sys
if sys.version_info < (3, 10):
    raise SystemExit("Python 3.10+ is required")
PY
echo "Using Python $PY_VERSION"

if ! id vps-deployer >/dev/null 2>&1; then
  useradd --system --home "$STATE_DIR" --shell /usr/sbin/nologin vps-deployer
fi
install -d -m 0755 /opt/vps-deployer "$APP_DIR" "$SCRIPT_DIR"
install -d -o vps-deployer -g vps-deployer -m 0750 "$STATE_DIR" "$LOG_DIR"
install -d -o root -g vps-deployer -m 0750 "$CONFIG_DIR"
install -m 0755 "$ROOT_DIR/src/vps_deployer.py" "$APP_DIR/vps_deployer.py"
install -m 0755 "$ROOT_DIR/scripts/doctor.sh" /usr/local/bin/vps-deployer-doctor
install -m 0755 "$ROOT_DIR/scripts/jobs.sh" /usr/local/bin/vps-deployer-jobs
install -m 0755 "$ROOT_DIR/scripts/retry.sh" /usr/local/bin/vps-deployer-retry
install -m 0644 "$ROOT_DIR/systemd/vps-deployer.service" "$SERVICE_FILE"

if [[ ! -f "$CONFIG_DIR/env" ]]; then
  install -o root -g vps-deployer -m 0640 "$ROOT_DIR/config/env.example" "$CONFIG_DIR/env"
  echo "Created $CONFIG_DIR/env (configure the webhook secret before starting)."
else
  echo "Preserving existing $CONFIG_DIR/env"
fi
if [[ ! -f "$CONFIG_DIR/projects.json" ]]; then
  printf '{\n  "deployments": []\n}\n' > "$CONFIG_DIR/projects.json"
  chown root:vps-deployer "$CONFIG_DIR/projects.json"
  chmod 0640 "$CONFIG_DIR/projects.json"
  echo "Created empty $CONFIG_DIR/projects.json"
else
  echo "Preserving existing $CONFIG_DIR/projects.json"
fi
if getent group docker >/dev/null 2>&1; then
  usermod -aG docker vps-deployer
  echo "Added vps-deployer to docker group (Docker access is effectively privileged)."
fi
systemctl daemon-reload

echo
echo "Installed. Next steps:"
echo "  1. sudo nano $CONFIG_DIR/env"
echo "  2. sudo nano $CONFIG_DIR/projects.json"
echo "  3. sudo vps-deployer-doctor"
echo "  4. sudo systemctl enable --now vps-deployer"
echo "  5. sudo systemctl status vps-deployer"
echo
echo "For recommended HTTPS on the public IP, run scripts/setup-ip-tls.sh after configuring the service."
