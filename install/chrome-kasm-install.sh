#!/usr/bin/env bash
# Application-only installer; intended for Debian 13 LXC provisioned by Community Scripts.
set -Eeuo pipefail
if [[ -n "${FUNCTIONS_FILE_PATH:-}" ]]; then
  # Community Scripts passes the shared helper location via this variable.
  # shellcheck disable=SC1090
  source /dev/stdin <<<"$FUNCTIONS_FILE_PATH"
  color
  catch_errors
  setting_up_container
  network_check
  update_os
fi
[[ "$EUID" -eq 0 ]] || { echo "Run as root in the container" >&2; exit 1; }
[[ "$( . /etc/os-release; echo "$ID:$VERSION_ID" )" == "debian:13" ]] || { echo "Debian 13 required" >&2; exit 1; }
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends curl wget ca-certificates gnupg openbox dbus-x11 xauth python3 openssl ssl-cert logrotate
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
cat >/home/browser/.vnc/kasmvnc.yaml <<'KASMCONFIG'
network:
  # LAN access; restrict port 8444 to trusted networks using the Proxmox firewall.
  interface: 0.0.0.0
  websocket_port: 8444
  use_ipv6: false
  udp:
    stun_server: none
KASMCONFIG
# Suppress KasmVNC's interactive desktop-selection prompt; launch our own session.
printf '%s\n' '1' > /home/browser/.vnc/.de-was-selected
cat >/home/browser/.vnc/chrome-watchdog.sh <<'WATCHDOG'
#!/bin/bash
LOG="$HOME/.vnc/chrome-watchdog.log"
echo "$(date '+%F %T') Watchdog started" >> "$LOG"
while true; do
  echo "$(date '+%F %T') Starting Chrome" >> "$LOG"
  START_TIME=$SECONDS
  google-chrome-stable \
    --no-first-run \
    --no-default-browser-check \
    --disable-dev-shm-usage \
    --start-maximized \
    https://chatgpt.com
  EXIT_CODE=$?
  RUNTIME=$((SECONDS - START_TIME))
  echo "$(date '+%F %T') Chrome exited: code=$EXIT_CODE runtime=${RUNTIME}s" >> "$LOG"
  if [ "$RUNTIME" -lt 30 ]; then
    sleep 15
  else
    sleep 3
  fi
done
WATCHDOG
chmod 755 /home/browser/.vnc/chrome-watchdog.sh
cat >/home/browser/.vnc/xstartup <<'STARTUP'
#!/bin/sh
export XDG_CURRENT_DESKTOP=OPENBOX
export XDG_SESSION_DESKTOP=openbox
exec dbus-run-session -- sh -c '
  openbox &
  WM_PID=$!
  sleep 2
  "$HOME/.vnc/chrome-watchdog.sh" &
  wait "$WM_PID"
'
STARTUP
chmod 755 /home/browser/.vnc/xstartup
# Rotate watchdog logs without stopping the persistent Chrome session.
cat >/etc/logrotate.d/chrome-watchdog <<'LOGROTATE'
/home/browser/.vnc/chrome-watchdog.log {
    daily
    rotate 7
    maxsize 1M
    missingok
    notifempty
    compress
    copytruncate
    su browser browser
}
LOGROTATE
chown -R browser:browser /home/browser
# Create a unique temporary initial credential; change it after first login.
# This is written root-only inside the LXC for first-login recovery.
umask 077
KASM_INITIAL_PASSWORD="$(openssl rand -hex 18)"
printf '%s\n%s\n' "$KASM_INITIAL_PASSWORD" "$KASM_INITIAL_PASSWORD" | runuser -u browser -- vncpasswd -u browser -w -r
printf 'KasmVNC username: browser\nKasmVNC initial password: %s\n' "$KASM_INITIAL_PASSWORD" >/root/kasmvnc-initial-credentials
unset KASM_INITIAL_PASSWORD
cat >/etc/systemd/system/kasm-browser.service <<'UNIT'
[Unit]
Description=Persistent KasmVNC Chrome desktop
After=network-online.target
Wants=network-online.target
[Service]
Type=forking
User=browser
WorkingDirectory=/home/browser
ExecStart=/usr/bin/vncserver :1 -geometry 1440x900 -depth 24 -publicIP 127.0.0.1
ExecStop=/usr/bin/vncserver -kill :1
Restart=on-failure
RestartSec=5
[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload
# Keep enable and start separate so a startup failure can be diagnosed.
systemctl enable kasm-browser.service
if ! systemctl start kasm-browser.service; then
  echo "ERROR: KasmVNC service failed to start; diagnostics follow." >&2
  systemctl status kasm-browser.service --no-pager -l >&2 || true
  journalctl -u kasm-browser.service -n 120 --no-pager >&2 || true
  echo "KasmVNC log files:" >&2
  find /home/browser/.vnc -maxdepth 2 -type f -name '*.log' -print -exec tail -n 80 {} \; >&2 || true
  echo "The Community Scripts failure menu may auto-remove the container; choose Keep container for debugging promptly." >&2
  exit 1
fi
if ! systemctl is-active --quiet kasm-browser.service; then
  systemctl status kasm-browser.service --no-pager -l >&2 || true
  journalctl -u kasm-browser.service -n 120 --no-pager >&2 || true
  exit 1
fi
echo "Chrome + Openbox + KasmVNC installed. LAN URL: https://$(hostname -I | awk '{print $1}'):8444"
echo "Initial credentials: /root/kasmvnc-initial-credentials (root-only). Change password after first login."
echo "Security: do not forward port 8444 to the internet; restrict it to trusted LAN clients."
