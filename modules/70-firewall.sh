#!/usr/bin/env bash

detect_lan_cidr() {
  local default_interface
  default_interface="$(ip -o -4 route show to default 2>/dev/null | awk '{print $5; exit}')"
  [[ -n "$default_interface" ]] || return 0
  ip -o -4 route show dev "$default_interface" scope link 2>/dev/null |
    awk '$1 != "default" {print $1; exit}'
}

collect_firewall_configuration() {
  CONFIGURE_UFW='no'
  LAN_CIDR="$(detect_lan_cidr)"
  command -v ufw >/dev/null 2>&1 || return 0
  if [[ ! -r /etc/ufw/ufw.conf ]] || ! grep -Eq '^ENABLED=yes' /etc/ufw/ufw.conf; then
    return 0
  fi
  printf '\nUFW is active. The wizard can allow local-network access to media services.\n'
  if [[ -n "$LAN_CIDR" ]]; then
    info "Detected local network: $LAN_CIDR"
  else
    warning 'The local network range could not be detected. Firewall rules will not be changed.'
    return 0
  fi
  if ask_yes_no 'Add the required UFW rules?' yes; then
    CONFIGURE_UFW='yes'
  fi
}

allow_lan_port() {
  local port="$1"
  local protocol="$2"
  local label="$3"
  run_root ufw allow from "$LAN_CIDR" to any port "$port" proto "$protocol" comment "$label"
}

apply_firewall_configuration() {
  begin_step 'Firewall configuration' 'Only an active UFW installation is changed, and local service ports are limited to the detected LAN.'
  if [[ "$CONFIGURE_UFW" != 'yes' ]]; then
    info 'No firewall changes were selected.'
    return 0
  fi
  allow_lan_port 8096 tcp Jellyfin
  if [[ "$TRANSMISSION_PROVIDER" == 'docker' ]]; then
    allow_lan_port "$RPC_PORT" tcp Transmission-RPC
    run_root ufw allow "$PEER_PORT/tcp" comment Transmission-Peer
    run_root ufw allow "$PEER_PORT/udp" comment Transmission-Peer
  fi
  allow_lan_port 445 tcp SMB
  allow_lan_port 139 tcp SMB-NetBIOS
  allow_lan_port 137 udp SMB-NetBIOS
  allow_lan_port 138 udp SMB-NetBIOS
  success 'UFW rules were added.'
}
