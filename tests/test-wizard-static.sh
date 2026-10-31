#!/usr/bin/env bash
set -Eeuo pipefail

TEST_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
GENERATED_ROOT="$(mktemp -d)"
trap 'rm -rf -- "$GENERATED_ROOT"' EXIT

source "$TEST_ROOT/modules/00-common.sh"
source "$TEST_ROOT/modules/50-applications.sh"

COMPOSE_PROJECT_NAME='local-media-server'
LOGIN_UID='1001'
MEDIA_GID='1002'
SYSTEM_TIMEZONE='Asia/Tbilisi'
MEDIA_PATH='/mnt/media'
JELLYFIN_CONFIG_DIR='/opt/pi-media-server/jellyfin/config'
JELLYFIN_CACHE_DIR='/opt/pi-media-server/jellyfin/cache'
TRANSMISSION_CONFIG_DIR='/opt/pi-media-server/transmission/config'
TRANSMISSION_WATCH_DIR='/opt/pi-media-server/transmission/watch'
RPC_PORT='9091'
PEER_PORT='51413'
RPC_USER='transmission'
RPC_PASS='safe-password'
SAMBA_SHARE_NAME='Media'
SAMBA_PASSWORD='safe-password'
TRANSMISSION_PROVIDER='docker'
SAMBA_PROVIDER='docker'
SAMBA_MODE='authenticated-read-write'
DEPLOY_DIR='/opt/pi-media-server'
PRIMARY_IP='192.168.4.40'

mkdir -p "$GENERATED_ROOT/transmission-image"
generate_environment_file "$GENERATED_ROOT/.env"
generate_compose_file "$GENERATED_ROOT/compose.yaml"
generate_transmission_dockerfile "$GENERATED_ROOT/transmission-image/Dockerfile"
generate_operator_readme "$GENERATED_ROOT/README.txt"

bash -n "$TEST_ROOT/main.sh" "$TEST_ROOT"/modules/*.sh
grep -q '^  jellyfin:' "$GENERATED_ROOT/compose.yaml"
grep -q '^  transmission:' "$GENERATED_ROOT/compose.yaml"
grep -q '^  samba:' "$GENERATED_ROOT/compose.yaml"
grep -q 'read only = no' "$GENERATED_ROOT/compose.yaml"
grep -q '^MEDIA_PATH=/mnt/media$' "$GENERATED_ROOT/.env"
grep -q '^FROM lscr.io/linuxserver/transmission:latest$' "$GENERATED_ROOT/transmission-image/Dockerfile"
grep -q 'never formats a disk' "$TEST_ROOT/modules/00-common.sh"
grep -q 'Existing host services are never disabled without an explicit choice' "$TEST_ROOT/modules/00-common.sh"

TRANSMISSION_PROVIDER='native'
SAMBA_PROVIDER='native'
generate_compose_file "$GENERATED_ROOT/compose-native.yaml"
grep -q '^  jellyfin:' "$GENERATED_ROOT/compose-native.yaml"
if grep -q '^  transmission:' "$GENERATED_ROOT/compose-native.yaml"; then
  printf 'Native-provider Compose unexpectedly contains Transmission.\n' >&2
  exit 1
fi
if grep -q '^  samba:' "$GENERATED_ROOT/compose-native.yaml"; then
  printf 'Native-provider Compose unexpectedly contains Samba.\n' >&2
  exit 1
fi

TRANSMISSION_PROVIDER='docker'
SAMBA_PROVIDER='docker'
SAMBA_MODE='guest-read-only'
generate_compose_file "$GENERATED_ROOT/compose-guest.yaml"
grep -q 'guest ok = yes; read only = yes' "$GENERATED_ROOT/compose-guest.yaml"

if LC_ALL=C grep -RIn '[^ -~]' "$TEST_ROOT/main.sh" "$TEST_ROOT/modules" "$TEST_ROOT/tests"; then
  printf 'Non-ASCII text was found in wizard-facing files.\n' >&2
  exit 1
fi

if grep -RInE '(^|[[:space:]])(mkfs|wipefs|parted|fdisk|sfdisk)([[:space:]]|$)' "$TEST_ROOT/main.sh" "$TEST_ROOT/modules"; then
  printf 'A disk-destructive command was found in the wizard.\n' >&2
  exit 1
fi

if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
  docker compose \
    --project-directory "$GENERATED_ROOT" \
    --env-file "$GENERATED_ROOT/.env" \
    -f "$GENERATED_ROOT/compose.yaml" config >/dev/null
fi

printf 'Wizard static tests passed.\n'
