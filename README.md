# Proxmox Scripts

Standalone Proxmox VE LXC installers. **Not affiliated with Community Scripts.**

## Chrome + KasmVNC (experimental)

Creates a persistent Debian 13 unprivileged LXC with Google Chrome Stable, XFCE and KasmVNC.

| Setting | Default |
| --- | --- |
| CPU | 2 cores |
| Memory | 2048 MiB |
| Swap | 2048 MiB |
| Disk | 16 GiB |
| Network | vmbr0 / DHCP |
| Root filesystem storage | local-lvm |
| Template storage | local |
| Boot on host startup | Enabled |

### Install

Run **on the Proxmox VE host as root**. Inspect the script before execution:

```bash
curl -fsSLo /root/chrome-kasm-lxc.sh https://raw.githubusercontent.com/steinily/proxmox_scripts/main/chrome-kasm-lxc.sh
less /root/chrome-kasm-lxc.sh
bash /root/chrome-kasm-lxc.sh
```

Optional environment variables: `CTID`, `HOSTNAME`, `STORAGE`, `TEMPLATE_STORAGE`, `BRIDGE`, `DISK_GB`, `KASM_PASSWORD`.

Example:

```bash
CTID=210 STORAGE=local-lvm TEMPLATE_STORAGE=local BRIDGE=vmbr0 bash /root/chrome-kasm-lxc.sh
```

### Security

- Do **not** forward TCP/6901 directly to the Internet.
- Use an authenticated HTTPS gateway (e.g. Cloudflare Tunnel + Access) for remote access; restrict direct LAN access with firewall rules.
- The installer prints the generated KasmVNC password to the terminal: treat terminal logs as sensitive.
- Prefer a dedicated low-privilege browser account; avoid using the browser for sensitive company data without authorization.

### Known limitations / verification required

**Experimental / not yet validated on a running Proxmox host.** The current installer must not be treated as production-ready.

- KasmVNC GitHub release asset matching for Debian 13 (Trixie) may fail if upstream naming differs.
- KasmVNC `vncpasswd` invocation, TLS defaults, port binding and systemd startup need end-to-end verification.\n- KasmVNC 1.5.0 release assets must be checked for an exact Debian 13 Trixie amd64 match; do not substitute a Bookworm package automatically.\n- The current installer has not been executed on a Proxmox host; **do not run in production yet**.
- Chrome is configured to autostart in XFCE with https://chatgpt.com, but this has not yet been verified in a live LXC.
- Template listing is refreshed and existing downloaded templates are reused; storage compatibility still needs verification on the target node.
- No interactive advanced mode, rollback, structured logs, health checks or upgrade/uninstall commands yet.
- The script creates a container before application installation. A later error can leave a partially configured container; investigate before retrying.
- 2 GiB RAM is a minimal allocation for Chrome; increase it if multiple tabs are required.

### Diagnostics

```bash
pct list
pct exec <CTID> -- systemctl status kasm-browser.service --no-pager
pct exec <CTID> -- journalctl -u kasm-browser.service -n 100 --no-pager
pct exec <CTID> -- google-chrome-stable --version
```

Do not assume a fixed KasmVNC port. Inspect `/home/browser/.vnc/*.log` for the actual listening address after startup.

## Community Scripts comparison

Reference: https://github.com/community-scripts/ProxmoxVE

| Capability | Community Scripts | This repository |
| --- | --- | --- |
| One-command installation | Yes | Yes |
| Default / advanced interactive setup | Yes | Not yet |
| Storage and network configuration | Interactive | Environment variables |
| Common provisioning functions | Yes | Not yet |
| Logging, retries and diagnostics | Shared helpers | Basic shell error handling |
| Updates and recovery | Application-specific | Not yet |
| Container resource defaults | Configurable | 2 CPU / 2 GiB RAM / 2 GiB swap |

Community Scripts typically separates host-side container creation (`ct/`) from in-container installation (`install/`) and uses shared build/install helpers. A future version of this project should adopt that separation **without importing unstable upstream internals**.

### Roadmap

1. Split host-side provisioning and guest-side installation.
2. Add preflight checks, validated storage/template selection, Default/Advanced modes and safe secret handling.
3. Pin and verify KasmVNC packages, test Debian compatibility and make service startup reliable.
4. Add health checks, install logs, safe retry/recovery, update and uninstall commands.
5. Test on Proxmox VE 8/9 and document verified versions.

## Disclaimer

Use at your own risk. Review all scripts before running them with root privileges.
