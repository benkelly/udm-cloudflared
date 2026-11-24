#!/bin/bash
# udm-cloudflared installs cloudflared on a gateway with UniFi OS 2.x or later.
# cloudflared is the connector for a Cloudflare Tunnel.
# All files stay in /data, which UniFi OS keeps during a firmware update.
#
# Usage: udm-cloudflared.sh <command>
# Commands: install, update, check, auto-update, restore, status, uninstall [--purge]

set -euo pipefail

DIR="/data/cloudflared"
BIN="${DIR}/cloudflared"
ENV_FILE="${DIR}/cloudflared.env"
UNIT_SRC="${DIR}/cloudflared.service"
SYSTEMD_DIR="/etc/systemd/system"
UNIT_DST="${SYSTEMD_DIR}/cloudflared.service"
SCRIPT="${DIR}/udm-cloudflared.sh"
UPDATE_UNITS="cloudflared-update.service cloudflared-update.timer"
LATEST="https://github.com/cloudflare/cloudflared/releases/latest"
RELEASES="${LATEST}/download"

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

installed_version() {
  "${BIN}" --version | awk '{print $3}'
}

# GitHub redirects the "latest" URL to the tag of the newest release.
latest_version() {
  local url
  url="$(curl -fsSLI -o /dev/null -w '%{url_effective}' "${LATEST}")" || return 1
  case "${url}" in
    */tag/*) echo "${url##*/}" ;;
    *) return 1 ;;
  esac
}

auto_update_enabled() {
  [ "${AUTO_UPDATE:-false}" = "true" ]
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

write_update_units() {
  cat >"${DIR}/cloudflared-update.service" <<EOF
[Unit]
Description=Update cloudflared when a newer release exists
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=${SCRIPT} auto-update
EOF
  cat >"${DIR}/cloudflared-update.timer" <<EOF
[Unit]
Description=Weekly update of cloudflared

[Timer]
OnCalendar=weekly
RandomizedDelaySec=1h
Persistent=true

[Install]
WantedBy=timers.target
EOF
}

# The timer runs only when AUTO_UPDATE=true is in the environment file.
sync_update_timer() {
  local unit
  if auto_update_enabled; then
    [ -x "${SCRIPT}" ] || die "${SCRIPT} does not exist. Copy this script to that path."
    write_update_units
    for unit in ${UPDATE_UNITS}; do
      cp -f "${DIR}/${unit}" "${SYSTEMD_DIR}/${unit}"
    done
    systemctl daemon-reload
    systemctl enable --now cloudflared-update.timer >/dev/null 2>&1 || die "The script cannot start the update timer. Run: systemctl status cloudflared-update.timer"
  else
    systemctl disable --now cloudflared-update.timer >/dev/null 2>&1 || true
    for unit in ${UPDATE_UNITS}; do
      rm -f "${SYSTEMD_DIR:?}/${unit:?}" "${DIR:?}/${unit:?}"
    done
    systemctl daemon-reload
  fi
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
  sync_update_timer
  systemctl restart cloudflared.service
  info "The service started. Make sure that the connector shows in the Cloudflare dashboard."
  if auto_update_enabled; then
    info "The weekly update is on."
  fi
}

cmd_update() {
  need_root
  [ -d "${DIR}" ] || die "${DIR} does not exist. Run: $0 install"
  download_binary
  systemctl restart cloudflared.service
  info "The update is complete. The service restarted."
}

cmd_check() {
  local installed latest
  [ -x "${BIN}" ] || die "${BIN} does not exist. Run: $0 install"
  installed="$(installed_version)"
  latest="$(latest_version)" || die "The script cannot read the latest version. Make sure that the gateway can connect to github.com."
  echo "Installed: ${installed}"
  echo "Latest:    ${latest}"
  if [ "${installed}" = "${latest}" ]; then
    info "cloudflared is up to date."
  else
    info "A newer version exists. Run: $0 update"
  fi
}

# The weekly timer runs this command. It downloads only a newer release.
cmd_auto_update() {
  local installed latest
  need_root
  [ -x "${BIN}" ] || die "${BIN} does not exist. Run: $0 install"
  installed="$(installed_version)"
  latest="$(latest_version)" || die "The script cannot read the latest version. Make sure that the gateway can connect to github.com."
  if [ "${installed}" = "${latest}" ]; then
    info "cloudflared ${installed} is up to date."
    return 0
  fi
  info "Updating cloudflared from ${installed} to ${latest}"
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
  if [ -f "${ENV_FILE}" ]; then
    # shellcheck disable=SC1090
    . "${ENV_FILE}"
  fi
  sync_update_timer
  systemctl start cloudflared.service
}

cmd_status() {
  [ -x "${BIN}" ] && "${BIN}" --version
  systemctl status cloudflared.service --no-pager || true
  if [ -f "${SYSTEMD_DIR}/cloudflared-update.timer" ]; then
    systemctl list-timers cloudflared-update.timer --no-pager || true
  fi
}

cmd_uninstall() {
  need_root
  local unit
  systemctl disable --now cloudflared-update.timer >/dev/null 2>&1 || true
  systemctl disable --now cloudflared.service >/dev/null 2>&1 || true
  rm -f "${UNIT_DST}"
  for unit in ${UPDATE_UNITS}; do
    rm -f "${SYSTEMD_DIR:?}/${unit:?}"
  done
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
  check) cmd_check ;;
  auto-update) cmd_auto_update ;;
  restore) cmd_restore ;;
  status) cmd_status ;;
  uninstall) cmd_uninstall "${2:-}" ;;
  *) die "Unknown command: ${1}. Use install, update, check, auto-update, restore, status, or uninstall [--purge]." ;;
esac
