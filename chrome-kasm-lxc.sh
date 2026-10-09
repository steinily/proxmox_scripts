#!/usr/bin/env bash
set -Eeuo pipefail
# Proxmox host installer: Debian 12 + Chrome + XFCE + KasmVNC
[[ $EUID -eq 0 ]] || { echo "Run as root on Proxmox"; exit 1; }
for c in pct pveam pvesm openssl; do command -v "$c" >/dev/null || { echo "Missing: $c"; exit 1; }; done
CTID="${CTID:-$(pvesh get /cluster/nextid)}"
HOSTNAME="${HOSTNAME:-chrome-kasm}"
STORAGE="${STORAGE:-local-lvm}"
TEMPLATE_STORAGE="${TEMPLATE_STORAGE:-local}"
BRIDGE="${BRIDGE:-vmbr0}"
DISK_GB="${DISK_GB:-16}"
[[ "$CTID" =~ ^[0-9]+$ ]] || exit 1
pct status "$CTID" &>/dev/null && { echo "CTID exists"; exit 1; }
pvesm status --storage "$STORAGE" >/dev/null
pvesm status --storage "$TEMPLATE_STORAGE" >/dev/null
TEMPLATE="$(pveam available --section system | awk '$2 ~ /debian-12-standard.*amd64/ {print $2}' | sort -V | tail -1)"
[[ -n "$TEMPLATE" ]] || { echo "Debian 12 template not found"; exit 1; }
pveam download "$TEMPLATE_STORAGE" "$TEMPLATE"
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
# KasmVNC package releases are architecture/distribution-specific: resolve Debian bookworm amd64 release.
python3 - <<'PY' >/tmp/kasm-url
import json,urllib.request
req=urllib.request.Request('https://api.github.com/repos/kasmtech/KasmVNC/releases/latest',headers={'User-Agent':'proxmox-kasm-installer'})
data=json.load(urllib.request.urlopen(req,timeout=20))
matches=[a['browser_download_url'] for a in data['assets'] if a['name'].endswith('.deb') and 'bookworm' in a['name'].lower() and ('amd64' in a['name'].lower() or 'x86_64' in a['name'].lower())]
if len(matches)!=1: raise SystemExit('No unique Bookworm amd64 KasmVNC release; inspect upstream assets')
print(matches[0])
PY
curl -fL --retry 3 "$(cat /tmp/kasm-url)" -o /tmp/kasm.deb
apt-get install -y /tmp/kasm.deb
useradd -m -s /bin/bash browser
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
ExecStart=/usr/bin/vncserver :1 -geometry 1440x900 -depth 24 -interface 0.0.0.0
ExecStop=/usr/bin/vncserver -kill :1
Restart=on-failure
RestartSec=5
[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload
systemctl enable --now kasm-browser.service
INNER
echo "CTID: $CTID"
echo "KasmVNC user: browser"
echo "KasmVNC password: $PASSWORD"
echo "IP: $(pct exec "$CTID" -- hostname -I)"
echo "URL: https://<CT-IP>:6901"
echo "IMPORTANT: Keep port 6901 LAN-only; use authenticated reverse proxy for remote access."
