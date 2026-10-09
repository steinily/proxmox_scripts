#!/usr/bin/env bash
set -Eeuo pipefail
# Proxmox host installer: Debian 13 + Chrome + XFCE + KasmVNC
[[ $EUID -eq 0 ]] || { echo "Run as root on Proxmox"; exit 1; }
MODE="${1:-install}"
[[ "$MODE" == install || "$MODE" == --preflight ]] || { echo "Usage: $0 [--preflight]"; exit 2; }

for c in pct pveam pvesm pvesh openssl; do command -v "$c" >/dev/null || { echo "Missing: $c"; exit 1; }; done
CTID="${CTID:-$(pvesh get /cluster/nextid)}"
HOSTNAME="${HOSTNAME:-chrome-kasm}"
STORAGE="${STORAGE:-local-lvm}"
TEMPLATE_STORAGE="${TEMPLATE_STORAGE:-local}"
BRIDGE="${BRIDGE:-vmbr0}"
DISK_GB="${DISK_GB:-16}"
[[ "$CTID" =~ ^[0-9]+$ ]] || exit 1
if pct config "$CTID" &>/dev/null; then echo "CTID already exists"; exit 1; fi
pvesm status --storage "$STORAGE" >/dev/null
pvesm status --storage "$TEMPLATE_STORAGE" >/dev/null
pvesm status --storage "$STORAGE" | awk -v s="$STORAGE" '$1==s && $3=="active" {ok=1} END {exit !ok}' || { echo "Root storage inactive"; exit 1; }
pvesm status --storage "$TEMPLATE_STORAGE" | awk -v s="$TEMPLATE_STORAGE" '$1==s && $3=="active" {ok=1} END {exit !ok}' || { echo "Template storage inactive"; exit 1; }
ip link show "$BRIDGE" >/dev/null 2>&1 || { echo "Bridge not found: $BRIDGE"; exit 1; }
if [[ "$MODE" == "install" ]]; then pveam update; fi
TEMPLATE="$(pveam available --section system | awk '$2 ~ /debian-13-standard.*amd64/ {print $2}' | sort -V | tail -1)"
if [[ -z "$TEMPLATE" ]]; then
  TEMPLATE="$(pveam list "$TEMPLATE_STORAGE" | awk '$1 ~ /debian-13-standard.*amd64/ {print $1}' | sort -V | tail -1)"
fi
[[ -n "$TEMPLATE" ]] || { echo "Debian 13 template not found in available or local templates"; exit 1; }
if [[ "$MODE" == "install" ]] && ! pveam list "$TEMPLATE_STORAGE" | grep -Fq "${TEMPLATE##*/}"; then
  pveam download "$TEMPLATE_STORAGE" "${TEMPLATE##*/}"
fi
if [[ "$MODE" == "--preflight" ]]; then
  echo "PREFLIGHT OK (host checks only): CTID=$CTID, storage=$STORAGE, template-storage=$TEMPLATE_STORAGE, bridge=$BRIDGE, template=${TEMPLATE##*/}"
  echo "NOTE: Guest-side KasmVNC and Chrome installation cannot be validated without a test LXC."
  exit 0
fi
PASSWORD="${KASM_PASSWORD:-$(openssl rand -base64 24)}"
echo "Creating CT $CTID"
pct create "$CTID" "$TEMPLATE_STORAGE:vztmpl/${TEMPLATE##*/}" --hostname "$HOSTNAME" --ostype debian --unprivileged 1 --features nesting=1 --cores 2 --memory 2048 --swap 2048 --rootfs "$STORAGE:$DISK_GB" --net0 "name=eth0,bridge=$BRIDGE,ip=dhcp" --onboot 1 --start 1
pct exec "$CTID" -- bash -s -- "$PASSWORD" <<'INNER'
set -Eeuo pipefail
PASS="$1"
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y curl wget ca-certificates gnupg xfce4 xfce4-terminal dbus-x11 xauth python3 openssl
install -d -m 0755 /etc/apt/keyrings
curl -fsSL https://dl.google.com/linux/linux_signing_key.pub | gpg --dearmor -o /etc/apt/keyrings/google-chrome.gpg
echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/google-chrome.gpg] https://dl.google.com/linux/chrome/deb/ stable main" >/etc/apt/sources.list.d/google-chrome.list
apt-get update && apt-get install -y google-chrome-stable
# KasmVNC package releases are architecture/distribution-specific: resolve Debian trixie amd64 release.
python3 - <<'PY'
import hashlib,json,urllib.request
name='kasmvncserver_trixie_1.4.0_amd64.deb'
req=urllib.request.Request('https://api.github.com/repos/kasmtech/KasmVNC/releases/tags/v1.4.0',headers={'User-Agent':'proxmox-kasm-installer'})
with urllib.request.urlopen(req,timeout=30) as resp: release=json.load(resp)
assets=[a for a in release['assets'] if a['name']==name]
if len(assets)!=1: raise SystemExit('Expected pinned KasmVNC Trixie asset missing: '+name)
asset=assets[0]
digest=asset.get('digest','')
if not digest.startswith('sha256:'): raise SystemExit('GitHub asset SHA256 digest unavailable; refusing unverified package')
request=urllib.request.Request(asset['browser_download_url'],headers={'User-Agent':'proxmox-kasm-installer'})
h=hashlib.sha256()
with urllib.request.urlopen(request,timeout=90) as src,open('/tmp/kasm.deb','wb') as dst:
    while True:
        chunk=src.read(1024*1024)
        if not chunk: break
        dst.write(chunk);h.update(chunk)
if h.hexdigest()!=digest.split(':',1)[1]: raise SystemExit('KasmVNC SHA256 mismatch')
print('KasmVNC asset verified:',name)
PY
apt-get install -y /tmp/kasm.deb
useradd -m -s /bin/bash browser
usermod -aG ssl-cert browser
install -d -o browser -g browser /home/browser/.vnc
printf '%s\n' '#!/bin/sh' 'exec startxfce4' >/home/browser/.vnc/xstartup
chmod +x /home/browser/.vnc/xstartup
printf '%s\n' '#!/bin/sh' 'exec google-chrome-stable --no-first-run --password-store=basic' >/home/browser/Desktop-Chrome.sh
chmod +x /home/browser/Desktop-Chrome.sh
chown -R browser:browser /home/browser
printf '%s\n%s\n' "$PASS" "$PASS" | runuser -u browser -- vncpasswd -u browser -w -r
cat >/etc/systemd/system/kasm-browser.service <<'UNIT'
[Unit]
Description=Persistent KasmVNC Chrome desktop
After=network-online.target
Wants=network-online.target
[Service]
Type=forking
User=browser
WorkingDirectory=/home/browser
ExecStart=/usr/bin/vncserver :1 -geometry 1440x900 -depth 24
ExecStop=/usr/bin/vncserver -kill :1
Restart=on-failure
RestartSec=5
[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload
systemctl enable --now kasm-browser.service
systemctl is-active --quiet kasm-browser.service || { journalctl -u kasm-browser.service -n 60 --no-pager; exit 1; }
INNER
echo "CTID: $CTID"
echo "KasmVNC user: browser"
echo "KasmVNC password: $PASSWORD"
echo "IP: $(pct exec "$CTID" -- hostname -I)"
echo "KasmVNC port: inspect the URL reported in /home/browser/.vnc/*.log (typically 8443 or 5901, depending on release)"
echo "IMPORTANT: Restrict the KasmVNC listening port with firewall rules; do not expose it directly to the Internet."
