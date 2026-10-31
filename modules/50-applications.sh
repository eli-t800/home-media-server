#!/usr/bin/env bash

docker_readonly_available() {
  docker info >/dev/null 2>&1 || sudo -n docker info >/dev/null 2>&1
}

docker_readonly() {
  if docker info >/dev/null 2>&1; then
    docker "$@"
  else
    sudo -n docker "$@"
  fi
}

discover_service_container() {
  local service_name="$1"
  docker_readonly ps -aq --filter "label=com.docker.compose.service=${service_name}" 2>/dev/null | head -n1
}

discover_compose_label() {
  local service_name="$1"
  local label_name="$2"
  local container_id
  container_id="$(discover_service_container "$service_name")"
  [[ -n "$container_id" ]] || return 0
  docker_readonly inspect -f "{{index .Config.Labels \"${label_name}\"}}" "$container_id" 2>/dev/null || true
}

discover_bind_source() {
  local service_name="$1"
  local destination="$2"
  local container_id
  container_id="$(discover_service_container "$service_name")"
  [[ -n "$container_id" ]] || return 0
  docker_readonly inspect -f '{{range .Mounts}}{{println .Type "|" .Source "|" .Destination}}{{end}}' "$container_id" 2>/dev/null |
    awk -F ' \| ' -v destination="$destination" '$1 == "bind" && $3 == destination { print $2; exit }'
}

collect_existing_application_state() {
  EXISTING_COMPOSE_AVAILABLE='no'
  EXISTING_DOCKER_SAMBA='no'
  EXISTING_DOCKER_TRANSMISSION='no'
  local discovered_deploy=''
  local discovered_project=''
  local discovered_jellyfin_config=''
  local discovered_jellyfin_cache=''
  local discovered_transmission_config=''
  local discovered_transmission_watch=''
  if command -v docker >/dev/null 2>&1 && docker_readonly_available; then
    discovered_deploy="$(discover_compose_label jellyfin com.docker.compose.project.working_dir)"
    discovered_project="$(discover_compose_label jellyfin com.docker.compose.project)"
    discovered_jellyfin_config="$(discover_bind_source jellyfin /config)"
    discovered_jellyfin_cache="$(discover_bind_source jellyfin /cache)"
    discovered_transmission_config="$(discover_bind_source transmission /config)"
    discovered_transmission_watch="$(discover_bind_source transmission /watch)"
    [[ -n "$(discover_service_container samba)" ]] && EXISTING_DOCKER_SAMBA='yes'
    [[ -n "$(discover_service_container transmission)" ]] && EXISTING_DOCKER_TRANSMISSION='yes'
  fi
  DEFAULT_DEPLOY_DIR="${discovered_deploy:-/opt/pi-media-server}"
  DEFAULT_PROJECT_NAME="${discovered_project:-local-media-server}"
  DISCOVERED_JELLYFIN_CONFIG="$discovered_jellyfin_config"
  DISCOVERED_JELLYFIN_CACHE="$discovered_jellyfin_cache"
  DISCOVERED_TRANSMISSION_CONFIG="$discovered_transmission_config"
  DISCOVERED_TRANSMISSION_WATCH="$discovered_transmission_watch"
  if [[ -f "$DEFAULT_DEPLOY_DIR/compose.yaml" ]]; then
    EXISTING_COMPOSE_AVAILABLE='yes'
  fi
}

choose_transmission_provider() {
  if [[ "$NATIVE_TRANSMISSION_ACTIVE" == 'yes' ]]; then
    printf '\nNative transmission-daemon is active. Its torrent state is not migrated automatically.\n'
    printf '  1) Keep the native service and its existing state (recommended on this host)\n'
    printf '  2) Disable the native service and deploy Transmission in Docker\n'
    local choice
    choice="$(choose_number 'Choose the Transmission provider' 1 2)"
    if [[ "$choice" == '1' ]]; then
      TRANSMISSION_PROVIDER='native'
    else
      TRANSMISSION_PROVIDER='docker'
      DISABLE_NATIVE_TRANSMISSION='yes'
    fi
  else
    TRANSMISSION_PROVIDER='docker'
  fi
}

choose_samba_provider() {
  if [[ "$NATIVE_SAMBA_ACTIVE" == 'yes' ]]; then
    printf '\nNative Samba is active. Existing shares may contain custom paths and access rules.\n'
    printf '  1) Keep native Samba and preserve its existing shares (recommended on this host)\n'
    printf '  2) Disable native Samba and deploy one Docker-managed Media share\n'
    local choice
    choice="$(choose_number 'Choose the Samba provider' 1 2)"
    if [[ "$choice" == '1' ]]; then
      SAMBA_PROVIDER='native'
    else
      SAMBA_PROVIDER='docker'
      DISABLE_NATIVE_SAMBA='yes'
    fi
  else
    SAMBA_PROVIDER='docker'
  fi
}

collect_transmission_settings() {
  RPC_PORT='9091'
  PEER_PORT='51413'
  RPC_USER=''
  RPC_PASS=''
  [[ "$TRANSMISSION_PROVIDER" == 'docker' ]] || return 0
  local expected_conflict='no'
  [[ "$DISABLE_NATIVE_TRANSMISSION" == 'yes' ]] && expected_conflict='yes'
  RPC_PORT="$(prompt_port 'Transmission Web UI port' 9091 "$expected_conflict")"
  PEER_PORT="$(prompt_port 'Transmission peer port' 51413 "$expected_conflict")"
  if ask_yes_no 'Protect the Transmission Web UI with a username and password?' yes; then
    RPC_USER="$(prompt_default 'Transmission username' 'transmission')"
    validate_simple_value "$RPC_USER" && [[ -n "$RPC_USER" ]] || die 'Use letters, numbers, and ._@%+=,:/- for the username.'
    while true; do
      read -r -s -p 'Transmission password: ' RPC_PASS
      printf '\n'
      if [[ ${#RPC_PASS} -lt 8 ]]; then
        warning 'Use at least 8 characters.'
        continue
      fi
      validate_simple_value "$RPC_PASS" || {
        warning 'Use letters, numbers, and ._@%+=,:/- for the password.'
        continue
      }
      break
    done
  else
    warning 'Transmission will be available without authentication on every interface.'
  fi
}

collect_samba_settings() {
  SAMBA_MODE='guest-read-only'
  SAMBA_PASSWORD=''
  SAMBA_SHARE_NAME='Media'
  [[ "$SAMBA_PROVIDER" == 'docker' ]] || return 0
  SAMBA_SHARE_NAME="$(prompt_default 'SMB share name' 'Media')"
  validate_name "$SAMBA_SHARE_NAME" || die 'The SMB share name may contain only letters, numbers, dot, underscore, and hyphen.'
  printf '\nDocker Samba access mode:\n'
  printf '  1) Guest read-only access (recommended for playback devices)\n'
  printf '  2) Username and password with read-write access\n'
  local choice
  choice="$(choose_number 'Choose the SMB access mode' 1 2)"
  if [[ "$choice" == '2' ]]; then
    SAMBA_MODE='authenticated-read-write'
    while true; do
      read -r -s -p 'SMB password for user media: ' SAMBA_PASSWORD
      printf '\n'
      if [[ ${#SAMBA_PASSWORD} -lt 8 ]]; then
        warning 'Use at least 8 characters.'
        continue
      fi
      validate_simple_value "$SAMBA_PASSWORD" || {
        warning 'Use letters, numbers, and ._@%+=,:/- for the password.'
        continue
      }
      break
    done
  fi
}

collect_application_configuration() {
  begin_step 'Application choices' 'The wizard preserves existing service providers by default and only migrates them after an explicit choice.'
  DISABLE_NATIVE_TRANSMISSION='no'
  DISABLE_NATIVE_SAMBA='no'
  collect_existing_application_state
  DEPLOY_DIR="$(prompt_default 'Docker deployment directory' "$DEFAULT_DEPLOY_DIR")"
  validate_absolute_path "$DEPLOY_DIR" || die 'Use an absolute deployment path without spaces.'
  COMPOSE_PROJECT_NAME="$(prompt_default 'Compose project name' "$DEFAULT_PROJECT_NAME")"
  validate_name "$COMPOSE_PROJECT_NAME" || die 'The Compose project name may contain only letters, numbers, dot, underscore, and hyphen.'
  local jellyfin_config_default="${DISCOVERED_JELLYFIN_CONFIG:-$DEPLOY_DIR/jellyfin/config}"
  local jellyfin_cache_default="${DISCOVERED_JELLYFIN_CACHE:-$DEPLOY_DIR/jellyfin/cache}"
  JELLYFIN_CONFIG_DIR="$(prompt_default 'Jellyfin configuration directory' "$jellyfin_config_default")"
  JELLYFIN_CACHE_DIR="$(prompt_default 'Jellyfin cache directory' "$jellyfin_cache_default")"
  validate_absolute_path "$JELLYFIN_CONFIG_DIR" || die 'Use an absolute Jellyfin configuration path without spaces.'
  validate_absolute_path "$JELLYFIN_CACHE_DIR" || die 'Use an absolute Jellyfin cache path without spaces.'
  choose_transmission_provider
  choose_samba_provider
  local transmission_config_default="${DISCOVERED_TRANSMISSION_CONFIG:-$DEPLOY_DIR/transmission/config}"
  local transmission_watch_default="${DISCOVERED_TRANSMISSION_WATCH:-$DEPLOY_DIR/transmission/watch}"
  TRANSMISSION_CONFIG_DIR="$transmission_config_default"
  TRANSMISSION_WATCH_DIR="$transmission_watch_default"
  if [[ "$TRANSMISSION_PROVIDER" == 'docker' ]]; then
    TRANSMISSION_CONFIG_DIR="$(prompt_default 'Transmission configuration directory' "$transmission_config_default")"
    TRANSMISSION_WATCH_DIR="$(prompt_default 'Transmission watch directory' "$transmission_watch_default")"
    validate_absolute_path "$TRANSMISSION_CONFIG_DIR" || die 'Use an absolute Transmission configuration path without spaces.'
    validate_absolute_path "$TRANSMISSION_WATCH_DIR" || die 'Use an absolute Transmission watch path without spaces.'
  fi
  collect_transmission_settings
  collect_samba_settings
}

generate_environment_file() {
  local output_path="$1"
  cat >"$output_path" <<EOF
COMPOSE_PROJECT_NAME=$COMPOSE_PROJECT_NAME
PUID=$LOGIN_UID
PGID=$MEDIA_GID
TZ=$SYSTEM_TIMEZONE
MEDIA_PATH=$MEDIA_PATH
JELLYFIN_CONFIG_PATH=$JELLYFIN_CONFIG_DIR
JELLYFIN_CACHE_PATH=$JELLYFIN_CACHE_DIR
TRANSMISSION_CONFIG_PATH=$TRANSMISSION_CONFIG_DIR
TRANSMISSION_WATCH_PATH=$TRANSMISSION_WATCH_DIR
RPC_PORT=$RPC_PORT
PEER_PORT=$PEER_PORT
RPC_USER=$RPC_USER
RPC_PASS=$RPC_PASS
SAMBA_SHARE_NAME=$SAMBA_SHARE_NAME
SAMBA_PASSWORD=$SAMBA_PASSWORD
TRGUING_REFRESH=0
EOF
  chmod 600 "$output_path"
}

generate_compose_file() {
  local output_path="$1"
  cat >"$output_path" <<'EOF'
name: "${COMPOSE_PROJECT_NAME}"

services:
  jellyfin:
    image: jellyfin/jellyfin:latest
    container_name: jellyfin
    user: "${PUID}:${PGID}"
    init: true
    network_mode: host
    restart: unless-stopped
    environment:
      TZ: "${TZ}"
    volumes:
      - type: bind
        source: "${JELLYFIN_CONFIG_PATH}"
        target: /config
      - type: bind
        source: "${JELLYFIN_CACHE_PATH}"
        target: /cache
      - type: bind
        source: "${MEDIA_PATH}"
        target: /media
        read_only: true
EOF
  if [[ "$TRANSMISSION_PROVIDER" == 'docker' ]]; then
    cat >>"$output_path" <<'EOF'

  transmission:
    image: pi-media-server-transmission:local
    build:
      context: ./transmission-image
      args:
        TRGUING_REFRESH: "${TRGUING_REFRESH}"
    container_name: transmission
    restart: unless-stopped
    environment:
      PUID: "${PUID}"
      PGID: "${PGID}"
      TZ: "${TZ}"
      UMASK: "002"
      USER: "${RPC_USER}"
      PASS: "${RPC_PASS}"
      WHITELIST: ""
      HOST_WHITELIST: ""
      PEERPORT: "${PEER_PORT}"
    volumes:
      - type: bind
        source: "${TRANSMISSION_CONFIG_PATH}"
        target: /config
      - type: bind
        source: "${MEDIA_PATH}"
        target: /downloads
      - type: bind
        source: "${TRANSMISSION_WATCH_PATH}"
        target: /watch
    ports:
      - "${RPC_PORT}:9091"
      - "${PEER_PORT}:${PEER_PORT}/tcp"
      - "${PEER_PORT}:${PEER_PORT}/udp"
EOF
  fi
  if [[ "$SAMBA_PROVIDER" == 'docker' && "$SAMBA_MODE" == 'guest-read-only' ]]; then
    cat >>"$output_path" <<'EOF'

  samba:
    image: ghcr.io/servercontainers/samba:smbd-only-latest
    container_name: samba
    network_mode: host
    restart: unless-stopped
    environment:
      AVAHI_DISABLE: "1"
      WSDD2_DISABLE: "1"
      NETBIOS_DISABLE: "0"
      SAMBA_VOLUME_CONFIG_media: "[${SAMBA_SHARE_NAME}]; path=/shares/media; guest ok = yes; read only = yes; browseable = yes"
    volumes:
      - type: bind
        source: "${MEDIA_PATH}"
        target: /shares/media
        read_only: true
EOF
  elif [[ "$SAMBA_PROVIDER" == 'docker' ]]; then
    cat >>"$output_path" <<'EOF'

  samba:
    image: ghcr.io/servercontainers/samba:smbd-only-latest
    container_name: samba
    network_mode: host
    restart: unless-stopped
    environment:
      AVAHI_DISABLE: "1"
      WSDD2_DISABLE: "1"
      NETBIOS_DISABLE: "0"
      ACCOUNT_media: "${SAMBA_PASSWORD}"
      UID_media: "${PUID}"
      GROUP_media: "${PGID}"
      GROUPS_media: "media"
      SAMBA_VOLUME_CONFIG_media: "[${SAMBA_SHARE_NAME}]; path=/shares/media; valid users = media; guest ok = no; read only = no; browseable = yes; force user = media; force group = media; create mask = 0664; directory mask = 2775"
    volumes:
      - type: bind
        source: "${MEDIA_PATH}"
        target: /shares/media
EOF
  fi
}

generate_transmission_dockerfile() {
  local output_path="$1"
  cat >"$output_path" <<'EOF'
# syntax=docker/dockerfile:1.7
FROM alpine:3.22 AS trguing
ARG TRGUING_REFRESH=0
RUN apk add --no-cache ca-certificates curl jq unzip
RUN set -eux; \
    echo "TrguiNG refresh token: ${TRGUING_REFRESH}"; \
    curl -fsSL -H 'Accept: application/vnd.github+json' -H 'User-Agent: pi-media-server-wizard' https://api.github.com/repos/openscopeproject/TrguiNG/releases/latest -o /tmp/release.json; \
    url="$(jq -r '.assets[] | select(.name | test("^trguing-web-.*\\.zip$")) | .browser_download_url' /tmp/release.json | head -n1)"; \
    test -n "$url" -a "$url" != "null"; \
    curl -fL "$url" -o /tmp/trguing.zip; \
    mkdir -p /tmp/extracted /out; \
    unzip -q /tmp/trguing.zip -d /tmp/extracted; \
    index="$(find /tmp/extracted -type f -name index.html -print -quit)"; \
    test -n "$index"; \
    cp -a "$(dirname "$index")"/. /out/

FROM lscr.io/linuxserver/transmission:latest
USER root
RUN apk add --no-cache curl
COPY --from=trguing /out/ /opt/trguing/
ENV TRANSMISSION_WEB_HOME=/opt/trguing
EXPOSE 9091/tcp 51413/tcp 51413/udp
HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 CMD code="$(curl -sS -o /dev/null -w '%{http_code}' http://127.0.0.1:9091/transmission/rpc || true)"; case "$code" in 200|401|409) exit 0 ;; *) exit 1 ;; esac
EOF
}

generate_operator_readme() {
  local output_path="$1"
  cat >"$output_path" <<EOF
Pi 4B Media Server
==================

Deployment directory: $DEPLOY_DIR
Media mount:          $MEDIA_PATH
Jellyfin:             http://$PRIMARY_IP:8096
Transmission provider: $TRANSMISSION_PROVIDER
Samba provider:        $SAMBA_PROVIDER

Jellyfin first run:
  1. Open the Jellyfin URL.
  2. Complete the first-run setup.
  3. Add /media as the library path.
  4. Prefer Direct Play on Raspberry Pi 4B.

Docker operations:
  cd $DEPLOY_DIR
  docker compose ps
  docker compose logs -f jellyfin
  docker compose pull jellyfin
  docker compose up -d
EOF
  if [[ "$TRANSMISSION_PROVIDER" == 'docker' ]]; then
    cat >>"$output_path" <<EOF

Transmission in Docker:
  http://$PRIMARY_IP:$RPC_PORT/transmission/web/
  Host media paths appear below /downloads inside Transmission.
  Update with: docker compose build --pull transmission && docker compose up -d
EOF
  else
    cat >>"$output_path" <<'EOF'

Native Transmission:
  systemctl status transmission-daemon
  The wizard preserved its existing settings and torrent state.
EOF
  fi
  if [[ "$SAMBA_PROVIDER" == 'docker' ]]; then
    cat >>"$output_path" <<EOF

SMB in Docker:
  smb://$PRIMARY_IP/$SAMBA_SHARE_NAME
  Update with: docker compose pull samba && docker compose up -d
EOF
  else
    cat >>"$output_path" <<'EOF'

Native Samba:
  systemctl status smbd nmbd
  The wizard preserved the existing shares in /etc/samba/smb.conf.
EOF
  fi
  cat >>"$output_path" <<EOF

No media disk was formatted by the wizard. Configuration backups use the
suffix .backup.$RUN_TIMESTAMP.
EOF
  chmod 644 "$output_path"
}

existing_compose_has_service() {
  local service_name="$1"
  [[ -f "$DEPLOY_DIR/compose.yaml" ]] || return 1
  docker_execute compose --project-directory "$DEPLOY_DIR" -f "$DEPLOY_DIR/compose.yaml" config --services 2>/dev/null |
    grep -qx "$service_name"
}

stop_existing_compose_service() {
  local service_name="$1"
  if existing_compose_has_service "$service_name"; then
    warning "Stopping the existing Docker $service_name service because the native provider was selected."
    docker_execute compose --project-directory "$DEPLOY_DIR" -f "$DEPLOY_DIR/compose.yaml" stop "$service_name"
  fi
}

stop_docker_services_for_native_providers() {
  if [[ "$TRANSMISSION_PROVIDER" == 'native' ]]; then
    stop_existing_compose_service transmission
  fi
  if [[ "$SAMBA_PROVIDER" == 'native' ]]; then
    stop_existing_compose_service samba
  fi
}

disable_native_services_for_docker_providers() {
  if [[ "$DISABLE_NATIVE_TRANSMISSION" == 'yes' ]]; then
    run_root systemctl disable --now transmission-daemon.service
  fi
  if [[ "$DISABLE_NATIVE_SAMBA" == 'yes' ]]; then
    service_is_installed smbd.service && run_root systemctl disable --now smbd.service
    service_is_installed nmbd.service && run_root systemctl disable --now nmbd.service
  fi
}

restore_native_services_after_failure() {
  if [[ "$DISABLE_NATIVE_TRANSMISSION" == 'yes' ]]; then
    sudo systemctl enable --now transmission-daemon.service || true
  fi
  if [[ "$DISABLE_NATIVE_SAMBA" == 'yes' ]]; then
    service_is_installed smbd.service && sudo systemctl enable --now smbd.service || true
    service_is_installed nmbd.service && sudo systemctl enable --now nmbd.service || true
  fi
}

apply_application_configuration() {
  begin_step 'Application deployment' 'The wizard validates generated files, preserves existing configuration, and starts the selected Compose services.'
  if (( DRY_RUN )); then
    info "Would back up and update the Compose project in $DEPLOY_DIR."
    info "Would keep Transmission provider: $TRANSMISSION_PROVIDER."
    info "Would keep Samba provider: $SAMBA_PROVIDER."
    return 0
  fi
  MEDIA_GID="$(getent group "$MEDIA_GROUP" | cut -d: -f3)"
  stop_docker_services_for_native_providers
  local generated_dir="$TEMP_ROOT/generated"
  mkdir -p "$generated_dir/transmission-image"
  generate_environment_file "$generated_dir/.env"
  generate_compose_file "$generated_dir/compose.yaml"
  generate_transmission_dockerfile "$generated_dir/transmission-image/Dockerfile"
  generate_operator_readme "$generated_dir/README.txt"
  docker_execute compose \
    --project-directory "$generated_dir" \
    --env-file "$generated_dir/.env" \
    -f "$generated_dir/compose.yaml" config >/dev/null
  sudo mkdir -p \
    "$DEPLOY_DIR" \
    "$JELLYFIN_CONFIG_DIR" \
    "$JELLYFIN_CACHE_DIR" \
    "$TRANSMISSION_CONFIG_DIR" \
    "$TRANSMISSION_WATCH_DIR" \
    "$DEPLOY_DIR/transmission-image"
  sudo chown -R "$LOGIN_UID:$MEDIA_GID" "$JELLYFIN_CONFIG_DIR" "$JELLYFIN_CACHE_DIR"
  sudo chown -R "$LOGIN_UID:$MEDIA_GID" "$TRANSMISSION_CONFIG_DIR" "$TRANSMISSION_WATCH_DIR"
  install_root_file "$generated_dir/.env" "$DEPLOY_DIR/.env" 0600 "$LOGIN_USER" "$LOGIN_GROUP"
  install_root_file "$generated_dir/compose.yaml" "$DEPLOY_DIR/compose.yaml" 0640 "$LOGIN_USER" "$LOGIN_GROUP"
  install_root_file "$generated_dir/README.txt" "$DEPLOY_DIR/README.txt" 0644 "$LOGIN_USER" "$LOGIN_GROUP"
  if [[ "$TRANSMISSION_PROVIDER" == 'docker' ]]; then
    install_root_file "$generated_dir/transmission-image/Dockerfile" "$DEPLOY_DIR/transmission-image/Dockerfile" 0644 "$LOGIN_USER" "$LOGIN_GROUP"
  fi
  compose_execute config >/dev/null
  compose_execute pull jellyfin
  if [[ "$SAMBA_PROVIDER" == 'docker' ]]; then
    compose_execute pull samba
  fi
  if [[ "$TRANSMISSION_PROVIDER" == 'docker' ]]; then
    compose_execute build --pull transmission
  fi
  disable_native_services_for_docker_providers
  if ! compose_execute up -d; then
    warning 'The Docker stack failed to start. Restoring native providers selected for migration.'
    restore_native_services_after_failure
    die 'Application startup failed. Review Docker Compose logs and retry.'
  fi
  success 'The selected application stack is deployed.'
}
