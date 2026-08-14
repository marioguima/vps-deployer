#!/usr/bin/env bash
set -euo pipefail

if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
  echo "Run as root: sudo ./scripts/uninstall.sh" >&2
  exit 1
fi

systemctl disable --now vps-deployer 2>/dev/null || true
rm -f /etc/systemd/system/vps-deployer.service
systemctl daemon-reload
rm -rf /opt/vps-deployer/app

echo "Service removed. Configuration, job database, logs and project scripts were intentionally preserved:"
echo "  /etc/vps-deployer"
echo "  /var/lib/vps-deployer"
echo "  /var/log/vps-deployer"
echo "  /opt/vps-deployer/project-scripts"
