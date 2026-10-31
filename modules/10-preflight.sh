#!/usr/bin/env bash

collect_preflight() {
  begin_step 'Preflight inspection' 'The wizard verifies the supported host, required commands, identity, and current service providers.'
  (( EUID != 0 )) || die 'Run this wizard as a regular user, not with sudo.'
  (( BASH_VERSINFO[0] >= 4 )) || die 'Bash 4 or newer is required.'
  [[ -r /etc/os-release ]] || die 'Cannot read /etc/os-release.'
  source /etc/os-release
  OS_ID="${ID:-unknown}"
  OS_CODENAME="${VERSION_CODENAME:-${UBUNTU_CODENAME:-unknown}}"
  OS_DESCRIPTION="${PRETTY_NAME:-$OS_ID}"
  case "$OS_ID:${ID_LIKE:-}" in
    *ubuntu*|*debian*|*raspbian*) ;;
    *) warning "This wizard is tested on Ubuntu and Debian-family systems. Detected: $OS_DESCRIPTION" ;;
  esac
  local required_command
  for required_command in awk blkid cmp cut date df findmnt getent grep hostname id ip lsblk mktemp mountpoint readlink sed ss stat systemctl tr; do
    command -v "$required_command" >/dev/null 2>&1 || die "Required command is missing: $required_command"
  done
  LOGIN_USER="${SUDO_USER:-$USER}"
  LOGIN_UID="$(id -u "$LOGIN_USER")"
  LOGIN_GID="$(id -g "$LOGIN_USER")"
  LOGIN_GROUP="$(id -gn "$LOGIN_USER")"
  SERVER_HOSTNAME="$(hostname -s 2>/dev/null || hostname)"
  PRIMARY_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
  PRIMARY_IP="${PRIMARY_IP:-<server-ip>}"
  SYSTEM_TIMEZONE="$(timedatectl show -p Timezone --value 2>/dev/null || true)"
  SYSTEM_TIMEZONE="${SYSTEM_TIMEZONE:-Etc/UTC}"
  SYSTEM_ARCH="$(dpkg --print-architecture 2>/dev/null || uname -m)"
  PI_MODEL='unknown'
  if [[ -r /proc/device-tree/model ]]; then
    PI_MODEL="$(tr -d '\0' </proc/device-tree/model)"
  fi
  case "$SYSTEM_ARCH" in
    arm64|aarch64) success "Architecture: $SYSTEM_ARCH" ;;
    *) warning "This wizard targets Raspberry Pi 4B arm64. Detected architecture: $SYSTEM_ARCH" ;;
  esac
  if [[ "$PI_MODEL" == *'Raspberry Pi 4 Model B'* ]]; then
    success "Hardware: $PI_MODEL"
  else
    warning "Raspberry Pi 4B was not detected. Hardware: $PI_MODEL"
  fi
  NATIVE_TRANSMISSION_ACTIVE='no'
  NATIVE_SAMBA_ACTIVE='no'
  service_is_active transmission-daemon.service && NATIVE_TRANSMISSION_ACTIVE='yes'
  if service_is_active smbd.service || service_is_active nmbd.service; then
    NATIVE_SAMBA_ACTIVE='yes'
  fi
  info "Login user: $LOGIN_USER ($LOGIN_UID:$LOGIN_GID)"
  info "Native Transmission active: $NATIVE_TRANSMISSION_ACTIVE"
  info "Native Samba active: $NATIVE_SAMBA_ACTIVE"
}
