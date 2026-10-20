#!/usr/bin/env bash
# Obsi Knowledge Base installer for Proxmox VE (run on pve03 as root).
# This script DOES NOT install Open WebUI or make MCP reachable on the LAN.
set -Eeuo pipefail

CTID=133
HOSTNAME=obsi-kb
NODE=pve03
NAS_IP=10.69.69.4
NFS_EXPORT=/mnt/Pool-2/obsi-ai
HOST_MOUNT=/mnt/obsi-ai
CT_MOUNT=/srv/obsi-ai
BRIDGE=vmbr0
RAM=1024
SWAP=512
CORES=1
DISK_GB=8
STORAGE=""
TEMPLATE=""
DRY_RUN=0
CT_CREATED=0
TEMP_MOUNT=""
WORKDIR=""

usage() {
  printf 'Usage: %s [--storage STORAGE] [--template STORAGE:vztmpl/FILE] [--dry-run]\n' "$0"
  printf 'Run on pve03 as root. Without --storage / --template you will be prompted.\n'
}

while (($#)); do
  case "$1" in
    --storage) STORAGE="${2:?Missing storage}"; shift 2 ;;
    --template) TEMPLATE="${2:?Missing template}"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'Unknown option: %s\n' "$1" >&2; usage; exit 2 ;;
  esac
done

log() { printf '\n[obsi] %s\n' "$*"; }
die() { printf '\n[obsi ERROR] %s\n' "$*" >&2; exit 1; }

cleanup() {
  if [[ -n "$TEMP_MOUNT" ]] && mountpoint -q "$TEMP_MOUNT"; then
    umount "$TEMP_MOUNT" || printf 'WARNING: temporary NFS mount remains: %s\n' "$TEMP_MOUNT" >&2
  fi
  if [[ -n "$WORKDIR" && -d "$WORKDIR" ]]; then
    # Only removes this run's small temporary source directory.
    rm -r -- "$WORKDIR"
  fi
  if [[ -n "$TEMP_MOUNT" && -d "$TEMP_MOUNT" ]]; then rmdir -- "$TEMP_MOUNT" || true; fi
}
trap cleanup EXIT
on_error() {
  status=$?
  printf '\n[obsi ERROR] Installer stopped at line %s (exit %s).\n' "$1" "$status" >&2
  if ((CT_CREATED)); then
    printf '[obsi] CT %s may be partially configured. It was NOT deleted. Inspect it before retrying.\n' "$CTID" >&2
  fi
  exit "$status"
}
trap 'on_error "$LINENO"' ERR

[[ $EUID -eq 0 ]] || die 'Run as root on the Proxmox host.'
[[ "$(hostname -s)" == "$NODE" ]] || die "Expected node $NODE, got $(hostname -s)."
for cmd in pct pveam pvesm findmnt mountpoint mount awk sed grep flock sha256sum; do
  command -v "$cmd" >/dev/null || die "Missing command: $cmd"
done
[[ -d /etc/pve/lxc ]] || die 'Not a Proxmox VE host.'
[[ -d /sys/class/net/$BRIDGE ]] || die "Network bridge $BRIDGE missing."
if pct config "$CTID" >/dev/null 2>&1 || [[ -e "/etc/pve/lxc/$CTID.conf" ]]; then
  die "CT $CTID already exists. This installer will never overwrite it."
fi

exec 9>/run/lock/obsi-kb-installer.lock
flock -n 9 || die 'Another Obsi installer run is active.'

log 'Checking available rootdir storage'
pvesm status --content rootdir
if [[ -z "$STORAGE" ]]; then
  [[ -t 0 ]] || die 'Non-interactive run requires --storage.'
  read -r -p 'Root disk storage ID (e.g. local-lvm): ' STORAGE
fi
[[ "$STORAGE" =~ ^[a-zA-Z0-9_.-]+$ ]] || die 'Invalid storage name.'
pvesm status --storage "$STORAGE" --content rootdir | awk 'NR>1 && $3=="active"{ok=1} END{exit !ok}' \
  || die "Storage $STORAGE is not active / rootdir-capable."

log 'Checking Debian 13 template'
if [[ -z "$TEMPLATE" ]]; then
  pveam list local 2>/dev/null | grep 'debian-13-standard' || true
  [[ -t 0 ]] || die 'Non-interactive run requires --template.'
  read -r -p 'Debian 13 template volume ID (e.g. local:vztmpl/debian-13-standard_...tar.zst): ' TEMPLATE
fi
[[ "$TEMPLATE" == *debian-13-standard* ]] || die 'Template must be Debian 13 standard.'
pvesm path "$TEMPLATE" >/dev/null || die "Template not found: $TEMPLATE"

log 'Review planned changes'
printf 'Node: %s | CT: %s (%s) | Debian 13 | unprivileged\n' "$NODE" "$CTID" "$HOSTNAME"
printf 'Resources: %s core / %s MiB RAM / %s MiB swap / %s GiB\n' "$CORES" "$RAM" "$SWAP" "$DISK_GB"
printf 'Template: %s | root storage: %s | bridge: %s | DHCP\n' "$TEMPLATE" "$STORAGE" "$BRIDGE"
printf 'TrueNAS: %s:%s -> host %s -> CT %s\n' "$NAS_IP" "$NFS_EXPORT" "$HOST_MOUNT" "$CT_MOUNT"
printf 'MCP will be read-only and listen on 127.0.0.1:8766 INSIDE CT ONLY.\n'
if ((DRY_RUN)); then
  log 'Dry-run complete. No package installations, mounts or CT changes performed.'
  exit 0
fi
[[ -t 0 ]] || die 'Interactive approval required; run in a terminal.'
read -r -p 'Proceed with host packages, NFS mount and NEW CT creation? Type CREATE: ' CONFIRM
[[ "$CONFIRM" == CREATE ]] || die 'Cancelled.'

log 'Installing host-side NFS client'
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y nfs-common

log 'Testing TrueNAS NFS export before changing permanent configuration'
WORKDIR="$(mktemp -d /tmp/obsi-installer.XXXXXX)"
TEMP_MOUNT="$(mktemp -d /mnt/obsi-preflight.XXXXXX)"
mount -t nfs -o rw,nosuid,nodev "$NAS_IP:$NFS_EXPORT" "$TEMP_MOUNT" \
  || die 'NFS mount failed. Verify NAS export/host allow-list.'
findmnt -rn --mountpoint "$TEMP_MOUNT" -t nfs,nfs4 >/dev/null || die 'NFS type validation failed.'

# Verify the server-side Mapall identity, not just the ability to mount.
CHECKFILE="$TEMP_MOUNT/.obsi-preflight-$(date +%s)-$$"
(umask 077; printf 'obsi preflight\n' > "$CHECKFILE") || die 'TrueNAS export is not writable.'
read -r OWNER_ID GROUP_ID < <(stat -c '%u %g' "$CHECKFILE")
if [[ "$OWNER_ID" != 3004 || "$GROUP_ID" != 3007 ]]; then
  die "Unexpected NFS write ownership $OWNER_ID:$GROUP_ID (expected 3004:3007). Preflight file left for inspection: $CHECKFILE"
fi
rm -- "$CHECKFILE"
umount "$TEMP_MOUNT"
rmdir "$TEMP_MOUNT"
TEMP_MOUNT=""

if findmnt -rn --mountpoint "$HOST_MOUNT" >/dev/null 2>&1; then
  [[ "$(findmnt -rn -o SOURCE --mountpoint "$HOST_MOUNT")" == "$NAS_IP:$NFS_EXPORT" ]] \
    || die "$HOST_MOUNT is already mounted from a different source."
else
  mkdir -p "$HOST_MOUNT"
  [[ -z "$(find "$HOST_MOUNT" -mindepth 1 -maxdepth 1 -print -quit)" ]] \
    || die "$HOST_MOUNT is nonempty without a mount; refusing to hide its files."
  mount -t nfs -o rw,nosuid,nodev "$NAS_IP:$NFS_EXPORT" "$HOST_MOUNT"
fi

# Persistent mount: explicit mount (not automount) and no fallback to local files.
FSTAB_LINE="$NAS_IP:$NFS_EXPORT $HOST_MOUNT nfs rw,_netdev,nofail,nosuid,nodev,x-systemd.requires=network-online.target 0 0"
if ! grep -Fq "$NAS_IP:$NFS_EXPORT $HOST_MOUNT " /etc/fstab; then
  cp -a /etc/fstab "/etc/fstab.obsi-backup-$(date +%Y%m%d%H%M%S)"
  printf '%s\n' "$FSTAB_LINE" >> /etc/fstab
  systemctl daemon-reload
fi

log 'Creating LXC (the existing-ID check is repeated)'
if pct config "$CTID" >/dev/null 2>&1; then die "CT $CTID appeared during preflight; stopping."; fi
pct create "$CTID" "$TEMPLATE" \
  --hostname "$HOSTNAME" --unprivileged 1 --features nesting=0 \
  --cores "$CORES" --memory "$RAM" --swap "$SWAP" \
  --rootfs "$STORAGE:$DISK_GB" \
  --net0 "name=eth0,bridge=$BRIDGE,ip=dhcp,type=veth" \
  --onboot 1 --start 0
CT_CREATED=1

# Bind mount only after NFS source validation.
findmnt -rn --mountpoint "$HOST_MOUNT" -t nfs,nfs4 >/dev/null || die 'NFS disappeared after CT creation.'
pct set "$CTID" -mp0 "$HOST_MOUNT,mp=$CT_MOUNT"
pct start "$CTID"

log 'Installing Python runtime in LXC'
pct exec "$CTID" -- bash -ec 'apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y python3 python3-venv python3-pip curl'
pct exec "$CTID" -- bash -ec 'python3 -m venv /opt/obsi-mcp-venv && /opt/obsi-mcp-venv/bin/python -m pip install --disable-pip-version-check "mcp>=2.0,<3.0"'

log 'Writing a restricted read-only MCP tool server'
mkdir -p "$WORKDIR/ct"
cat > "$WORKDIR/ct/server.py" <<'PY'
#!/usr/bin/env python3
"""Obsi KB: read-only MCP service. No mutation tools are registered."""
from __future__ import annotations

import os
from pathlib import Path
from mcp.server.mcpserver import MCPServer

ROOT = Path('/srv/obsi-ai').resolve(strict=True)
MARKER = ROOT / '.obsi-storage-check'
if not MARKER.is_file():
    raise RuntimeError('TrueNAS marker is missing; refusing local-storage fallback')

server = MCPServer('obsi-kb')

def resolve(relative_path: str) -> Path:
    if relative_path.startswith('/'):
        raise ValueError('Use vault-relative paths')
    candidate = (ROOT / relative_path).resolve(strict=True)
    if not candidate.is_relative_to(ROOT):
        raise ValueError('Access outside the Obsidian vault denied')
    if '.obsidian' in candidate.relative_to(ROOT).parts:
        raise ValueError('Obsidian application settings are not exposed')
    return candidate

@server.tool()
def list_notes(directory: str = '.') -> list[str]:
    """List Markdown notes and directories inside the vault."""
    target = resolve(directory)
    if not target.is_dir():
        raise ValueError('Not a directory')
    return sorted(p.name + ('/' if p.is_dir() else '') for p in target.iterdir()
                  if p.name != '.obsidian' and (p.is_dir() or p.suffix.lower() == '.md'))[:1000]

@server.tool()
def read_note(path: str) -> str:
    """Read a Markdown note by its vault-relative path (limit: 256 KiB)."""
    target = resolve(path)
    if not target.is_file() or target.suffix.lower() != '.md':
        raise ValueError('Only Markdown files can be read')
    if target.stat().st_size > 262144:
        raise ValueError('Note too large')
    return target.read_text(encoding='utf-8')

@server.tool()
def search_notes(term: str) -> list[str]:
    """Find up to 50 Markdown notes containing a case-insensitive literal term."""
    term = term.strip().casefold()
    if not 2 <= len(term) <= 120:
        raise ValueError('Search term must be 2-120 characters')
    hits: list[str] = []
    for dirpath, dirs, files in os.walk(ROOT, followlinks=False):
        dirs[:] = [d for d in dirs if not d.startswith('.')]
        for name in files:
            if not name.lower().endswith('.md'):
                continue
            rel = str((Path(dirpath) / name).relative_to(ROOT))
            try:
                p = resolve(rel)
                if p.stat().st_size <= 262144 and term in p.read_text(encoding='utf-8').casefold():
                    hits.append(rel)
            except (OSError, UnicodeError, ValueError):
                continue
            if len(hits) >= 50:
                return hits
    return hits

if __name__ == '__main__':
    # No externally reachable listener until the Open WebUI IP and auth are configured.
    server.run(transport='streamable-http', host='127.0.0.1', port=8766,
               stateless_http=True, json_response=True)
PY

cat > "$WORKDIR/ct/obsi-mcp.service" <<'UNIT'
[Unit]
Description=Obsi read-only knowledge base MCP
After=network-online.target
Wants=network-online.target
ConditionPathIsMountPoint=/srv/obsi-ai

[Service]
Type=simple
ExecStartPre=/usr/bin/test -f /srv/obsi-ai/.obsi-storage-check
ExecStart=/opt/obsi-mcp-venv/bin/python /opt/obsi-mcp/server.py
WorkingDirectory=/opt/obsi-mcp
User=root
Group=root
Restart=on-failure
RestartSec=5
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
ReadOnlyPaths=/srv/obsi-ai
RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6

[Install]
WantedBy=multi-user.target
UNIT

# This marker is created only on the already-validated TrueNAS mount.
findmnt -rn --mountpoint "$HOST_MOUNT" -t nfs,nfs4 >/dev/null || die 'NFS disappeared before marker creation.'
[[ -e "$HOST_MOUNT/.obsi-storage-check" ]] || (umask 044; printf 'TrueNAS-backed Obsi storage\n' > "$HOST_MOUNT/.obsi-storage-check")
pct exec "$CTID" -- mkdir -p /opt/obsi-mcp
pct push "$CTID" "$WORKDIR/ct/server.py" /opt/obsi-mcp/server.py
pct push "$CTID" "$WORKDIR/ct/obsi-mcp.service" /etc/systemd/system/obsi-mcp.service
pct exec "$CTID" -- systemctl daemon-reload
pct exec "$CTID" -- systemctl enable --now obsi-mcp.service

log 'Verifying service and mount inside CT'
pct exec "$CTID" -- mountpoint -q "$CT_MOUNT" || die 'LXC bind mount missing.'
pct exec "$CTID" -- test -f "$CT_MOUNT/.obsi-storage-check" || die 'NFS marker missing inside CT.'
pct exec "$CTID" -- systemctl is-active --quiet obsi-mcp.service || die 'MCP service did not start; inspect journalctl.'
pct exec "$CTID" -- bash -c 'curl --fail --silent --max-time 5 http://127.0.0.1:8766/mcp >/dev/null || test "$?" -eq 22' \
  || log 'MCP GET endpoint may not return 200; verify handshake when connecting a client.'

log 'Installation complete'
printf 'CT %s created on %s. Vault inside CT: %s\n' "$CTID" "$NODE" "$CT_MOUNT"
printf 'MCP (read-only): http://127.0.0.1:8766/mcp INSIDE CT ONLY.\n'
printf 'Next: deploy Open WebUI, choose an authenticated/private bridge, then implement approved writes.\n'
printf 'Inspect: pct exec %s -- journalctl -u obsi-mcp -n 80 --no-pager\n' "$CTID"
