#!/usr/bin/env bash
set -Eeuo pipefail
# Proxmox host installer: Debian 13 + Chrome + XFCE + KasmVNC
[[ $EUID -eq 0 ]] || { echo "Run as root on Proxmox"; exit 1; }
MODE="${1:-install}"
[[ "$MODE" == install || "$MODE" == --preflight ]] || { echo "Usage: $0 [--preflight]"; exit 2; }

for c in pct pveam pvesm pvesh openssl; do command -v "$c" >/dev/null || { echo "Missing: $c"; exit 1; }; done
CTID="${CTID:-$(pvesh get /cluster/nextid)}"
HOSTNAME="${HOSTNAME:-chrome-kasm}"
STORAGE="${STORAGE:-}"
TEMPLATE_STORAGE="${TEMPLATE_STORAGE:-}"
BRIDGE="${BRIDGE:-vmbr0}"
DISK_GB="${DISK_GB:-16}"
[[ "$CTID" =~ ^[0-9]+$ ]] || { echo "Invalid CTID"; exit 1; }
[[ "$DISK_GB" =~ ^[0-9]+$ ]] && (( DISK_GB >= 16 )) || { echo "DISK_GB must be >= 16"; exit 1; }
if pct config "$CTID" &>/dev/null; then echo "CTID already exists"; exit 1; fi

# Community Scripts pattern: discover storages by Proxmox content type.
select_storage() {
  local content="$1" chosen="$2" line
  local -a candidates=()
  mapfile -t candidates < <(pvesm status -content "$content" | awk 'NR>1 && $3=="active" {print $1}')
  if [[ -n "$chosen" ]]; then
    for line in "${candidates[@]}"; do
      if [[ "$line" == "$chosen" ]]; then printf '%s\n' "$chosen"; return 0; fi
    done
    echo "Storage '$chosen' is not active or does not support '$content'." >&2
    return 1
  fi
  case "${#candidates[@]}" in
    0) echo "No active storage supports '$content'." >&2; return 1 ;;
    1) printf '%s\n' "${candidates[0]}" ;;
    *)
      if [[ ! -t 0 ]]; then
        echo "Multiple '$content' storages: ${candidates[*]}; set STORAGE or TEMPLATE_STORAGE explicitly." >&2
        return 1
      fi
      echo "Available '$content' storages:" >&2
      local i
      for i in "${!candidates[@]}"; do printf '  %d) %s\n' "$((i+1))" "${candidates[i]}" >&2; done
      local selection
      read -r -p "Select number: " selection
      [[ "$selection" =~ ^[0-9]+$ ]] && (( selection>=1 && selection<=${#candidates[@]} )) || return 1
      printf '%s\n' "${candidates[selection-1]}"
      ;;
  esac
}
STORAGE="$(select_storage rootdir "$STORAGE")"
TEMPLATE_STORAGE="$(select_storage vztmpl "$TEMPLATE_STORAGE")"
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
# Transfer secret through stdin, never through process arguments.
printf '%s' "$PASSWORD" | pct exec "$CTID" -- sh -c 'umask 077; cat > /root/.kasm-setup-password'
pct exec "$CTID" -- bash -s <<'INNER'
set -Eeuo pipefail
trap 'rm -f /root/.kasm-setup-password' EXIT
PASS="$(cat /root/.kasm-setup-password)"
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y curl wget ca-certificates gnupg xfce4 xfce4-terminal dbus-x11 xauth python3 openssl ssl-cert
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
  interface: 127.0.0.1
  websocket_port: 8444
  use_ipv6: false
  udp:
    stun_server: none
KASMCONFIG
printf '%s\n' '#!/bin/sh' 'exec startxfce4' >/home/browser/.vnc/xstartup
chmod +x /home/browser/.vnc/xstartup
install -d /home/browser/.config/autostart
cat >/home/browser/.config/autostart/chrome.desktop <<'DESKTOP'
[Desktop Entry]
Type=Application
Name=Google Chrome
Exec=google-chrome-stable --no-first-run --no-default-browser-check --disable-dev-shm-usage https://chatgpt.com
Terminal=false
X-GNOME-Autostart-enabled=true
DESKTOP
chown -R browser:browser /home/browser
printf '%s\n%s\n' "$PASS" "$PASS" | runuser -u browser -- vncpasswd -u browser -w -r
unset PASS
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
echo "KasmVNC password: $PASSWORD" # Save securely; shown only once
echo "IP: $(pct exec "$CTID" -- hostname -I)"
echo "KasmVNC endpoint inside LXC: https://127.0.0.1:8444 (loopback only)"
echo "IMPORTANT: Do not expose KasmVNC directly; use Cloudflare Tunnel + Access."
