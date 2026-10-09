# Proxmox Scripts

Custom Proxmox VE installers using the [Community Scripts](https://github.com/community-scripts/ProxmoxVE) architecture and shared [core framework](https://github.com/community-scripts/core). This repository is **not affiliated with or maintained by Community Scripts**.

## Chrome + XFCE + KasmVNC — experimental

The goal is a persistent Chrome desktop in a Debian 13 LXC, accessible through KasmVNC. **End-to-end installation has not yet been verified. Use a disposable test container only.**

### Which script do I run?

| File | Purpose | Run manually? |
| --- | --- | --- |
| [`ct/chrome-kasm.sh`](ct/chrome-kasm.sh) | Proxmox host entry point: Community Scripts configuration, storage/template selection and LXC creation | **Yes, on Proxmox host as root** |
| [`install/chrome-kasm-install.sh`](install/chrome-kasm-install.sh) | Guest installation: XFCE, Google Chrome, KasmVNC, service and initial credentials | **No. Called by the builder inside the LXC** |
| [`chrome-kasm-lxc.sh`](chrome-kasm-lxc.sh) | Legacy standalone installer, including its own `--preflight` | **Legacy only; not the new installation path** |

The new entry point sets `COMMUNITY_SCRIPTS_URL` to this repository, and `var_install=chrome-kasm-install`, so the Community Scripts engine should resolve `install/chrome-kasm-install.sh` from this repository rather than upstream.

### Planned installation — test environment only

On the **Proxmox host**, as `root`:

```bash
curl -fsSLo /root/chrome-kasm.sh https://raw.githubusercontent.com/steinily/proxmox_scripts/main/ct/chrome-kasm.sh
less /root/chrome-kasm.sh
bash /root/chrome-kasm.sh
```

The builder will prompt for the supported container settings. **Do not use the legacy root-level `chrome-kasm-lxc.sh` to start the new installation.** The command above is documented for an isolated test; it has not been verified to complete successfully.

### Defaults

| Setting | Value |
| --- | --- |
| Guest OS | Debian 13 (amd64) |
| CPU | 2 cores |
| RAM | 2048 MiB |
| Disk | 16 GiB |
| Container | Unprivileged |
| Desktop | XFCE |
| Browser | Google Chrome Stable |
| Remote desktop | KasmVNC 1.4.0, Trixie amd64 package |

Swap, networking, template and storage choices are handled by the Community Scripts builder; do not assume the old standalone installer's `STORAGE`/`BRIDGE` variables apply.

### First login and diagnostics

The guest installer is intended to generate initial credentials in `/root/kasmvnc-initial-credentials` (root-only). After a successful installation, substitute the actual CTID:

```bash
pct exec <CTID> -- cat /root/kasmvnc-initial-credentials
pct exec <CTID> -- systemctl status kasm-browser.service --no-pager
pct exec <CTID> -- journalctl -u kasm-browser.service -n 100 --no-pager
pct exec <CTID> -- ss -ltnp
```

The intended KasmVNC bind is `127.0.0.1:8444` **inside the container**. Its actual binding, TLS configuration, login and XFCE/Chrome startup still require runtime verification.

### Cloudflare Tunnel + Access

Cloudflare is configured **manually**, outside this installer.

- Install/run `cloudflared` in the **same LXC** if the origin is `https://127.0.0.1:8444`.
- Protect the public hostname with **Cloudflare Access** authentication.
- If KasmVNC uses a self-signed origin certificate, configure the tunnel's origin TLS trust appropriately; do not expose the VNC service directly to the Internet.
- A tunnel running on a different host cannot reach the container's loopback address.

### Known limitations

- **No verified full install yet.** The Community Scripts host/guest integration and startup are still experimental.
- The guest installer currently expects a fresh Debian 13 container; retrying against a partially installed container may fail.
- KasmVNC password creation, the `vncserver` service unit, XFCE startup, Chrome autostart and HTTPS port must be tested.
- No automated upgrade, rollback or uninstall flow.
- 2 GiB RAM is a minimum; more memory may be needed for multiple Chrome tabs.
- The legacy script and its `--preflight` remain in the repository for reference; that preflight **does not validate the new Community Scripts path**.

### Source and licensing

The host installer loads the external Community Scripts core framework at runtime. Review upstream code and versions before running scripts as root. Community Scripts is MIT licensed; this repository is an independent integration.

## Disclaimer

Use only on systems you administer, review the scripts before execution, and test in a disposable LXC before production deployment.
