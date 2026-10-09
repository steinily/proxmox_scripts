#!/usr/bin/env bash
# Community Scripts core-based Proxmox LXC builder.
# Experimental: do not execute until the guest installer and credential bootstrap are integrated.
set -Eeuo pipefail
echo "The Community Scripts integration is under development; no LXC has been created." >&2
exit 2

# Target architecture (intentionally unreachable until integration is verified):
# source <(curl -fsSL https://raw.githubusercontent.com/community-scripts/core/main/core/build.func)
# APP="Chrome Kasm"
# var_cpu=2
# var_ram=2048
# var_disk=16
# var_os=debian
# var_version=13
# var_unprivileged=1
# header_info "$APP"
# variables
# color
# catch_errors
# start
# build_container
# description
