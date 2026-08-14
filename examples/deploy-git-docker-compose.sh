#!/usr/bin/env bash
set -euo pipefail

ENVIRONMENT="${1:?usage: deploy-git-docker-compose.sh <environment>}"
: "${DEPLOY_REPOSITORY:?missing DEPLOY_REPOSITORY}"
: "${DEPLOY_BRANCH:?missing DEPLOY_BRANCH}"
: "${DEPLOY_SHA:?missing DEPLOY_SHA}"

SAFE_NAME="${DEPLOY_REPOSITORY//\//-}"
ROOT="/var/lib/vps-deployer/workspaces/$SAFE_NAME/$ENVIRONMENT"
REPO_DIR="$ROOT/repo"
mkdir -p "$ROOT"

# Authenticates with the GitHub App and guarantees that HEAD is exactly the
# full SHA received in the signed webhook. No SSH deploy key, PAT or token in
# the remote URL is required.
vps-deployer-checkout "$REPO_DIR"

cd "$REPO_DIR"
docker compose build
docker compose up -d
docker compose ps
