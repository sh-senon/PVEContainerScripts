#!/usr/bin/env bash
# Run on pve03. Adds isolated authenticated write service to CT133 and tunnel to CT134.
# Keeps existing MCP read-only, does not mount TrueNAS into the WebUI container.
set -Eeuo pipefail

CT_KB=133
CT_UI=134
NODE=pve03
ROOT_MOUNT=/mnt/obsi-ai
CT_MOUNT=/srv/obsi-ai
DRY_RUN=0
WRITE_CREATED=0
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
WORK=""

say() { printf '\n[obsi-hybrid] %s\n' "$*"; }
die() { printf '[obsi-hybrid ERROR] %s\n' "$*" >&2; exit 1; }
cleanup() {
  if [[ -n "$WORK" && -d "$WORK" ]]; then
    rm -r -- "$WORK"
  fi
}
trap cleanup EXIT
on_error() {
  local status=$?
  printf '[obsi-hybrid ERROR] Upgrade stopped at line %s (exit %s).\n' "$1" "$status" >&2
  printf '[obsi-hybrid] The original read-only MCP server has not been replaced.\n' >&2
  if (( WRITE_CREATED )) && pct exec "$CT_KB" -- test -f /etc/systemd/system/obsi-write.service 2>/dev/null; then
    pct exec "$CT_KB" -- systemctl disable --now obsi-write.service >/dev/null 2>&1 || true
    printf '[obsi-hybrid] The new write service was disabled for safety. Inspect before retrying.\n' >&2
  fi
  exit "$status"
}
trap 'on_error "$LINENO"' ERR

case "${1:-}" in
  --dry-run) DRY_RUN=1 ;;
  "") ;;
  *) die 'Usage: bash obsi-hybrid-upgrade.sh [--dry-run]' ;;
esac

[[ $EUID -eq 0 ]] || die 'Run as root on pve03'
[[ "$(hostname -s)" == "$NODE" ]] || die 'This script must run on pve03'
for command in pct findmnt flock openssl mktemp; do
  command -v "$command" >/dev/null || die "Missing dependency: $command"
done
[[ -f "$SCRIPT_DIR/obsi-write-server.py" ]] || die 'Place obsi-write-server.py beside this script'
[[ -f "$SCRIPT_DIR/obsi-hybrid-tool.py" ]] || die 'Place obsi-hybrid-tool.py beside this script'
findmnt -rn --mountpoint "$ROOT_MOUNT" -t nfs,nfs4 >/dev/null ||
  die 'TrueNAS NFS mount missing on host'
[[ "$(findmnt -rn -o SOURCE --mountpoint "$ROOT_MOUNT")" == '10.69.69.4:/mnt/Pool-2/obsi-ai' ]] ||
  die 'TrueNAS export does not match expected source'
[[ -f "$ROOT_MOUNT/.obsi-storage-check" ]] || die 'TrueNAS safety marker missing'

for id in "$CT_KB" "$CT_UI"; do
  pct status "$id" | grep -q '^status: running$' || die "CT $id must be running"
  pct config "$id" | grep -q '^unprivileged: 1$' || die "CT $id is not unprivileged"
done
pct config "$CT_KB" | grep -Fq 'mp=/srv/obsi-ai' || die 'KB vault mount missing'
pct exec "$CT_KB" -- systemctl is-active --quiet obsi-mcp ||
  die 'Read-only MCP service is not healthy'
pct exec "$CT_UI" -- systemctl is-active --quiet obsi-webui ||
  die 'Open WebUI service is not healthy'
pct exec "$CT_UI" -- systemctl is-active --quiet obsi-mcp-tunnel ||
  die 'Existing MCP tunnel is not healthy'
pct exec "$CT_UI" -- test -f /root/.ssh/obsi_mcp ||
  die 'SSH tunnel key is missing'
pct exec "$CT_KB" -- test -f /home/obsi-tunnel/.ssh/authorized_keys ||
  die 'Tunnel public key is missing'
pct exec "$CT_KB" -- test ! -e /etc/systemd/system/obsi-write.service ||
  die 'Write service already exists. Stop and review it before rerunning.'
pct exec "$CT_UI" -- id obsiwebui >/dev/null ||
  die 'Open WebUI service account missing'

say 'Review planned upgrade'
printf 'CT 133: add localhost-only write service on 127.0.0.1:8767, token authentication\n'
printf 'CT 134: extend existing SSH tunnel to localhost:18767, plus read-only token file\n'
printf 'CT 133 read-only MCP service will NOT change. No data files are removed.\n'
printf 'Existing notes will require confirmation inside the Open WebUI Python tool.\n'
printf 'Open WebUI and the tunnel will restart briefly; chat access may pause.\n'
if ((DRY_RUN)); then
  say 'Dry run complete. Nothing changed.'
  exit 0
fi

[[ -t 0 ]] || die 'Installation requires interactive confirmation'
read -r -p 'Proceed? Type UPGRADE: ' approval
[[ "$approval" == UPGRADE ]] || die 'Cancelled'

exec 9>/run/lock/obsi-hybrid-upgrade.lock
flock -n 9 || die 'Another hybrid upgrade is running'
WORK="$(mktemp -d /root/obsi-hybrid.XXXXXX)"
chmod 700 "$WORK"

say 'Backing up tunnel authorization and service definitions inside LXCs'
pct exec "$CT_KB" -- cp -a /home/obsi-tunnel/.ssh/authorized_keys /home/obsi-tunnel/.ssh/authorized_keys.obsi-prewrite
pct exec "$CT_UI" -- cp -a /etc/systemd/system/obsi-mcp-tunnel.service /etc/systemd/system/obsi-mcp-tunnel.service.obsi-prewrite

say 'Installing authenticated write server in CT 133'
pct exec "$CT_KB" -- install -d -m 0750 /opt/obsi-write
pct push "$CT_KB" "$SCRIPT_DIR/obsi-write-server.py" /opt/obsi-write/server.py
pct exec "$CT_KB" -- chmod 0640 /opt/obsi-write/server.py
pct exec "$CT_KB" -- python3 -m py_compile /opt/obsi-write/server.py

if ! pct exec "$CT_KB" -- test -f /etc/obsi-write-token; then
  pct exec "$CT_KB" -- bash -c 'umask 077; openssl rand -hex 32 > /etc/obsi-write-token'
fi
pct exec "$CT_KB" -- chmod 0600 /etc/obsi-write-token
pct pull "$CT_KB" /etc/obsi-write-token "$WORK/obsi-write-token"
pct push "$CT_UI" "$WORK/obsi-write-token" /etc/obsi-write-token
pct exec "$CT_UI" -- chown root:obsiwebui /etc/obsi-write-token
pct exec "$CT_UI" -- chmod 0640 /etc/obsi-write-token
pct exec "$CT_UI" -- runuser -u obsiwebui -- test -r /etc/obsi-write-token ||
  die 'Open WebUI cannot read service token'

cat > "$WORK/obsi-write.service" <<'UNIT'
[Unit]
Description=Obsi authenticated TrueNAS write service
Wants=network-online.target
After=network-online.target
ConditionPathIsMountPoint=/srv/obsi-ai

[Service]
Type=simple
User=root
Group=root
ExecStartPre=/usr/bin/test -f /srv/obsi-ai/.obsi-storage-check
ExecStart=/usr/bin/python3 /opt/obsi-write/server.py
Restart=on-failure
RestartSec=5
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true
ProtectSystem=strict
ReadWritePaths=/srv/obsi-ai
RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6
UMask=0027

[Install]
WantedBy=multi-user.target
UNIT
pct push "$CT_KB" "$WORK/obsi-write.service" /etc/systemd/system/obsi-write.service
WRITE_CREATED=1
pct exec "$CT_KB" -- systemctl daemon-reload
pct exec "$CT_KB" -- systemctl enable --now obsi-write.service
pct exec "$CT_KB" -- systemctl is-active --quiet obsi-write.service ||
  die 'Write service failed to start; check journalctl -u obsi-write'

say 'Allowing dedicated SSH key to tunnel ONLY to the second loopback endpoint'
pct exec "$CT_KB" -- python3 -c '
from pathlib import Path
p=Path("/home/obsi-tunnel/.ssh/authorized_keys")
s=p.read_text()
old="permitopen=\"127.0.0.1:8766\""
assert s.count(old) == 1, "Tunnel key permission needs manual inspection"
s=s.replace(old, old + ",permitopen=\"127.0.0.1:8767\"", 1)
p.write_text(s)
'
pct exec "$CT_KB" -- chown obsi-tunnel:obsi-tunnel /home/obsi-tunnel/.ssh/authorized_keys
pct exec "$CT_KB" -- chmod 0600 /home/obsi-tunnel/.ssh/authorized_keys

say 'Extending existing tunnel with second forwarded localhost-only port'
pct exec "$CT_UI" -- install -d -m 0755 /etc/systemd/system/obsi-mcp-tunnel.service.d
cat > "$WORK/20-obsi-write.conf" <<'UNIT'
[Service]
ExecStart=
ExecStart=/usr/bin/ssh -NT -i /root/.ssh/obsi_mcp -o BatchMode=yes -o StrictHostKeyChecking=yes -o ExitOnForwardFailure=yes -o ServerAliveInterval=30 -o ServerAliveCountMax=3 -L 127.0.0.1:18766:127.0.0.1:8766 -L 127.0.0.1:18767:127.0.0.1:8767 obsi-tunnel@10.69.69.110
UNIT
pct push "$CT_UI" "$WORK/20-obsi-write.conf" /etc/systemd/system/obsi-mcp-tunnel.service.d/20-obsi-write.conf
pct exec "$CT_UI" -- systemctl daemon-reload
pct exec "$CT_UI" -- systemctl restart obsi-mcp-tunnel
pct exec "$CT_UI" -- systemctl is-active --quiet obsi-mcp-tunnel ||
  die 'Tunnel did not restart. Restore original unit and check logs.'

say 'Testing authenticated local write endpoint WITHOUT writing any notes'
pct exec "$CT_UI" -- python3 -c '
import json, pathlib, urllib.request
secret=pathlib.Path("/etc/obsi-write-token").read_text().strip()
request=urllib.request.Request(
    "http://127.0.0.1:18767/write",
    data=json.dumps({"operation":"inspect","path":"obsi-connection-test.md"}).encode(),
    headers={"Authorization":"Bearer "+secret,"Content-Type":"application/json"},
    method="POST")
with urllib.request.urlopen(request, timeout=8) as response:
    data=json.load(response)
assert "exists" in data, data
print("Secure write endpoint healthy; test was read-only")
'
pct exec "$CT_UI" -- systemctl is-active --quiet obsi-webui ||
  die 'Open WebUI not running'

say 'Upgrade complete. No Markdown notes or screenshots were created.'
printf 'Next: import obsi-hybrid-tool.py via Open WebUI > Workspace > Tools.\n'
printf 'Enable the tool for your Obsi model alongside the existing read-only MCP connection.\n'
