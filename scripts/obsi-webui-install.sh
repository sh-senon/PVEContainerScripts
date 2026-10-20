#!/usr/bin/env bash
# Install Open WebUI natively in a new Proxmox LXC (no Docker).
# Intended for pve03; creates CT 134 only after an explicit confirmation.
set -Eeuo pipefail

CTID=134
CTNAME=obsi-webui
NODE=pve03
BRIDGE=vmbr0
CORES=2
RAM=2048
SWAP=512
DISK_GB=24
STORAGE=""
TEMPLATE=""
DRY_RUN=0
CREATED=0
SERVICE_UNIT=""

usage() {
  printf 'Usage: %s [--storage STORAGE] [--template STORAGE:vztmpl/FILE] [--dry-run]\n' "$0"
}
die() { printf '[obsi-webui ERROR] %s\n' "$*" >&2; exit 1; }
log() { printf '\n[obsi-webui] %s\n' "$*"; }
on_error() {
  rc=$?
  printf '\n[obsi-webui ERROR] Stopped at line %s (exit %s).\n' "$1" "$rc" >&2
  if (( CREATED )); then
    printf 'CT %s was created and is NOT removed automatically. Inspect before retrying.\n' "$CTID" >&2
  fi
  exit "$rc"
}
cleanup() {
  if [[ -n "$SERVICE_UNIT" && -f "$SERVICE_UNIT" ]]; then
    rm -- "$SERVICE_UNIT"
  fi
}
trap cleanup EXIT
trap 'on_error "$LINENO"' ERR

while (($#)); do
  case "$1" in
    --storage) [[ $# -ge 2 ]] || die '--storage requires a value'; STORAGE="$2"; shift 2 ;;
    --template) [[ $# -ge 2 ]] || die '--template requires a value'; TEMPLATE="$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage; die "Unknown argument: $1" ;;
  esac
done

[[ $EUID -eq 0 ]] || die 'Run this on pve03 as root.'
[[ "$(hostname -s)" == "$NODE" ]] || die "Expected $NODE; got $(hostname -s)."
[[ -d /etc/pve/lxc ]] || die 'This is not a Proxmox VE host.'
for cmd in pct pvesm pveam flock awk grep hostname; do
  command -v "$cmd" >/dev/null || die "Missing dependency: $cmd"
done
[[ -d "/sys/class/net/$BRIDGE" ]] || die "Missing bridge: $BRIDGE"

exec 9>/run/lock/obsi-webui-installer.lock
flock -n 9 || die 'Another Obsi WebUI installation is running.'
if pct config "$CTID" >/dev/null 2>&1 || [[ -e "/etc/pve/lxc/$CTID.conf" ]]; then
  die "CT $CTID already exists. Nothing will be overwritten."
fi

log 'Checking active Proxmox root-disk storage'
pvesm status --content rootdir
if [[ -z "$STORAGE" ]]; then
  [[ -t 0 ]] || die 'Provide --storage for non-interactive execution.'
  read -r -p 'Root disk storage ID (e.g. local-lvm): ' STORAGE
fi
[[ "$STORAGE" =~ ^[a-zA-Z0-9_.-]+$ ]] || die 'Invalid storage ID.'
pvesm status --storage "$STORAGE" --content rootdir | awk 'NR>1 && $3=="active"{ok=1} END{exit !ok}' \
  || die "Storage $STORAGE is not active and rootdir-capable."

log 'Checking Debian 12 amd64 template (Python 3.11)'
if [[ -z "$TEMPLATE" ]]; then
  pveam list local 2>/dev/null | grep 'debian-12-standard' || true
  [[ -t 0 ]] || die 'Provide --template for non-interactive execution.'
  read -r -p 'Debian 12 amd64 template volume ID: ' TEMPLATE
fi
[[ "$TEMPLATE" =~ ^[a-zA-Z0-9_.-]+:vztmpl/debian-12-standard_[a-zA-Z0-9._-]+_amd64\.tar\.(zst|gz|xz)$ ]] \
  || die 'Template must be a Debian 12 standard amd64 archive.'
pvesm path "$TEMPLATE" >/dev/null || die "Template not found: $TEMPLATE"

log 'Review planned changes'
printf 'Node: %s | NEW LXC: %s (%s) | Debian 12 amd64 | unprivileged\n' "$NODE" "$CTID" "$CTNAME"
printf 'Resources: %s cores, %s MiB RAM, %s MiB swap, %s GiB disk\n' "$CORES" "$RAM" "$SWAP" "$DISK_GB"
printf 'Storage: %s | Template: %s | Network: %s DHCP\n' "$STORAGE" "$TEMPLATE" "$BRIDGE"
printf 'Open WebUI: port 8080 on the CT LAN IP, authenticated web interface.\n'
printf 'No TrueNAS mount, Docker, API keys, or public internet exposure will be configured.\n'
printf 'IMPORTANT: First person to register through the WebUI becomes administrator.\n'
if (( DRY_RUN )); then
  log 'Dry run complete; no changes made.'
  exit 0
fi

[[ -t 0 ]] || die 'Interactive confirmation required.'
read -r -p 'Install packages and create NEW CT 134? Type CREATE: ' CONFIRM
[[ "$CONFIRM" == CREATE ]] || die 'Cancelled.'

# Recheck for an existing CT immediately before mutation.
if pct config "$CTID" >/dev/null 2>&1 || [[ -e "/etc/pve/lxc/$CTID.conf" ]]; then
  die 'CT 134 appeared during preflight. Stopping.'
fi

log 'Creating unprivileged LXC 134'
pct create "$CTID" "$TEMPLATE" \
  --hostname "$CTNAME" --unprivileged 1 --features nesting=0 \
  --cores "$CORES" --memory "$RAM" --swap "$SWAP" \
  --rootfs "$STORAGE:$DISK_GB" \
  --net0 "name=eth0,bridge=$BRIDGE,ip=dhcp,type=veth" \
  --onboot 1 --start 0
CREATED=1
pct start "$CTID"

log 'Installing Debian dependencies and creating Python virtual environment'
pct exec "$CTID" -- bash -ec 'apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y python3 python3-venv python3-pip ca-certificates curl openssl'
pct exec "$CTID" -- python3 -c 'import sys; assert sys.version_info[:2] == (3, 11), sys.version'
pct exec "$CTID" -- python3 -m venv /opt/obsi-webui-venv

log 'Installing CPU-only PyTorch first, avoiding large NVIDIA/CUDA dependencies'
pct exec "$CTID" -- /opt/obsi-webui-venv/bin/python -m pip install --disable-pip-version-check --index-url https://download.pytorch.org/whl/cpu torch

log 'Installing Open WebUI (may take several minutes)'
pct exec "$CTID" -- /opt/obsi-webui-venv/bin/python -m pip install --disable-pip-version-check open-webui

log 'Creating a restricted systemd service and persistent application directory'
pct exec "$CTID" -- bash -ec 'id obsiwebui >/dev/null 2>&1 || useradd --system --home-dir /var/lib/obsi-webui --shell /usr/sbin/nologin obsiwebui'
pct exec "$CTID" -- install -d -o obsiwebui -g obsiwebui -m 0750 /var/lib/obsi-webui

# Generate and store the session signing secret in the CT, never on the host command line.
pct exec "$CTID" -- bash -ec 'umask 077; test -e /etc/obsi-webui.env || { printf "WEBUI_SECRET_KEY=%s\n" "$(openssl rand -hex 32)" > /etc/obsi-webui.env; printf "DATA_DIR=/var/lib/obsi-webui\nWEBUI_AUTH=true\nUVICORN_WORKERS=1\nENABLE_COMMUNITY_SHARING=false\n" >> /etc/obsi-webui.env; }; chmod 600 /etc/obsi-webui.env'

SERVICE_UNIT="$(mktemp /tmp/obsi-webui-unit.XXXXXX)"
chmod 0644 "$SERVICE_UNIT"
printf '%s\n' '[Unit]' > "$SERVICE_UNIT"
cat >> "$SERVICE_UNIT" <<'UNIT'
Description=Obsi Open WebUI
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
User=obsiwebui
Group=obsiwebui
WorkingDirectory=/var/lib/obsi-webui
EnvironmentFile=/etc/obsi-webui.env
ExecStart=/opt/obsi-webui-venv/bin/open-webui serve --host 0.0.0.0 --port 8080
Restart=on-failure
RestartSec=10
NoNewPrivileges=true
ProtectHome=true
ProtectSystem=strict
PrivateTmp=true
ReadWritePaths=/var/lib/obsi-webui
UMask=0077

[Install]
WantedBy=multi-user.target
UNIT
pct push "$CTID" "$SERVICE_UNIT" /etc/systemd/system/obsi-webui.service

pct exec "$CTID" -- systemctl daemon-reload
pct exec "$CTID" -- systemctl enable --now obsi-webui.service

log 'Waiting for first startup and checking the service'
for attempt in $(seq 1 30); do
  if pct exec "$CTID" -- curl -fsS --max-time 5 http://127.0.0.1:8080/ >/dev/null 2>&1; then
    break
  fi
  if ! pct exec "$CTID" -- systemctl is-active --quiet obsi-webui.service; then
    die 'Open WebUI service stopped; inspect journalctl -u obsi-webui.'
  fi
  sleep 4
done
pct exec "$CTID" -- curl -fsS --max-time 10 http://127.0.0.1:8080/ >/dev/null \
  || die 'Service started but HTTP was not ready; inspect logs before retrying.'

log 'Installation complete'
pct exec "$CTID" -- hostname -I || true
printf '\nOpen http://<CT-134-DHCP-IP>:8080 from a trusted LAN or VPN.\n'
printf 'IMMEDIATELY create the first admin account; first registrant becomes administrator.\n'
printf 'Then confirm Settings > Admin > Authentication > Sign Ups is OFF.\n'
printf 'Next: add Qwen 3.8 Flash and set up an authenticated link to CT 133 MCP.\n'
printf 'Logs: pct exec %s -- journalctl -u obsi-webui -n 100 --no-pager\n' "$CTID"
