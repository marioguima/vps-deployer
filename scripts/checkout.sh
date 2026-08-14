#!/usr/bin/env bash
set -euo pipefail

TARGET_DIR="${1:-}"
REPOSITORY="${DEPLOY_REPOSITORY:-}"
BRANCH="${DEPLOY_BRANCH:-}"
SHA="${DEPLOY_SHA:-}"

usage() {
  cat >&2 <<'EOF'
Usage:
  vps-deployer-checkout TARGET_DIR

Required environment variables:
  DEPLOY_REPOSITORY=owner/repo
  DEPLOY_BRANCH=branch
  DEPLOY_SHA=40-character commit SHA

The command initializes/updates a clean Git working tree and checks out exactly
DEPLOY_SHA. Authentication is delegated to vps-deployer-git.
EOF
}

[[ -n "$TARGET_DIR" ]] || { usage; exit 2; }
[[ "$REPOSITORY" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || {
  echo "Invalid or missing DEPLOY_REPOSITORY: $REPOSITORY" >&2
  exit 2
}
[[ "$BRANCH" =~ ^[A-Za-z0-9._/-]+$ ]] || {
  echo "Invalid or missing DEPLOY_BRANCH: $BRANCH" >&2
  exit 2
}
[[ "$SHA" =~ ^[0-9a-fA-F]{40}$ ]] || {
  echo "Invalid or missing DEPLOY_SHA; expected a full 40-character SHA" >&2
  exit 2
}

command -v git >/dev/null || { echo "git is required" >&2; exit 2; }
command -v vps-deployer-git >/dev/null || { echo "vps-deployer-git is required" >&2; exit 2; }

EXPECTED_URL="https://github.com/${REPOSITORY}.git"
PARENT_DIR="$(dirname "$TARGET_DIR")"

[[ -d "$PARENT_DIR" ]] || {
  echo "Parent directory does not exist: $PARENT_DIR" >&2
  echo "Project directories must be created during one-time onboarding." >&2
  exit 2
}
[[ -w "$PARENT_DIR" ]] || {
  echo "Parent directory is not writable: $PARENT_DIR" >&2
  exit 2
}

if [[ ! -e "$TARGET_DIR" ]]; then
  mkdir "$TARGET_DIR"
fi
[[ -d "$TARGET_DIR" ]] || { echo "Target is not a directory: $TARGET_DIR" >&2; exit 2; }

if [[ ! -d "$TARGET_DIR/.git" ]]; then
  if [[ -n "$(find "$TARGET_DIR" -mindepth 1 -maxdepth 1 -print -quit)" ]]; then
    echo "Refusing to initialize non-empty non-Git directory: $TARGET_DIR" >&2
    exit 2
  fi
  git -C "$TARGET_DIR" init -q
  git -C "$TARGET_DIR" remote add origin "$EXPECTED_URL"
else
  ACTUAL_URL="$(git -C "$TARGET_DIR" remote get-url origin 2>/dev/null || true)"
  [[ "$ACTUAL_URL" == "$EXPECTED_URL" ]] || {
    echo "origin mismatch in $TARGET_DIR" >&2
    echo "expected: $EXPECTED_URL" >&2
    echo "actual:   ${ACTUAL_URL:-<missing>}" >&2
    exit 2
  }
fi

# First fetch the authorized branch. For normal pushes this also brings the exact
# webhook SHA. The explicit SHA fetch is a fallback for unusual histories.
vps-deployer-git --cwd "$TARGET_DIR" "$REPOSITORY" -- \
  fetch --no-tags --prune origin \
  "+refs/heads/${BRANCH}:refs/remotes/origin/${BRANCH}"

if ! git -C "$TARGET_DIR" cat-file -e "${SHA}^{commit}" 2>/dev/null; then
  vps-deployer-git --cwd "$TARGET_DIR" "$REPOSITORY" -- \
    fetch --no-tags origin "$SHA"
fi

git -C "$TARGET_DIR" cat-file -e "${SHA}^{commit}" 2>/dev/null || {
  echo "Webhook SHA is not available after fetch: $SHA" >&2
  exit 1
}

git -C "$TARGET_DIR" checkout -q --detach --force "$SHA"
git -C "$TARGET_DIR" reset -q --hard "$SHA"
git -C "$TARGET_DIR" clean -q -fdx

ACTUAL_SHA="$(git -C "$TARGET_DIR" rev-parse HEAD)"
[[ "$ACTUAL_SHA" == "${SHA,,}" ]] || {
  echo "Checkout verification failed: expected $SHA, got $ACTUAL_SHA" >&2
  exit 1
}

echo "checkout_ok repository=$REPOSITORY branch=$BRANCH sha=${ACTUAL_SHA:0:12} target=$TARGET_DIR"
