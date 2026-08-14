#!/usr/bin/env bash
set -euo pipefail
ENV_FILE="${VPS_DEPLOYER_ENV_FILE:-/etc/vps-deployer/env}"
APP="${VPS_DEPLOYER_APP:-/opt/vps-deployer/app/vps_deployer.py}"
set -a
source "$ENV_FILE"
set +a
exec python3 "$APP" jobs "$@"
