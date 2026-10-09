#!/usr/bin/env bash
# Diagnostic launcher for Chrome Kasm Community Scripts installer.
# Run as root on the Proxmox VE host. Does not modify the installer.
set -uo pipefail

if [[ "${EUID}" -ne 0 ]]; then
  echo "ERROR: Run this script as root on the Proxmox host." >&2
  exit 1
fi
for cmd in bash curl tee tail; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "Missing dependency: $cmd" >&2; exit 1; }
done

INSTALLER_URL="https://raw.githubusercontent.com/steinily/proxmox_scripts/main/ct/chrome-kasm.sh"
INSTALLER="/root/chrome-kasm.sh"
LOG="/root/chrome-kasm-debug-$(date +%Y%m%d-%H%M%S).log"

echo "Downloading: $INSTALLER_URL"
if ! curl --fail --show-error --silent --location "$INSTALLER_URL" --output "$INSTALLER"; then
  echo "ERROR: Download failed. No installer executed." >&2
  exit 1
fi
if ! bash -n "$INSTALLER"; then
  echo "ERROR: Installer syntax check failed. No installer executed." >&2
  exit 1
fi

echo "Installer downloaded and syntax checked."
echo "Log file: $LOG"
echo "WARNING: Running this script will launch the real LXC installer."
echo "If its configuration menu appears, stop before confirming container creation when only diagnosing startup."
read -r -p "Launch installer with bash -x diagnostics? [y/N]: " ANSWER
if [[ ! "$ANSWER" =~ ^([yY]|[yY][eE][sS])$ ]]; then
  echo "Cancelled. No installer launched."
  exit 0
fi

set +e
bash -x "$INSTALLER" 2>&1 | tee "$LOG"
STATUS=${PIPESTATUS[0]}
set -e

echo
echo "Installer exit code: $STATUS"
echo "Log saved: $LOG"
echo "Last 50 log lines:"
tail -n 50 "$LOG"
echo
echo "Review the log for credentials or sensitive host details before sharing."
exit "$STATUS"
