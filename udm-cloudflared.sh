#!/bin/bash
# udm-cloudflared installs cloudflared on a gateway with UniFi OS 2.x or later.
# cloudflared is the connector for a Cloudflare Tunnel.
# All files stay in /data, which UniFi OS keeps during a firmware update.
#
# Usage: udm-cloudflared.sh <command>
# Commands: install, update, check, auto-update, self-update, restore, status,
# version, uninstall [--purge]

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
SCRIPT_VERSION="0.1.0"
SCRIPT_REPO="benkelly/udm-cloudflared"
SCRIPT_LATEST="https://github.com/${SCRIPT_REPO}/releases/latest"
SCRIPT_RAW="https://raw.githubusercontent.com/${SCRIPT_REPO}"

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

# Prints the tag of the newest release of this script, for example v0.2.0.
latest_script_tag() {
  local url
  url="$(curl -fsSLI -o /dev/null -w '%{url_effective}' "${SCRIPT_LATEST}")" || return 1
  case "${url}" in
    */tag/v[0-9]*) echo "${url##*/}" ;;
    *) return 1 ;;
  esac
}

# Returns 0 only if version $1 is newer than version $2.
version_newer() {
  [ "$1" != "$2" ] && [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -n 1)" = "$1" ]
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
    systemctl enable --now cloudflared-update.timer >/dev/null 2>&1
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
  check_script
}

check_script() {
  local tag
  echo "Script installed: ${SCRIPT_VERSION}"
  if ! tag="$(latest_script_tag)"; then
    echo "Script latest:    not found"
    return 0
  fi
  echo "Script latest:    ${tag#v}"
  if version_newer "${tag#v}" "${SCRIPT_VERSION}"; then
    info "A newer script exists. Run: $0 self-update"
  else
    info "The script is up to date."
  fi
}

# This command replaces the script with the newest release. Only you run it.
cmd_self_update() {
  local tag tmp
  need_root
  [ -d "${DIR}" ] || die "${DIR} does not exist. Run: $0 install"
  tag="$(latest_script_tag)" || die "The script cannot find a release. Make sure that the gateway can connect to github.com."
  if ! version_newer "${tag#v}" "${SCRIPT_VERSION}"; then
    info "The script ${SCRIPT_VERSION} is up to date."
    return 0
  fi
  tmp="$(mktemp "${DIR}/udm-cloudflared.XXXXXX")"
  info "Downloading the script ${tag}"
  if ! curl -fsSL "${SCRIPT_RAW}/${tag}/udm-cloudflared.sh" -o "${tmp}"; then
    rm -f "${tmp:?}"
    die "The download of the script failed."
  fi
  if ! bash -n "${tmp}" 2>/dev/null || ! grep -q "^SCRIPT_VERSION=\"${tag#v}\"$" "${tmp}"; then
    rm -f "${tmp:?}"
    die "The new script is not valid. The old script stays in place."
  fi
  chmod 755 "${tmp}"
  mv -f "${tmp}" "${SCRIPT}"
  info "The script is now version ${tag#v}. Run: ${SCRIPT} install"
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
  self-update) cmd_self_update ;;
  version) echo "${SCRIPT_VERSION}" ;;
  restore) cmd_restore ;;
  status) cmd_status ;;
  uninstall) cmd_uninstall "${2:-}" ;;
  *) die "Unknown command: ${1}. Use install, update, check, auto-update, self-update, restore, status, version, or uninstall [--purge]." ;;
esac
