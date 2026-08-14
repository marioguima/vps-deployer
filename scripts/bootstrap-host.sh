#!/usr/bin/env bash
set -Eeuo pipefail

if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
  echo "Run as root: sudo ./scripts/bootstrap-host.sh" >&2
  exit 1
fi

export DEBIAN_FRONTEND=noninteractive

have_docker() {
  command -v docker >/dev/null 2>&1 \
    && docker --version >/dev/null 2>&1 \
    && docker compose version >/dev/null 2>&1
}

if have_docker; then
  echo "OK: Docker Engine and Docker Compose are already installed"
  docker --version
  docker compose version
  systemctl enable --now docker >/dev/null 2>&1 || true
  exit 0
fi

echo "Docker Engine/Compose not found; installing from Docker's official Ubuntu APT repository..."

if [[ ! -r /etc/os-release ]]; then
  echo "/etc/os-release not found; unsupported host" >&2
  exit 1
fi

. /etc/os-release
if [[ "${ID:-}" != "ubuntu" ]]; then
  echo "Automatic Docker bootstrap currently supports Ubuntu only (detected: ${ID:-unknown})" >&2
  exit 1
fi

apt-get update
apt-get install -y ca-certificates curl

# Do not silently remove container runtimes that may belong to another workload.
# Abort on known conflicting distribution packages instead of making a destructive
# decision automatically on a non-empty VPS.
conflicts=()
for pkg in docker.io docker-compose docker-compose-v2 docker-doc docker-buildx podman-docker containerd runc; do
  if dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q '^install ok installed$'; then
    conflicts+=("$pkg")
  fi
done
if ((${#conflicts[@]})); then
  echo "Conflicting Docker/container packages detected: ${conflicts[*]}" >&2
  echo "Bootstrap stopped instead of removing existing runtime packages automatically." >&2
  exit 1
fi

install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc

cat >/etc/apt/sources.list.d/docker.sources <<EOF
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: ${UBUNTU_CODENAME:-$VERSION_CODENAME}
Components: stable
Architectures: $(dpkg --print-architecture)
Signed-By: /etc/apt/keyrings/docker.asc
EOF

apt-get update
apt-get install -y \
  docker-ce \
  docker-ce-cli \
  containerd.io \
  docker-buildx-plugin \
  docker-compose-plugin

systemctl enable --now docker

have_docker || {
  echo "Docker installation finished but validation failed" >&2
  exit 1
}

echo "OK: Docker Engine and Docker Compose installed"
docker --version
docker compose version
