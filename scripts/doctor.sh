#!/usr/bin/env bash
set -euo pipefail
ENV_FILE="${VPS_DEPLOYER_ENV_FILE:-/etc/vps-deployer/env}"
APP="${VPS_DEPLOYER_APP:-/opt/vps-deployer/app/vps_deployer.py}"
[[ -f "$ENV_FILE" ]] || { echo "Missing $ENV_FILE" >&2; exit 1; }
[[ -f "$APP" ]] || { echo "Missing $APP" >&2; exit 1; }
set -a
source "$ENV_FILE"
set +a

python3 "$APP" doctor

# GitHub App is optional for public-only installations. If any App identity is
# configured, validate the complete local configuration without making a network
# request or printing secrets.
if [[ -n "${GITHUB_APP_CLIENT_ID:-}" || -n "${GITHUB_APP_ID:-}" ]]; then
  [[ -n "${GITHUB_APP_CLIENT_ID:-}" ]] || {
    echo "Missing GITHUB_APP_CLIENT_ID" >&2
    exit 1
  }
  [[ -n "${GITHUB_APP_PRIVATE_KEY:-}" ]] || {
    echo "Missing GITHUB_APP_PRIVATE_KEY" >&2
    exit 1
  }
  [[ -f "$GITHUB_APP_PRIVATE_KEY" ]] || {
    echo "Missing GitHub App private key: $GITHUB_APP_PRIVATE_KEY" >&2
    exit 1
  }
  command -v openssl >/dev/null || { echo "Missing openssl" >&2; exit 1; }
  command -v git >/dev/null || { echo "Missing git" >&2; exit 1; }
  command -v vps-deployer-git >/dev/null || { echo "Missing vps-deployer-git" >&2; exit 1; }
  command -v vps-deployer-checkout >/dev/null || { echo "Missing vps-deployer-checkout" >&2; exit 1; }
  runuser -u vps-deployer -- test -r "$GITHUB_APP_PRIVATE_KEY" || {
    echo "vps-deployer cannot read GitHub App private key: $GITHUB_APP_PRIVATE_KEY" >&2
    exit 1
  }
  echo "OK GitHub App local configuration (Client ID + readable private key)"
fi
