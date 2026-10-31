#!/usr/bin/env bash

wait_for_compose_service() {
  local service_name="$1"
  local attempts=30
  local container_id
  local state
  container_id="$(compose_execute ps -q "$service_name" 2>/dev/null || true)"
  [[ -n "$container_id" ]] || {
    warning "No container was found for Compose service $service_name."
    return 1
  }
  while (( attempts > 0 )); do
    state="$(docker_execute inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$container_id" 2>/dev/null || true)"
    case "$state" in
      healthy|running)
        success "$service_name is $state."
        return 0
        ;;
      unhealthy|exited|dead)
        warning "$service_name entered state: $state"
        return 1
        ;;
    esac
    sleep 2
    attempts=$((attempts - 1))
  done
  warning "$service_name did not become ready within 60 seconds."
  return 1
}

verify_http_code() {
  local url="$1"
  local label="$2"
  local accepted_codes="$3"
  local code
  code="$(curl -sS -o /dev/null -w '%{http_code}' "$url" 2>/dev/null || true)"
  if [[ ",$accepted_codes," == *",$code,"* ]]; then
    success "$label responded with HTTP $code."
  else
    warning "$label response was HTTP ${code:-unavailable}."
    VERIFY_WARNINGS=$((VERIFY_WARNINGS + 1))
  fi
}

verify_configuration() {
  begin_step 'Verification' 'The wizard checks the effective mount, service health, application endpoints, and selected providers.'
  if (( DRY_RUN )); then
    info 'Would verify mount identity, Compose rendering, containers, host services, ports, and HTTP health.'
    return 0
  fi
  VERIFY_WARNINGS=0
  ensure_apt_packages curl
  local mounted_uuid
  mounted_uuid="$(findmnt -rn -M "$MEDIA_PATH" -o UUID 2>/dev/null || true)"
  if [[ "$mounted_uuid" == "$DISK_UUID" ]]; then
    success "$MEDIA_PATH is mounted from UUID $DISK_UUID."
  else
    warning "Mount verification failed for $MEDIA_PATH."
    VERIFY_WARNINGS=$((VERIFY_WARNINGS + 1))
  fi
  compose_execute config >/dev/null
  compose_execute ps
  wait_for_compose_service jellyfin || VERIFY_WARNINGS=$((VERIFY_WARNINGS + 1))
  verify_http_code 'http://127.0.0.1:8096/health' Jellyfin '200'
  if [[ "$TRANSMISSION_PROVIDER" == 'docker' ]]; then
    wait_for_compose_service transmission || VERIFY_WARNINGS=$((VERIFY_WARNINGS + 1))
    verify_http_code "http://127.0.0.1:${RPC_PORT}/transmission/rpc" Transmission '200,401,409'
  elif service_is_active transmission-daemon.service; then
    success 'Native transmission-daemon is active.'
  else
    warning 'Native transmission-daemon is not active.'
    VERIFY_WARNINGS=$((VERIFY_WARNINGS + 1))
  fi
  if [[ "$SAMBA_PROVIDER" == 'docker' ]]; then
    wait_for_compose_service samba || VERIFY_WARNINGS=$((VERIFY_WARNINGS + 1))
  elif service_is_active smbd.service; then
    success 'Native smbd is active.'
  else
    warning 'Native smbd is not active.'
    VERIFY_WARNINGS=$((VERIFY_WARNINGS + 1))
  fi
  if ss -H -lnt | grep -Eq '(^|[.:])445[[:space:]]'; then
    success 'SMB port 445 is listening.'
  else
    warning 'SMB port 445 is not listening.'
    VERIFY_WARNINGS=$((VERIFY_WARNINGS + 1))
  fi
  if (( VERIFY_WARNINGS == 0 )); then
    success 'All verification checks passed.'
  else
    warning "Verification completed with $VERIFY_WARNINGS warning(s)."
  fi
}

print_completion_summary() {
  printf '\n%bMedia server configuration complete%b\n' "$COLOR_BOLD$COLOR_GREEN" "$COLOR_RESET"
  if (( DRY_RUN )); then
    printf 'No host changes were made because dry-run mode was active.\n'
    return 0
  fi
  printf '  Jellyfin:   http://%s:8096\n' "$PRIMARY_IP"
  if [[ "$TRANSMISSION_PROVIDER" == 'docker' ]]; then
    printf '  Transmission: http://%s:%s/transmission/web/\n' "$PRIMARY_IP" "$RPC_PORT"
  else
    printf '  Transmission: existing native service\n'
  fi
  if [[ "$SAMBA_PROVIDER" == 'docker' ]]; then
    printf '  SMB:        smb://%s/%s\n' "$PRIMARY_IP" "$SAMBA_SHARE_NAME"
  else
    printf '  SMB:        existing native shares\n'
  fi
  printf '  Compose:    %s/compose.yaml\n' "$DEPLOY_DIR"
  printf '  Operations: %s/README.txt\n' "$DEPLOY_DIR"
  printf '\nSign out and back in before using docker and media-group access without sudo.\n'
}
