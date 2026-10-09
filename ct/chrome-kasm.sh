#!/usr/bin/env bash
# Chrome + XFCE + KasmVNC, using the Community Scripts LXC engine.
# Source: https://github.com/community-scripts/core (MIT)
set -Eeuo pipefail
COMMUNITY_SCRIPTS_URL="${COMMUNITY_SCRIPTS_URL:-https://raw.githubusercontent.com/steinily/proxmox_scripts/main}"
export COMMUNITY_SCRIPTS_URL
_cs_boot="${COMMUNITY_SCRIPTS_CORE_DIR:-$(dirname "${BASH_SOURCE[0]}")/../../core}/core/build.func"
# shellcheck disable=SC1090
source "$_cs_boot" 2>/dev/null || source <(curl -fsSL "${COMMUNITY_SCRIPTS_CORE_URL:-https://raw.githubusercontent.com/community-scripts/core/main}/core/build.func")

APP="Chrome Kasm"
var_tags="${var_tags:-browser;remote}"
var_cpu="${var_cpu:-2}"
var_ram="${var_ram:-2048}"
var_disk="${var_disk:-16}"
var_os="${var_os:-debian}"
var_version="${var_version:-13}"
var_unprivileged="${var_unprivileged:-1}"
var_arm64="no"

header_info "$APP"
variables
color
catch_errors

function update_script() {
  msg_error "In-place updates are not implemented. No changes made."
  exit 2
}

start
build_container
description
