#!/usr/bin/env bash
set -euo pipefail

ENVIRONMENT="${1:?usage: deploy-git-docker-compose.sh <environment>}"
: "${DEPLOY_REPOSITORY:?missing DEPLOY_REPOSITORY}"
: "${DEPLOY_SHA:?missing DEPLOY_SHA}"

SAFE_NAME="${DEPLOY_REPOSITORY//\//-}"
ROOT="/var/lib/vps-deployer/workspaces/$SAFE_NAME/$ENVIRONMENT"
REPO_DIR="$ROOT/repo"
mkdir -p "$ROOT"

if [[ ! -d "$REPO_DIR/.git" ]]; then
  git clone "git@github.com:${DEPLOY_REPOSITORY}.git" "$REPO_DIR"
fi

cd "$REPO_DIR"
git fetch --prune origin
git checkout --detach "$DEPLOY_SHA"
docker compose build
docker compose up -d
docker compose ps
