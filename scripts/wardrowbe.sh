#!/usr/bin/env bash
set -Eeuo pipefail

APP="Wardrowbe"
VERSION="1.10.3"
TAG="wardrowbe-v${VERSION}"
CT_HOSTNAME="${CT_HOSTNAME:-wardrowbe}"
CORES="${CORES:-4}"
RAM="${RAM:-8192}"
SWAP="${SWAP:-2048}"
DISK="${DISK:-40}"
BRIDGE="${BRIDGE:-vmbr0}"

if [[ $EUID -ne 0 ]]; then
  echo "ERROR: Run this as root on the Proxmox host."
  exit 1
fi

for cmd in pct pveam pvesm pvesh openssl; do
  command -v "$cmd" >/dev/null 2>&1 || {
    echo "ERROR: '$cmd' is missing. Run this on the Proxmox VE host."
    exit 1
  }
done

if [[ ! -d "/sys/class/net/${BRIDGE}" ]]; then
  echo "ERROR: Network bridge '${BRIDGE}' does not exist on this host."
  echo "Available Linux bridges:"
  for netdev in /sys/class/net/*; do
    if [[ -d "${netdev}/bridge" ]]; then
      echo "  ${netdev##*/}"
    fi
  done
  echo "Run with a different bridge, for example: BRIDGE=vmbr1 bash -c \"\$(curl -fsSL URL)\""
  exit 1
fi

CTID="$(pvesh get /cluster/nextid)"
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

echo "Creating ${APP} in LXC ${CTID}..."

TEMPLATE_STORAGE="${TEMPLATE_STORAGE:-$(pvesm status -content vztmpl | awk 'NR>1 && $3=="active" {print $1; exit}')}"

if [[ -z "$TEMPLATE_STORAGE" ]]; then
  echo "ERROR: No active storage with vztmpl content support was found."
  exit 1
fi

CONTAINER_STORAGE="${CONTAINER_STORAGE:-$(pvesm status -content rootdir | awk 'NR>1 && $3=="active" && $1=="local-lvm" {print $1; exit}')}"

if [[ -z "$CONTAINER_STORAGE" ]]; then
  CONTAINER_STORAGE="$(pvesm status -content rootdir | awk 'NR>1 && $3=="active" {print $1; exit}')"
fi

if [[ -z "$CONTAINER_STORAGE" ]]; then
  echo "ERROR: No active storage with rootdir content support was found."
  exit 1
fi

pveam update >/dev/null

ARCH="$(dpkg --print-architecture)"

case "$ARCH" in
  amd64|arm64) ;;
  *)
    echo "ERROR: Unsupported Proxmox host architecture: ${ARCH}"
    exit 1
    ;;
esac

TEMPLATE="$(pveam available --section system \
  | awk -v arch="$ARCH" \
      'index($2, "debian-13-standard") && index($2, "_" arch ".tar") {print $2}' \
  | sort -V \
  | tail -n1)"

if [[ -z "$TEMPLATE" ]]; then
  echo "ERROR: No Debian 13 ${ARCH} LXC template was found."
  exit 1
fi

case "$TEMPLATE" in
  *_"${ARCH}".tar.*) ;;
  *)
    echo "ERROR: Template architecture does not match host architecture."
    echo "Host architecture: ${ARCH}"
    echo "Selected template: ${TEMPLATE}"
    exit 1
    ;;
esac

echo "Host architecture: ${ARCH}"
echo "Selected template: ${TEMPLATE}"

if ! pveam list "$TEMPLATE_STORAGE" 2>/dev/null | grep -Fq "$TEMPLATE"; then
  echo "Downloading ${TEMPLATE}..."
  pveam download "$TEMPLATE_STORAGE" "$TEMPLATE"
fi

echo "Creating LXC..."

pct create "$CTID" "${TEMPLATE_STORAGE}:vztmpl/${TEMPLATE}" \
  --hostname "$CT_HOSTNAME" \
  --arch "$ARCH" \
  --cores "$CORES" \
  --memory "$RAM" \
  --swap "$SWAP" \
  --rootfs "${CONTAINER_STORAGE}:${DISK}" \
  --net0 "name=eth0,bridge=${BRIDGE},ip=dhcp,type=veth" \
  --ostype debian \
  --unprivileged 0 \
  --features nesting=1 \
  --onboot 1

if ! pct start "$CTID"; then
  echo
  echo "ERROR: LXC ${CTID} failed to start. Detailed diagnostics follow:"
  echo
  pct start "$CTID" --debug || true
  echo
  echo "The failed container was kept for diagnosis. Remove it with:"
  echo "  pct destroy ${CTID} --purge"
  exit 1
fi

echo "Waiting for network..."

for _ in {1..60}; do
  if pct exec "$CTID" -- bash -lc \
    'ip -4 -o addr show dev eth0 | grep -q "inet "' \
    >/dev/null 2>&1; then
    break
  fi

  sleep 2
done

IP="$(pct exec "$CTID" -- ip -4 -o addr show dev eth0 \
  | awk '{print $4}' \
  | cut -d/ -f1 \
  | head -n1 \
  | tr -d '\r')"

if [[ -z "$IP" ]]; then
  echo "ERROR: The container did not receive an IPv4 address."
  exit 1
fi

echo "Container IP: ${IP}"
echo "Installing Docker..."

pct exec "$CTID" -- bash -lc '
set -Eeuo pipefail

export DEBIAN_FRONTEND=noninteractive

if [[ "$(stat -c "%U" /)" != "root" ]]; then
  chown root:root / 2>/dev/null || true
fi

for i in {1..10}; do
  if apt-get update; then
    break
  fi

  if [[ "$i" == "10" ]]; then
    echo "ERROR: apt update failed."
    exit 1
  fi

  sleep 5
done

apt-get install -y \
  ca-certificates \
  curl \
  git \
  openssl

install -m 0755 -d /etc/apt/keyrings

curl -fsSL https://download.docker.com/linux/debian/gpg \
  -o /etc/apt/keyrings/docker.asc

chmod a+r /etc/apt/keyrings/docker.asc

. /etc/os-release

cat >/etc/apt/sources.list.d/docker.sources <<DOCKER_REPO
Types: deb
URIs: https://download.docker.com/linux/debian
Suites: ${VERSION_CODENAME}
Components: stable
Signed-By: /etc/apt/keyrings/docker.asc
DOCKER_REPO

apt-get update

apt-get install -y \
  docker-ce \
  docker-ce-cli \
  containerd.io \
  docker-buildx-plugin \
  docker-compose-plugin

systemctl enable --now docker

docker version >/dev/null
docker compose version >/dev/null

echo "Docker installed successfully."
'

echo "Installing Wardrowbe ${VERSION}..."

pct exec "$CTID" -- bash -lc \
  "rm -rf /opt/wardrowbe && \
   git clone \
   --branch '${TAG}' \
   --depth 1 \
   https://github.com/Anyesh/wardrowbe.git \
   /opt/wardrowbe"

pct exec "$CTID" -- bash -lc "
set -Eeuo pipefail

cd /opt/wardrowbe

sed -i \
  's|ghcr.io/anyesh/wardrowbe:backend-latest|ghcr.io/anyesh/wardrowbe:backend-${VERSION}|g' \
  docker-compose.yml

sed -i \
  's|ghcr.io/anyesh/wardrowbe:frontend-latest|ghcr.io/anyesh/wardrowbe:frontend-${VERSION}|g' \
  docker-compose.yml
"

POSTGRES_PASSWORD="$(openssl rand -hex 32)"
SECRET_KEY="$(openssl rand -hex 32)"
NEXTAUTH_SECRET="$(openssl rand -hex 32)"

cat >"${TMPDIR}/wardrowbe.env" <<ENVFILE
POSTGRES_USER=wardrobe
POSTGRES_PASSWORD=${POSTGRES_PASSWORD}
POSTGRES_DB=wardrobe

POSTGRES_PORT=127.0.0.1:5432
REDIS_PORT=127.0.0.1:6379
BACKEND_PORT=127.0.0.1:8000
FRONTEND_PORT=3000

SECRET_KEY=${SECRET_KEY}

DEBUG=true

BACKEND_URL=http://backend:8000

NEXTAUTH_URL=http://${IP}:3000
NEXTAUTH_SECRET=${NEXTAUTH_SECRET}

AI_INTERNAL_ENABLED=true
AI_VISION_ENABLED=true
AI_TEXT_ENABLED=true

AI_BASE_URL=http://ollama:11434/v1
AI_API_KEY=not-needed

AI_VISION_MODEL=gemma3:4b
AI_TEXT_MODEL=gemma3:4b

AI_TIMEOUT=600
AI_MAX_RETRIES=2
AI_TAGGING_CONCURRENCY=1
AI_REASONING_EFFORT=none

IMAGE_WORKER_CONCURRENCY=1

BG_REMOVAL_PROVIDER=rembg
BG_REMOVAL_MODEL=u2net

MAX_IMAGE_MEGAPIXELS=50

LOG_LEVEL=INFO
ENVFILE

cat >"${TMPDIR}/docker-compose.ollama.yml" <<'COMPOSEFILE'
services:

  backend:
    environment:
      AI_API_KEY: ${AI_API_KEY:-}

  worker:
    environment:
      AI_API_KEY: ${AI_API_KEY:-}

  ollama:
    image: ollama/ollama:latest
    container_name: wardrobe-ollama
    restart: unless-stopped
    volumes:
      - ollama_data:/root/.ollama

volumes:
  ollama_data:
COMPOSEFILE

pct push \
  "$CTID" \
  "${TMPDIR}/wardrowbe.env" \
  /opt/wardrowbe/.env

pct push \
  "$CTID" \
  "${TMPDIR}/docker-compose.ollama.yml" \
  /opt/wardrowbe/docker-compose.ollama.yml

pct exec "$CTID" -- chmod 600 /opt/wardrowbe/.env

echo "Pulling Wardrowbe, PostgreSQL, Redis and Ollama images..."

pct exec "$CTID" -- bash -lc '
set -Eeuo pipefail

cd /opt/wardrowbe

DC="docker compose -f docker-compose.yml -f docker-compose.ollama.yml"

$DC pull

echo "Starting database, Redis and Ollama..."

$DC up -d postgres redis ollama

echo "Waiting for Ollama..."

for i in {1..60}; do

  if $DC exec -T ollama ollama list >/dev/null 2>&1; then
    break
  fi

  if [[ "$i" == "60" ]]; then
    echo "ERROR: Ollama did not become ready."
    exit 1
  fi

  sleep 2
done

echo "Downloading Gemma 3 4B..."

$DC exec -T ollama ollama pull gemma3:4b

echo "Running database migrations..."

$DC run --rm backend alembic upgrade head

echo "Starting Wardrowbe..."

$DC up -d
'

echo "Verifying Wardrowbe..."

if ! pct exec "$CTID" -- bash -lc '
set -Eeuo pipefail

for i in {1..90}; do

  BACKEND_OK=0
  FRONTEND_OK=0

  curl -fsS \
    http://127.0.0.1:8000/api/v1/health \
    >/dev/null 2>&1 \
    && BACKEND_OK=1 \
    || true

  curl -fsS \
    http://127.0.0.1:3000 \
    >/dev/null 2>&1 \
    && FRONTEND_OK=1 \
    || true

  if [[ "$BACKEND_OK" == "1" && "$FRONTEND_OK" == "1" ]]; then
    exit 0
  fi

  sleep 4
done

exit 1
'; then

  echo
  echo "ERROR: Wardrowbe did not become healthy."
  echo "Recent logs:"
  echo

  pct exec "$CTID" -- bash -lc '
  cd /opt/wardrowbe

  docker compose \
    -f docker-compose.yml \
    -f docker-compose.ollama.yml \
    ps

  docker compose \
    -f docker-compose.yml \
    -f docker-compose.ollama.yml \
    logs \
    --tail=100 \
    backend frontend worker ollama
  '

  exit 1
fi

echo
echo "============================================================"
echo " Wardrowbe ${VERSION} installed successfully"
echo "============================================================"
echo
echo "Container ID: ${CTID}"
echo "IP address:   ${IP}"
echo "Web UI:       http://${IP}:3000"
echo
echo "AI model:     Gemma 3 4B"
echo "AI backend:   Local Ollama"
echo "Database:     PostgreSQL 15"
echo "Queue:        Redis 7"
echo "Install path: /opt/wardrowbe"
echo
echo "Open:"
echo
echo "http://${IP}:3000"
echo
echo "Click Login to enter Wardrowbe."
echo
