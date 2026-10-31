#!/usr/bin/env bash

DOCKER_COMMAND=(docker)

collect_docker_configuration() {
  begin_step 'Docker inspection' 'Jellyfin and optional application providers use Docker Engine with the Compose v2 plugin.'
  DOCKER_PRESENT='no'
  COMPOSE_PRESENT='no'
  INSTALL_DOCKER='no'
  command -v docker >/dev/null 2>&1 && DOCKER_PRESENT='yes'
  if [[ "$DOCKER_PRESENT" == 'yes' ]] && docker compose version >/dev/null 2>&1; then
    COMPOSE_PRESENT='yes'
  fi
  if [[ "$DOCKER_PRESENT" != 'yes' || "$COMPOSE_PRESENT" != 'yes' ]]; then
    warning 'Docker Engine or Docker Compose v2 is missing.'
    ask_yes_no 'Install Docker Engine from the official Docker repository?' yes || die 'Docker is required for Jellyfin.'
    INSTALL_DOCKER='yes'
  else
    success "$(docker compose version 2>/dev/null || true)"
  fi
}

install_official_docker() {
  case "$OS_ID" in
    ubuntu|debian) ;;
    *) die "Automatic Docker installation is not supported for $OS_ID." ;;
  esac
  [[ "$OS_CODENAME" != 'unknown' ]] || die 'Cannot determine the distribution codename for the Docker repository.'
  ensure_apt_packages ca-certificates curl
  local key_file="$TEMP_ROOT/docker.asc"
  local repository_file="$TEMP_ROOT/docker.list"
  local architecture
  architecture="$(dpkg --print-architecture)"
  run_command curl -fsSL "https://download.docker.com/linux/${OS_ID}/gpg" -o "$key_file"
  printf 'deb [arch=%s signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/%s %s stable\n' \
    "$architecture" "$OS_ID" "$OS_CODENAME" >"$repository_file"
  run_root install -m 0755 -d /etc/apt/keyrings
  install_root_file "$key_file" /etc/apt/keyrings/docker.asc 0644 root root
  install_root_file "$repository_file" /etc/apt/sources.list.d/docker.list 0644 root root
  if (( DRY_RUN )); then
    info 'Would refresh APT and install Docker Engine with the Compose v2 plugin.'
    return 0
  fi
  sudo apt-get update
  APT_UPDATED=1
  sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
}

select_docker_command() {
  DOCKER_COMMAND=(docker)
  if docker info >/dev/null 2>&1; then
    return 0
  fi
  if sudo docker info >/dev/null 2>&1; then
    DOCKER_COMMAND=(sudo docker)
    warning 'The current shell does not yet have Docker socket access. This run will use sudo docker.'
    return 0
  fi
  die 'Docker is installed, but the daemon is unavailable.'
}

docker_execute() {
  "${DOCKER_COMMAND[@]}" "$@"
}

compose_execute() {
  docker_execute compose \
    --project-directory "$DEPLOY_DIR" \
    --env-file "$DEPLOY_DIR/.env" \
    -f "$DEPLOY_DIR/compose.yaml" "$@"
}

apply_docker_configuration() {
  begin_step 'Docker configuration' 'The wizard installs missing Docker components, enables the daemon, and prepares current-user access.'
  if [[ "$INSTALL_DOCKER" == 'yes' ]]; then
    install_official_docker
  fi
  run_root systemctl enable --now docker
  if ! getent group docker >/dev/null 2>&1; then
    run_root groupadd docker
  fi
  run_root usermod -aG docker "$LOGIN_USER"
  if (( DRY_RUN )); then
    info 'Would validate Docker Engine and Docker Compose v2.'
    return 0
  fi
  select_docker_command
  docker_execute info >/dev/null
  docker_execute compose version
  success 'Docker Engine and Docker Compose v2 are ready.'
}
