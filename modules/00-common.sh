#!/usr/bin/env bash

WIZARD_VERSION='2.0.0'
DRY_RUN=0
SHOW_HELP=0
SHOW_STEPS=0
SHOW_VERSION=0
CURRENT_STEP='startup'
TEMP_ROOT=''
APT_UPDATED=0
RUN_TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
COLOR_RESET=''
COLOR_BOLD=''
COLOR_BLUE=''
COLOR_GREEN=''
COLOR_YELLOW=''
COLOR_RED=''

initialize_colors() {
  if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
    COLOR_RESET=$'\033[0m'
    COLOR_BOLD=$'\033[1m'
    COLOR_BLUE=$'\033[34m'
    COLOR_GREEN=$'\033[32m'
    COLOR_YELLOW=$'\033[33m'
    COLOR_RED=$'\033[31m'
  fi
}

info() {
  printf '%b[INFO]%b %s\n' "$COLOR_BLUE" "$COLOR_RESET" "$*"
}

success() {
  printf '%b[ OK ]%b %s\n' "$COLOR_GREEN" "$COLOR_RESET" "$*"
}

warning() {
  printf '%b[WARN]%b %s\n' "$COLOR_YELLOW" "$COLOR_RESET" "$*"
}

failure() {
  printf '%b[FAIL]%b %s\n' "$COLOR_RED" "$COLOR_RESET" "$*" >&2
}

die() {
  failure "$*"
  exit 1
}

begin_step() {
  CURRENT_STEP="$1"
  printf '\n%bStep: %s%b\n' "$COLOR_BOLD" "$1" "$COLOR_RESET"
  printf '%s\n' "$2"
}

print_command() {
  local argument
  printf '  '
  for argument in "$@"; do
    printf '%q ' "$argument"
  done
  printf '\n'
}

run_command() {
  if (( DRY_RUN )); then
    info 'Dry run command:'
    print_command "$@"
    return 0
  fi
  "$@"
}

run_root() {
  if (( DRY_RUN )); then
    info 'Dry run privileged command:'
    if (( EUID == 0 )); then
      print_command "$@"
    else
      print_command sudo "$@"
    fi
    return 0
  fi
  if (( EUID == 0 )); then
    "$@"
  else
    sudo "$@"
  fi
}

cleanup_runtime() {
  if [[ -n "$TEMP_ROOT" && -d "$TEMP_ROOT" ]]; then
    rm -rf -- "$TEMP_ROOT"
  fi
}

handle_runtime_error() {
  local exit_code=$?
  failure "The wizard failed during: $CURRENT_STEP"
  failure "Review the error above. Existing backups use timestamp $RUN_TIMESTAMP."
  exit "$exit_code"
}

initialize_runtime() {
  initialize_colors
  [[ -t 0 ]] || die 'This wizard requires an interactive terminal.'
  TEMP_ROOT="$(mktemp -d)"
  trap cleanup_runtime EXIT
  trap handle_runtime_error ERR
}

parse_arguments() {
  while (($#)); do
    case "$1" in
      --dry-run) DRY_RUN=1 ;;
      --help|-h) SHOW_HELP=1 ;;
      --list-steps) SHOW_STEPS=1 ;;
      --version) SHOW_VERSION=1 ;;
      *) die "Unknown option: $1. Use --help for usage." ;;
    esac
    shift
  done
}

print_help() {
  cat <<'EOF'
Pi 4B Media Server Wizard

Usage:
  ./main.sh
  ./main.sh --dry-run
  ./main.sh --list-steps
  ./main.sh --help

Options:
  --dry-run     Collect choices and print planned commands without changing the host.
  --list-steps  Show the configuration stages and exit.
  --version     Print the wizard version and exit.
  --help        Show this help and exit.

Run this wizard as a regular user with sudo access. It never formats a disk and
never deletes media files. Existing configuration files are backed up before
replacement.
EOF
}

print_steps() {
  cat <<'EOF'
1. Preflight: inspect the operating system, Raspberry Pi model, and active services.
2. Storage: select or reuse a filesystem and persist its UUID in /etc/fstab.
3. Permissions: configure the media group and inherited filesystem ACLs.
4. Docker: install or validate Docker Engine and Docker Compose v2.
5. Applications: deploy Jellyfin and the selected Transmission and Samba providers.
6. Startup: make every selected service wait for the media mount.
7. Firewall: optionally add UFW rules for the selected services.
8. Verification: verify the mount, Compose project, services, ports, and health.
EOF
}

handle_information_request() {
  if (( SHOW_HELP )); then
    print_help
    exit 0
  fi
  if (( SHOW_STEPS )); then
    print_steps
    exit 0
  fi
  if (( SHOW_VERSION )); then
    printf '%s\n' "$WIZARD_VERSION"
    exit 0
  fi
}

print_welcome() {
  cat <<'EOF'

Pi 4B Media Server Wizard
=========================

This wizard builds a reproducible media server around one host-mounted media
filesystem. Jellyfin runs in Docker. Transmission and Samba can remain as
existing host services or move to Docker after an explicit choice.

Safety rules:
  - No disk is formatted.
  - No media file is deleted.
  - Existing configuration files are backed up before replacement.
  - Existing host services are never disabled without an explicit choice.
  - A dry run prints changes without applying them.
EOF
  if (( DRY_RUN )); then
    warning 'Dry-run mode is active. The host will not be changed.'
  fi
}

prompt_default() {
  local prompt="$1"
  local default_value="$2"
  local answer=''
  read -r -p "$prompt [$default_value]: " answer
  printf '%s' "${answer:-$default_value}"
}

ask_yes_no() {
  local prompt="$1"
  local default_answer="${2:-yes}"
  local answer=''
  local suffix='[y/N]'
  [[ "$default_answer" == 'yes' ]] && suffix='[Y/n]'
  while true; do
    read -r -p "$prompt $suffix " answer
    answer="${answer:-$default_answer}"
    case "$answer" in
      y|Y|yes|YES|Yes) return 0 ;;
      n|N|no|NO|No) return 1 ;;
      *) warning 'Please answer yes or no.' ;;
    esac
  done
}

choose_number() {
  local prompt="$1"
  local default_choice="$2"
  local maximum="$3"
  local answer=''
  while true; do
    read -r -p "$prompt [$default_choice]: " answer
    answer="${answer:-$default_choice}"
    if [[ "$answer" =~ ^[0-9]+$ ]] && (( answer >= 1 && answer <= maximum )); then
      printf '%s' "$answer"
      return 0
    fi
    warning "Enter a number from 1 to $maximum."
  done
}

validate_absolute_path() {
  [[ "$1" =~ ^/[A-Za-z0-9._/+:-]+$ ]]
}

validate_simple_value() {
  [[ "$1" =~ ^[A-Za-z0-9._@%+=,:/-]*$ ]]
}

validate_name() {
  [[ "$1" =~ ^[A-Za-z0-9._-]+$ ]]
}

validate_port() {
  [[ "$1" =~ ^[0-9]+$ ]] && (( 10#$1 >= 1 && 10#$1 <= 65535 ))
}

port_is_listening() {
  local port="$1"
  ss -H -lnt 2>/dev/null | grep -Eq "(^|[.:])${port}[[:space:]]"
}

prompt_port() {
  local label="$1"
  local default_port="$2"
  local expected_conflict="${3:-no}"
  local port=''
  while true; do
    port="$(prompt_default "$label" "$default_port")"
    validate_port "$port" || {
      warning 'Enter a port number from 1 to 65535.'
      continue
    }
    if port_is_listening "$port" && [[ "$expected_conflict" != 'yes' ]]; then
      warning "Port $port is already listening."
      ask_yes_no 'Use this port anyway?' no || continue
    fi
    printf '%s' "$port"
    return 0
  done
}

service_is_active() {
  systemctl is-active --quiet "$1" 2>/dev/null
}

service_is_installed() {
  systemctl cat "$1" >/dev/null 2>&1
}

open_sudo_session() {
  if (( DRY_RUN )); then
    return 0
  fi
  command -v sudo >/dev/null 2>&1 || die 'sudo is required.'
  info 'Opening a sudo session for host-level changes.'
  sudo -v
}

install_root_file() {
  local source_path="$1"
  local target_path="$2"
  local mode="$3"
  local owner="$4"
  local group="$5"
  local backup_path="${target_path}.backup.${RUN_TIMESTAMP}"
  if (( DRY_RUN )); then
    info "Would install $target_path with mode $mode and owner $owner:$group."
    return 0
  fi
  if sudo test -e "$target_path"; then
    if sudo cmp -s -- "$source_path" "$target_path"; then
      sudo chown "$owner:$group" "$target_path"
      sudo chmod "$mode" "$target_path"
      success "Already current: $target_path"
      return 0
    fi
    sudo cp -a -- "$target_path" "$backup_path"
    success "Backup created: $backup_path"
  fi
  sudo install -D -m "$mode" -o "$owner" -g "$group" -- "$source_path" "$target_path"
}

ensure_apt_packages() {
  local package
  local missing_packages=()
  for package in "$@"; do
    if ! dpkg-query -W -f='${Status}' "$package" 2>/dev/null | grep -q 'install ok installed'; then
      missing_packages+=("$package")
    fi
  done
  ((${#missing_packages[@]} > 0)) || return 0
  if (( DRY_RUN )); then
    info "Would install packages: ${missing_packages[*]}"
    return 0
  fi
  if (( ! APT_UPDATED )); then
    sudo apt-get update
    APT_UPDATED=1
  fi
  sudo apt-get install -y "${missing_packages[@]}"
}

print_configuration_plan() {
  printf '\n%bConfiguration plan%b\n' "$COLOR_BOLD" "$COLOR_RESET"
  printf '  Host:                 %s (%s)\n' "$SERVER_HOSTNAME" "$PRIMARY_IP"
  printf '  Operating system:     %s\n' "$OS_DESCRIPTION"
  printf '  Media filesystem:     %s (%s, UUID %s)\n' "$DEVICE" "$FSTYPE" "$DISK_UUID"
  printf '  Media mount:          %s\n' "$MEDIA_PATH"
  printf '  Deployment directory: %s\n' "$DEPLOY_DIR"
  printf '  Runtime identity:      %s:%s (%s:%s)\n' "$LOGIN_UID" "$MEDIA_GID" "$LOGIN_USER" "$MEDIA_GROUP"
  printf '  Jellyfin config:       %s\n' "$JELLYFIN_CONFIG_DIR"
  printf '  Jellyfin cache:        %s\n' "$JELLYFIN_CACHE_DIR"
  printf '  Jellyfin:             Docker on port 8096\n'
  printf '  Transmission:         %s\n' "$TRANSMISSION_PROVIDER"
  printf '  Samba:                %s\n' "$SAMBA_PROVIDER"
  printf '  Recursive media ACL:  %s\n' "$APPLY_RECURSIVE_ACL"
  printf '  UFW changes:          %s\n' "$CONFIGURE_UFW"
  if [[ "$TRANSMISSION_PROVIDER" == 'docker' ]]; then
    printf '  Transmission RPC:     port %s\n' "$RPC_PORT"
    printf '  Transmission peer:    port %s TCP/UDP\n' "$PEER_PORT"
    if [[ -n "$RPC_USER" ]]; then
      printf '  Transmission auth:    enabled\n'
    else
      printf '  Transmission auth:    disabled\n'
    fi
  fi
  if [[ "$SAMBA_PROVIDER" == 'docker' ]]; then
    printf '  Samba access:          %s\n' "$SAMBA_MODE"
  fi
  if [[ "$DISABLE_NATIVE_TRANSMISSION" == 'yes' ]]; then
    printf '  Native service change: disable transmission-daemon\n'
  fi
  if [[ "$DISABLE_NATIVE_SAMBA" == 'yes' ]]; then
    printf '  Native service change: disable smbd and nmbd\n'
  fi
  printf '\nThe wizard will not format %s or delete files below %s.\n' "$DEVICE" "$MEDIA_PATH"
}

confirm_execution() {
  local prompt='Apply this configuration?'
  (( DRY_RUN )) && prompt='Print the complete dry-run execution?'
  ask_yes_no "$prompt" yes || die 'Cancelled by the user.'
}
