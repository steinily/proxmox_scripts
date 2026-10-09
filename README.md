# Proxmox Scripts — Persistent Chrome + KasmVNC

Reproducible, disposable **Debian 13 (amd64) Proxmox LXC** running Google Chrome Stable, Openbox and KasmVNC. Access a persistent browser desktop from another browser on your LAN; optionally publish it securely using **Cloudflare Tunnel + Access**.

> Independent project, **not affiliated with Community Scripts**. The direct guest-installation procedure below was successfully tested on a clean Debian 13.6 LXC on **2026-10-09**. The Community Scripts host entry point has **not** been end-to-end validated.

## Features

- Google Chrome Stable with a persistent profile in `/home/browser/.config/google-chrome`
- Lightweight Openbox desktop and KasmVNC web UI (HTTPS, port `8444`)
- Systemd-managed graphical session, automatically started when the container boots
- Chrome watchdog: relaunches Chrome after it exits; short-failure backoff
- Log rotation (daily, up to seven rotations, 1 MiB maxsize)
- Random initial KasmVNC password stored **inside the LXC**, root-readable only
- Disposable infrastructure: **no Proxmox backups required by the design**; browser profile, sessions and downloads are **not** recreated by the installer

## Repository layout

| Path | Role | Status |
| --- | --- | --- |
| [`install/chromekasm-install.sh`](install/chromekasm-install.sh) | Direct guest installer | **Tested end-to-end** |
| [`install/chrome-kasm-install.sh`](install/chrome-kasm-install.sh) | Identical guest installer used by the host builder | Same content; direct path validated |
| [`ct/chrome-kasm.sh`](ct/chrome-kasm.sh) | Community Scripts-based Proxmox host entry point | **Integration not yet validated** |
| [`chrome-kasm-lxc.sh`](chrome-kasm-lxc.sh) | Legacy standalone implementation | Legacy; do not use for the tested installation |
| [`chrome-kasm-debug.sh`](chrome-kasm-debug.sh) | Diagnostic helper | Optional |
| [`.github/workflows/installer-lint.yml`](.github/workflows/installer-lint.yml) | Installer static checks | CI; not a replacement for runtime tests |

## Requirements

- Proxmox VE host with a free CTID and an LXC-capable storage (`rootdir`)
- Debian 13 amd64 container template
- A network bridge with DHCP and outbound internet access (example: `vmbr0`)
- Suggested minimum: **2 vCPU, 2048 MiB RAM, 512 MiB swap, 16 GiB disk**
- Run Proxmox commands as `root` **on the Proxmox host**, not inside another LXC
- The guest installer must run as `root` **inside a fresh Debian 13 container**
- For direct LAN access, permit TCP `8444` only from trusted clients; **do not port-forward it to the public internet**

## Installation A — tested direct installation (recommended)

### 1. Check storage, template and CTID

On the **Proxmox host**:

```bash
pvesm status --content rootdir
pveam list local | grep debian-13
pct status 120
```

Choose an **unused** CTID, a storage listed by the first command, and an existing Debian 13 template. The following example uses **CTID 120**, `local` and `vmbr0`; **replace these to match your host**. Do not reuse an existing CTID.

### 2. Create a disposable Debian 13 LXC

```bash
pct create 120 \
  local:vztmpl/debian-13-standard_13.6-1_amd64.tar.zst \
  --hostname chrome-kasm \
  --ostype debian \
  --cores 2 \
  --memory 2048 \
  --swap 512 \
  --rootfs local:16 \
  --net0 name=eth0,bridge=vmbr0,ip=dhcp,type=veth \
  --unprivileged 1 \
  --features nesting=1 \
  --onboot 1 \
  --start 1
```

The template filename is the **one tested**, not a promise that it will always be available. Use the actual template name shown by `pveam list`. For a short-lived test container, set `--onboot 0`.

### 3. Install from GitHub inside the LXC

Run on the **Proxmox host**; `pct exec` runs the enclosed commands inside CTID 120:

```bash
pct exec 120 -- bash -c '
set -o pipefail
apt-get update &&
apt-get install -y curl ca-certificates &&
curl -fsSL \
  https://raw.githubusercontent.com/steinily/proxmox_scripts/main/install/chromekasm-install.sh \
  -o /root/chromekasm-install.sh &&
bash /root/chromekasm-install.sh 2>&1 | tee /root/chromekasm-install.log
'
```

This installs Chrome, Openbox, KasmVNC 1.4.0 (pinned Debian Trixie amd64 package with SHA-256 verification), the Chrome watchdog, logrotate, and `kasm-browser.service`. **Do not blindly rerun** the installer in a partially installed container: it assumes a fresh guest.

### 4. Verify the installation

```bash
pct status 120
pct exec 120 -- hostname -I
pct exec 120 -- systemctl is-active kasm-browser.service
pct exec 120 -- pgrep -ax openbox
pct exec 120 -- pgrep -u browser -af '^/opt/google/chrome/chrome --no-first-run'
pct exec 120 -- tail -20 /home/browser/.vnc/chrome-watchdog.log
```

Expected: `running`, a LAN IP, `active`, and both Openbox and Chrome processes. After a reboot, wait a few seconds before checking: systemd can initially show `activating`.

### 5. First login

Retrieve the randomly generated **initial** credentials locally on the Proxmox host:

```bash
pct exec 120 -- cat /root/kasmvnc-initial-credentials
```

**Never paste the password into an issue, chat, screenshot or commit.** Open `https://<LXC-IP>:8444` on your trusted LAN and sign in as `browser` with that password. The KasmVNC origin uses a self-signed certificate by default, so the browser may warn about TLS trust. Change the initial password after first login using KasmVNC's password management, and remove the temporary credentials file once the new password is verified.

The installer launches `https://chatgpt.com` in Chrome by default. Your Chrome profile survives service/container restarts **while the container still exists**.

## Installation B — Community Scripts host entry point (not yet validated)

For advanced users who want the Community Scripts provisioning flow, review and run the host script **on Proxmox**:

```bash
curl -fsSLo /root/chrome-kasm.sh \
  https://raw.githubusercontent.com/steinily/proxmox_scripts/main/ct/chrome-kasm.sh
less /root/chrome-kasm.sh
bash /root/chrome-kasm.sh
```

The host entry point loads the external Community Scripts core and delegates to `install/chrome-kasm-install.sh`. **This complete host/builder path has not been tested**; use Installation A for the validated path. Review the external core code before running it as root.

## Optional remote HTTPS: Cloudflare Tunnel + Access

Cloudflare configuration is **not automated by this repository**. In the tested setup, a separate Cloudflare Tunnel + Access deployment provides authenticated remote access.

- Point the tunnel origin at `https://<LXC-IP>:8444` when `cloudflared` runs **outside** this LXC; if it runs inside, `https://127.0.0.1:8444` can be used.
- Configure the tunnel's origin TLS verification/trust for KasmVNC's self-signed certificate. Do not disable TLS validation without understanding the security implications.
- Require Cloudflare Access authentication on the public hostname.
- Restrict direct port `8444` access to trusted networks; never expose it via router port forwarding.

The KasmVNC guest configuration currently listens on `0.0.0.0:8444` **inside the container**; the `-publicIP 127.0.0.1` launch option does **not** make that listener loopback-only.

## Operations and troubleshooting

Replace `120` with your actual CTID.

```bash
# Service and startup diagnostics
pct exec 120 -- systemctl status kasm-browser.service --no-pager -l
pct exec 120 -- journalctl -u kasm-browser.service -n 100 --no-pager

# Chrome watchdog
pct exec 120 -- tail -40 /home/browser/.vnc/chrome-watchdog.log

# Log rotation configuration
pct exec 120 -- logrotate -d /etc/logrotate.d/chrome-watchdog

# LAN listener
pct exec 120 -- ss -ltnp

# Reboot test
pct reboot 120
pct exec 120 -- systemctl is-active kasm-browser.service
```

If Chrome is missing immediately after reboot, wait 15 seconds and check again. The installer log is `/root/chromekasm-install.log` **when Installation A was used**.

### What was actually validated (2026-10-09)

- Fresh Debian 13.6 unprivileged LXC creation, DHCP connectivity, `apt-get update`
- Direct GitHub guest installer and interactive KasmVNC/Chrome access
- Watchdog: terminating Chrome PID `5301` led to replacement PID `6855`
- Full LXC reboot: `kasm-browser.service` active, Openbox, watchdog and Chrome processes restored
- Two guest installer files matched byte-for-byte and passed `bash -n`

**Not separately verified:** the complete Community Scripts host flow, an actual log rotation cycle, automatic upgrade/uninstall, and end-to-end Cloudflare setup from this repository.

## Disposable deployment and cleanup

The installer restores the **software and configuration**, **not** Chrome sign-ins, bookmarks, downloads, extensions or other local profile data. Keep important data outside the LXC if it must survive deletion. No automatic Proxmox backup is configured by this project.

For a disposable **test** LXC only, after verifying its CTID and that it contains nothing to keep:

```bash
pct shutdown 120 --timeout 30
pct destroy 120
```

**Never run the destroy command against your production CTID.** There is currently no in-place update, rollback, or uninstall implementation.

## Security and attribution

This repository executes scripts as root and downloads third-party components. Review the code before execution. KasmVNC initial credentials are local to the guest; do not commit secrets or tunnel tokens. Community Scripts is an independent project and is not responsible for this integration.

## License

No license is asserted for this repository unless a separate `LICENSE` file is added. Third-party components retain their respective licenses.
