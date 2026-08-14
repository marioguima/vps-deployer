#!/usr/bin/env bash
set -Eeuo pipefail

if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
  echo "Run as root: sudo bash ./scripts/repair-coolify-localhost-ssh.sh" >&2
  exit 1
fi

KEY_DIR=/data/coolify/ssh/keys
AUTH_KEYS=/root/.ssh/authorized_keys
SSHD_CONFIG=/etc/ssh/sshd_config
STAMP="$(date +%Y%m%d-%H%M%S)"

command -v ssh-keygen >/dev/null || { echo "ERRO: ssh-keygen is required" >&2; exit 1; }
command -v sshd >/dev/null || { echo "ERRO: sshd is required" >&2; exit 1; }
[[ -d "$KEY_DIR" ]] || { echo "ERRO: $KEY_DIR not found" >&2; exit 1; }

# Coolify may only persist the private key file. Derive the corresponding public
# key instead of assuming a sibling *.pub file exists.
mapfile -t PRIVATE_KEYS < <(
  find "$KEY_DIR" -maxdepth 1 -type f ! -name '*.pub' -print | while IFS= read -r candidate; do
    if ssh-keygen -y -f "$candidate" >/dev/null 2>&1; then
      printf '%s\n' "$candidate"
    fi
  done
)

if (( ${#PRIVATE_KEYS[@]} == 0 )); then
  echo "ERRO: no usable Coolify private SSH key found in $KEY_DIR" >&2
  find "$KEY_DIR" -maxdepth 1 -type f -printf '  %f\n' >&2 || true
  exit 1
fi

if (( ${#PRIVATE_KEYS[@]} > 1 )); then
  echo "ERRO: more than one usable Coolify private SSH key found; refusing to authorize an ambiguous key" >&2
  printf '  %s\n' "${PRIVATE_KEYS[@]}" >&2
  exit 1
fi

PRIVATE_KEY="${PRIVATE_KEYS[0]}"
PUBLIC_KEY="$(ssh-keygen -y -f "$PRIVATE_KEY")"
COMMENT="coolify-localhost"
PUBLIC_LINE="$PUBLIC_KEY $COMMENT"

install -d -o root -g root -m 0700 /root/.ssh
touch "$AUTH_KEYS"
chown root:root "$AUTH_KEYS"
chmod 0600 "$AUTH_KEYS"

# Match by key material, regardless of an existing comment.
KEY_B64="$(awk '{print $2}' <<<"$PUBLIC_KEY")"
if ! awk -v key="$KEY_B64" '$2 == key {found=1} END {exit !found}' "$AUTH_KEYS"; then
  printf '%s\n' "$PUBLIC_LINE" >> "$AUTH_KEYS"
  echo "Authorized Coolify localhost public key derived from: $(basename "$PRIVATE_KEY")"
else
  echo "Coolify localhost public key is already authorized"
fi

cp -a "$SSHD_CONFIG" "${SSHD_CONFIG}.pre-coolify-${STAMP}"

# Permit root only by key; password authentication for root stays disabled.
if grep -qE '^[[:space:]#]*PermitRootLogin[[:space:]]+' "$SSHD_CONFIG"; then
  sed -i -E 's/^[[:space:]#]*PermitRootLogin[[:space:]]+.*/PermitRootLogin prohibit-password/' "$SSHD_CONFIG"
else
  printf '\nPermitRootLogin prohibit-password\n' >> "$SSHD_CONFIG"
fi

sshd -t
systemctl restart ssh

EFFECTIVE="$(sshd -T | awk '$1=="permitrootlogin" {print $2; exit}')"
echo "permitrootlogin=$EFFECTIVE"
[[ "$EFFECTIVE" == "without-password" || "$EFFECTIVE" == "prohibit-password" ]] || {
  echo "ERRO: unexpected effective PermitRootLogin=$EFFECTIVE" >&2
  exit 1
}

# Validate the same key from the host before asking the UI to retry.
ssh -i "$PRIVATE_KEY" \
  -o BatchMode=yes \
  -o StrictHostKeyChecking=no \
  -o UserKnownHostsFile=/dev/null \
  -o ConnectTimeout=5 \
  root@127.0.0.1 'true' >/dev/null

echo "COOLIFY_LOCALHOST_SSH_OK"
