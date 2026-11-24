#!/bin/bash
# udm-cloudflared installs cloudflared on a gateway with UniFi OS 2.x or later.
# cloudflared is the connector for a Cloudflare Tunnel.
# All files stay in /data, which UniFi OS keeps during a firmware update.
#
# Usage: udm-cloudflared.sh [install|update|restore|status|uninstall [--purge]]

set -euo pipefail

DIR="/data/cloudflared"
BIN="${DIR}/cloudflared"
ENV_FILE="${DIR}/cloudflared.env"
UNIT_SRC="${DIR}/cloudflared.service"
UNIT_DST="/etc/systemd/system/cloudflared.service"
RELEASES="https://github.com/cloudflare/cloudflared/releases/latest/download"

die() { echo "Error: $*" >&2; exit 1; }
info() { echo "==> $*"; }

need_root() {
  [ "$(id -u)" -eq 0 ] || die "Run this script as the root user."
}

detect_arch() {
  case "$(uname -m)" in
    aarch64 | arm64) echo "arm64" ;;
    x86_64 | amd64) echo "amd64" ;;
    armv7l | armhf) echo "arm" ;;
    *) die "The script does not support this CPU architecture: $(uname -m)" ;;
  esac
}

check_env() {
  [ -f "${ENV_FILE}" ] || die "${ENV_FILE} does not exist. Copy cloudflared.env.example to that path and set TUNNEL_TOKEN."
  # shellcheck disable=SC1090
  . "${ENV_FILE}"
  [ -n "${TUNNEL_TOKEN:-}" ] || die "TUNNEL_TOKEN is empty in ${ENV_FILE}. Set it to the token of your tunnel."
  chmod 600 "${ENV_FILE}"
}

download_binary() {
  local arch tmp
  arch="$(detect_arch)"
  tmp="$(mktemp "${DIR}/cloudflared.XXXXXX")"
  info "Downloading cloudflared (${arch})"
  if ! curl -fsSL "${RELEASES}/cloudflared-linux-${arch}" -o "${tmp}"; then
    rm -f "${tmp}"
    die "The download of cloudflared failed. Make sure that the gateway can connect to github.com."
  fi
  chmod 755 "${tmp}"
  "${tmp}" --version >/dev/null 2>&1 || { rm -f "${tmp}"; die "The cloudflared binary does not start on this device."; }
  mv -f "${tmp}" "${BIN}"
  info "Installed $("${BIN}" --version)"
}

write_unit() {
  cat >"${UNIT_SRC}" <<EOF
[Unit]
Description=Cloudflare Tunnel connector (cloudflared)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
EnvironmentFile=${ENV_FILE}
ExecStart=${BIN} --no-autoupdate tunnel run
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
}

link_unit() {
  cp -f "${UNIT_SRC}" "${UNIT_DST}"
  systemctl daemon-reload
  systemctl enable cloudflared.service >/dev/null 2>&1
}

cmd_install() {
  need_root
  [ -d /data ] || die "The /data directory does not exist. The script needs UniFi OS 2.x or later."
  mkdir -p "${DIR}"
  check_env
  [ -x "${BIN}" ] || download_binary
  write_unit
  link_unit
  systemctl restart cloudflared.service
  info "The service started. Make sure that the connector shows in the Cloudflare dashboard."
}

cmd_update() {
  need_root
  [ -d "${DIR}" ] || die "${DIR} does not exist. Run: $0 install"
  download_binary
  systemctl restart cloudflared.service
  info "The update is complete. The service restarted."
}

# This command restores the systemd unit after a firmware update.
# It downloads nothing, so you can run it at each start of the gateway.
cmd_restore() {
  need_root
  [ -x "${BIN}" ] || die "${BIN} does not exist. Run: $0 install"
  [ -f "${UNIT_SRC}" ] || write_unit
  if [ ! -f "${UNIT_DST}" ] || ! cmp -s "${UNIT_SRC}" "${UNIT_DST}"; then
    link_unit
    info "The script restored the systemd unit."
  fi
  systemctl start cloudflared.service
}

cmd_status() {
  [ -x "${BIN}" ] && "${BIN}" --version
  systemctl status cloudflared.service --no-pager || true
}

cmd_uninstall() {
  need_root
  systemctl disable --now cloudflared.service >/dev/null 2>&1 || true
  rm -f "${UNIT_DST}"
  systemctl daemon-reload
  if [ "${1:-}" = "--purge" ]; then
    rm -rf "${DIR}"
    info "The script removed the service and deleted ${DIR}."
  else
    info "The script removed the service. The files stay in ${DIR}. Add --purge to delete them."
  fi
}

case "${1:-install}" in
  install) cmd_install ;;
  update) cmd_update ;;
  restore) cmd_restore ;;
  status) cmd_status ;;
  uninstall) cmd_uninstall "${2:-}" ;;
  *) die "Unknown command: ${1}. Use install, update, restore, status, or uninstall [--purge]." ;;
esac
