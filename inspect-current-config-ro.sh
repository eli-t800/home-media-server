#!/usr/bin/env bash
set -uo pipefail

SCRIPT_NAME="${0##*/}"
ALLOW_SUDO=false
INCLUDE_SANITIZED_CONFIG=false
MEDIA_PATH_OVERRIDE=''

usage() {
  cat <<EOF
Usage: $SCRIPT_NAME [options]

Collect the effective Raspberry Pi media-server configuration without changing it.
The report is written to stdout only.

Options:
  --allow-sudo                 Use only non-interactive sudo (-n) when available.
  --include-sanitized-config   Include sanitized Compose and .env file contents.
  --media-path PATH            Add a media path to the filesystem checks.
  -h, --help                   Show this help.

Examples:
  ./$SCRIPT_NAME
  ./$SCRIPT_NAME --allow-sudo --media-path /mnt/media
  ./$SCRIPT_NAME --allow-sudo --include-sanitized-config > pi-config-report.txt
EOF
}

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 2
}

while (($# > 0)); do
  case "$1" in
    --allow-sudo)
      ALLOW_SUDO=true
      shift
      ;;
    --include-sanitized-config)
      INCLUDE_SANITIZED_CONFIG=true
      shift
      ;;
    --media-path)
      (($# >= 2)) || die '--media-path requires a path'
      MEDIA_PATH_OVERRIDE="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "unknown option: $1"
      ;;
  esac
done

if ((BASH_VERSINFO[0] < 4)); then
  die 'Bash 4 or newer is required'
fi

section() {
  printf '\n\n## %s\n' "$*"
}

subsection() {
  printf '\n### %s\n' "$*"
}

note() {
  printf '[note] %s\n' "$*"
}

print_command() {
  printf '$'
  printf ' %q' "$@"
  printf '\n'
}

run() {
  print_command "$@"
  "$@" 2>&1
  local status=$?
  if ((status != 0)); then
    printf '[exit %d]\n' "$status"
  fi
  return 0
}

run_if_available() {
  local command_name="$1"
  shift
  if command -v "$command_name" >/dev/null 2>&1; then
    run "$command_name" "$@"
  else
    note "$command_name is not installed"
  fi
}

sanitize_stream() {
  awk '
    {
      lowered = tolower($0)
      if (lowered ~ /(password|passwd|passphrase|secret|token|api[_-]?key|private[_-]?key|rpc[_-]?pass|samba[_-]?password)/) {
        print "[REDACTED: secret-bearing line]"
      } else {
        print $0
      }
    }
  '
}

run_sanitized() {
  print_command "$@"
  "$@" 2>&1 | sanitize_stream
  local status=${PIPESTATUS[0]}
  if ((status != 0)); then
    printf '[exit %d]\n' "$status"
  fi
  return 0
}

trim() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "$value"
}

is_secret_key() {
  local key="${1^^}"
  case "$key" in
    *PASSWORD*|*PASSWD*|*PASSPHRASE*|*SECRET*|*TOKEN*|*API_KEY*|*APIKEY*|*PRIVATE_KEY*|*RPC_PASS*|*SAMBA_PASSWORD*|*CREDENTIAL*|*AUTH*)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

print_sanitized_env() {
  local line key value
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    if [[ "$line" == *=* ]]; then
      key="${line%%=*}"
      value="${line#*=}"
      if is_secret_key "$key"; then
        printf '%s=<redacted>\n' "$key"
      else
        printf '%s=%s\n' "$key" "$value"
      fi
    else
      printf '%s\n' "$line"
    fi
  done
}

declare -a PRIVILEGE=()
if [[ $EUID -eq 0 ]]; then
  PRIVILEGE=()
elif [[ "$ALLOW_SUDO" == true ]] && command -v sudo >/dev/null 2>&1 && sudo -n true >/dev/null 2>&1; then
  PRIVILEGE=(sudo -n)
elif [[ "$ALLOW_SUDO" == true ]]; then
  note 'non-interactive sudo is unavailable; continuing without it'
fi

declare -a DOCKER=()
DOCKER_ACCESS=false
if command -v docker >/dev/null 2>&1; then
  if docker info >/dev/null 2>&1; then
    DOCKER=(docker)
    DOCKER_ACCESS=true
  elif ((${#PRIVILEGE[@]} > 0)) && "${PRIVILEGE[@]}" docker info >/dev/null 2>&1; then
    DOCKER=("${PRIVILEGE[@]}" docker)
    DOCKER_ACCESS=true
  fi
fi

declare -A MEDIA_PATH_SET=()
declare -a MEDIA_PATHS=()
declare -A COMPOSE_FILE_SET=()
declare -a COMPOSE_FILES=()
declare -A COMPOSE_DIR_SET=()
declare -a COMPOSE_DIRS=()

add_media_path() {
  local path="$1"
  [[ -n "$path" ]] || return 0
  if [[ -z "${MEDIA_PATH_SET[$path]+x}" ]]; then
    MEDIA_PATH_SET["$path"]=1
    MEDIA_PATHS+=("$path")
  fi
}

add_compose_file() {
  local path
  path="$(trim "$1")"
  [[ -n "$path" ]] || return 0
  if [[ -z "${COMPOSE_FILE_SET[$path]+x}" ]]; then
    COMPOSE_FILE_SET["$path"]=1
    COMPOSE_FILES+=("$path")
  fi
}

add_compose_dir() {
  local path
  path="$(trim "$1")"
  [[ -n "$path" ]] || return 0
  if [[ -z "${COMPOSE_DIR_SET[$path]+x}" ]]; then
    COMPOSE_DIR_SET["$path"]=1
    COMPOSE_DIRS+=("$path")
  fi
}

discover_docker_paths() {
  [[ "$DOCKER_ACCESS" == true ]] || return 0
  local container_id config_files working_dir mount_type source destination writable file candidate
  local -a split_files=()

  while IFS= read -r container_id; do
    [[ -n "$container_id" ]] || continue

    config_files="$("${DOCKER[@]}" inspect --format '{{ index .Config.Labels "com.docker.compose.project.config_files" }}' "$container_id" 2>/dev/null || true)"
    if [[ -n "$config_files" && "$config_files" != '<no value>' ]]; then
      IFS=',' read -r -a split_files <<<"$config_files"
      for file in "${split_files[@]}"; do
        add_compose_file "$file"
      done
    fi

    working_dir="$("${DOCKER[@]}" inspect --format '{{ index .Config.Labels "com.docker.compose.project.working_dir" }}' "$container_id" 2>/dev/null || true)"
    if [[ -n "$working_dir" && "$working_dir" != '<no value>' ]]; then
      add_compose_dir "$working_dir"
    fi

    while IFS=$'\t' read -r mount_type source destination writable; do
      [[ "$mount_type" == bind && -n "$source" ]] || continue
      case "${destination,,}" in
        /media|/media/*|/downloads|/downloads/*|/music|/music/*|/movies|/movies/*|/tv|/tv/*|/shares|/shares/*)
          add_media_path "$source"
          ;;
      esac
    done < <("${DOCKER[@]}" inspect --format '{{range .Mounts}}{{printf "%s\t%s\t%s\t%t\n" .Type .Source .Destination .RW}}{{end}}' "$container_id" 2>/dev/null || true)
  done < <("${DOCKER[@]}" ps -aq 2>/dev/null || true)

  for working_dir in "${COMPOSE_DIRS[@]}"; do
    for candidate in compose.yaml compose.yml docker-compose.yaml docker-compose.yml .env; do
      [[ -f "$working_dir/$candidate" ]] && add_compose_file "$working_dir/$candidate"
    done
  done
}

[[ -n "$MEDIA_PATH_OVERRIDE" ]] && add_media_path "$MEDIA_PATH_OVERRIDE"
[[ -e /mnt/media ]] && add_media_path /mnt/media
discover_docker_paths

printf '# Raspberry Pi media-server configuration report\n'
printf 'Generated: %s\n' "$(date --iso-8601=seconds 2>/dev/null || date)"
printf 'Collector: %s\n' "$SCRIPT_NAME"
printf 'Read-only mode: no mounts, services, containers, packages, permissions, or files are changed.\n'
printf 'Sudo policy: %s\n' "$(if [[ "$ALLOW_SUDO" == true ]]; then printf 'non-interactive sudo allowed'; else printf 'disabled'; fi)"
printf 'Secret policy: known secret-bearing environment values and config lines are redacted.\n'

section 'Host identity and capacity'
run_if_available hostnamectl
run_if_available uname -a
if [[ -r /etc/os-release ]]; then
  run cat /etc/os-release
fi
if [[ -r /proc/device-tree/model ]]; then
  printf '$ tr -d \\0 < /proc/device-tree/model\n'
  tr -d '\0' </proc/device-tree/model
  printf '\n'
fi
run_if_available lscpu
run_if_available free -h
run_if_available uptime
run_if_available timedatectl
run_if_available id
if command -v getent >/dev/null 2>&1; then
  run getent group docker media render video
fi
if command -v vcgencmd >/dev/null 2>&1; then
  run vcgencmd get_throttled
  run vcgencmd measure_temp
fi

section 'Network and listening services'
run_if_available hostname -I
if command -v ip >/dev/null 2>&1; then
  run ip -brief address
  run ip route
fi
if command -v ss >/dev/null 2>&1; then
  if ((${#PRIVILEGE[@]} > 0)); then
    run "${PRIVILEGE[@]}" ss -lntup
  else
    run ss -lntup
  fi
fi

section 'Storage, mounts, and boot persistence'
if command -v lsblk >/dev/null 2>&1; then
  run lsblk -e 7 -o NAME,PATH,TYPE,SIZE,FSTYPE,FSVER,LABEL,UUID,MOUNTPOINTS,MODEL,TRAN
fi
if command -v blkid >/dev/null 2>&1; then
  if ((${#PRIVILEGE[@]} > 0)); then
    run "${PRIVILEGE[@]}" blkid
  else
    run blkid
  fi
fi
run_if_available findmnt --real --output SOURCE,TARGET,FSTYPE,OPTIONS
run_if_available findmnt --fstab --evaluate --output SOURCE,TARGET,FSTYPE,OPTIONS
run_if_available df -hT
if [[ -r /etc/fstab ]]; then
  subsection '/etc/fstab (sanitized)'
  run_sanitized cat /etc/fstab
else
  note '/etc/fstab is not readable'
fi

section 'Host configuration files'
for host_config in /etc/docker/daemon.json /etc/default/docker /boot/firmware/config.txt /boot/firmware/cmdline.txt /boot/config.txt /boot/cmdline.txt; do
  [[ -e "$host_config" ]] || continue
  subsection "$host_config"
  if [[ -r "$host_config" ]]; then
    run stat -c 'mode=%A (%a) owner=%U:%G size=%s modified=%y path=%n' "$host_config"
    if command -v sha256sum >/dev/null 2>&1; then
      run sha256sum "$host_config"
    fi
    run_sanitized cat "$host_config"
  elif ((${#PRIVILEGE[@]} > 0)) && "${PRIVILEGE[@]}" test -r "$host_config"; then
    run "${PRIVILEGE[@]}" stat -c 'mode=%A (%a) owner=%U:%G size=%s modified=%y path=%n' "$host_config"
    if command -v sha256sum >/dev/null 2>&1; then
      run "${PRIVILEGE[@]}" sha256sum "$host_config"
    fi
    run_sanitized "${PRIVILEGE[@]}" cat "$host_config"
  else
    note 'file exists but is not readable'
  fi
done

section 'systemd startup order and host services'
if command -v systemctl >/dev/null 2>&1; then
  run systemctl show docker.service --no-pager --property=LoadState,ActiveState,UnitFileState,FragmentPath,DropInPaths,After,Requires,Wants
  run_sanitized systemctl cat docker.service --no-pager
  run systemctl list-units --type=mount --all --no-pager --plain
  for unit in docker.service containerd.service jellyfin.service transmission-daemon.service smbd.service nmbd.service avahi-daemon.service; do
    subsection "$unit"
    run systemctl show "$unit" --no-pager --property=LoadState,ActiveState,SubState,UnitFileState,FragmentPath,DropInPaths
  done
else
  note 'systemctl is not installed'
fi

section 'Relevant host packages'
if command -v dpkg-query >/dev/null 2>&1; then
  run dpkg-query -W '-f=${binary:Package}\t${Version}\n' 'docker*' 'containerd*' 'jellyfin*' 'samba*' 'transmission*'
elif command -v rpm >/dev/null 2>&1; then
  run rpm -qa
else
  note 'neither dpkg-query nor rpm is installed'
fi

section 'Hardware acceleration devices'
if [[ -e /dev/dri ]]; then
  run ls -la /dev/dri
else
  note '/dev/dri is absent'
fi
if [[ -e /dev/vchiq ]]; then
  run ls -la /dev/vchiq
fi
run_if_available groups

section 'Docker runtime'
if [[ "$DOCKER_ACCESS" != true ]]; then
  note 'Docker is absent or inaccessible to this user'
  if [[ "$ALLOW_SUDO" != true ]]; then
    note 'rerun with --allow-sudo if Docker requires sudo'
  fi
else
  run "${DOCKER[@]}" version
  run "${DOCKER[@]}" info
  run "${DOCKER[@]}" compose version
  run "${DOCKER[@]}" compose ls --all
  run "${DOCKER[@]}" ps -a --no-trunc --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}\t{{.Networks}}'
  run "${DOCKER[@]}" image ls --digests --no-trunc
  run "${DOCKER[@]}" system df
  run "${DOCKER[@]}" network ls
  run "${DOCKER[@]}" volume ls

  while IFS= read -r container_id; do
    [[ -n "$container_id" ]] || continue
    container_name="$("${DOCKER[@]}" inspect --format '{{.Name}}' "$container_id" 2>/dev/null || printf '%s' "$container_id")"
    container_name="${container_name#/}"
    subsection "Container: $container_name"

    run_sanitized "${DOCKER[@]}" inspect --format 'ID={{.Id}}
Created={{.Created}}
Image={{.Config.Image}}
ImageID={{.Image}}
Path={{.Path}}
User={{.Config.User}}
WorkingDir={{.Config.WorkingDir}}
State={{.State.Status}}
Health={{if .State.Health}}{{.State.Health.Status}}{{else}}not-configured{{end}}
RestartPolicy={{.HostConfig.RestartPolicy.Name}}
NetworkMode={{.HostConfig.NetworkMode}}
Networks={{json .NetworkSettings.Networks}}
Runtime={{.HostConfig.Runtime}}
Privileged={{.HostConfig.Privileged}}
ReadonlyRootfs={{.HostConfig.ReadonlyRootfs}}
SecurityOpt={{json .HostConfig.SecurityOpt}}
MemoryBytes={{.HostConfig.Memory}}
NanoCpus={{.HostConfig.NanoCpus}}
LogConfig={{json .HostConfig.LogConfig}}
Ports={{json .NetworkSettings.Ports}}
Devices={{json .HostConfig.Devices}}
DeviceRequests={{json .HostConfig.DeviceRequests}}
GroupAdd={{json .HostConfig.GroupAdd}}
CapAdd={{json .HostConfig.CapAdd}}
Healthcheck={{json .Config.Healthcheck}}
ComposeProject={{index .Config.Labels "com.docker.compose.project"}}
ComposeService={{index .Config.Labels "com.docker.compose.service"}}
ComposeWorkingDir={{index .Config.Labels "com.docker.compose.project.working_dir"}}
ComposeFiles={{index .Config.Labels "com.docker.compose.project.config_files"}}' "$container_id"

    printf '$ docker inspect <container> mounts\n'
    "${DOCKER[@]}" inspect --format '{{range .Mounts}}{{printf "type=%s source=%s destination=%s rw=%t propagation=%s\n" .Type .Source .Destination .RW .Propagation}}{{end}}' "$container_id" 2>&1

    printf '$ docker inspect <container> environment\n'
    "${DOCKER[@]}" inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "$container_id" 2>/dev/null | print_sanitized_env
  done < <("${DOCKER[@]}" ps -aq 2>/dev/null || true)
fi

section 'Discovered media paths'
if ((${#MEDIA_PATHS[@]} == 0)); then
  note 'no media path was discovered; use --media-path PATH to add one'
else
  for media_path in "${MEDIA_PATHS[@]}"; do
    subsection "$media_path"
    if [[ ! -e "$media_path" ]]; then
      note 'path does not exist on the host'
      continue
    fi
    run ls -ld "$media_path"
    run_if_available stat -c 'mode=%A (%a) owner=%U:%G uid=%u gid=%g size=%s modified=%y path=%n' "$media_path"
    run_if_available findmnt -T "$media_path" --output SOURCE,TARGET,FSTYPE,OPTIONS
    run_if_available namei -l "$media_path"
    if command -v getfacl >/dev/null 2>&1; then
      run getfacl -cp "$media_path"
    fi
  done
fi

section 'Compose and environment file provenance'
if ((${#COMPOSE_FILES[@]} == 0)); then
  note 'no Compose config files were discovered from running container labels'
else
  for compose_file in "${COMPOSE_FILES[@]}"; do
    subsection "$compose_file"
    if [[ -r "$compose_file" ]]; then
      run stat -c 'mode=%A (%a) owner=%U:%G size=%s modified=%y path=%n' "$compose_file"
      if command -v sha256sum >/dev/null 2>&1; then
        run sha256sum "$compose_file"
      fi
      if [[ "$INCLUDE_SANITIZED_CONFIG" == true ]]; then
        run_sanitized cat "$compose_file"
      else
        note 'content omitted; use --include-sanitized-config to include a redacted copy'
      fi
    elif ((${#PRIVILEGE[@]} > 0)) && "${PRIVILEGE[@]}" test -r "$compose_file"; then
      run "${PRIVILEGE[@]}" stat -c 'mode=%A (%a) owner=%U:%G size=%s modified=%y path=%n' "$compose_file"
      if command -v sha256sum >/dev/null 2>&1; then
        run "${PRIVILEGE[@]}" sha256sum "$compose_file"
      fi
      if [[ "$INCLUDE_SANITIZED_CONFIG" == true ]]; then
        run_sanitized "${PRIVILEGE[@]}" cat "$compose_file"
      else
        note 'content omitted; use --include-sanitized-config to include a redacted copy'
      fi
    else
      note 'file is missing or unreadable from this host context'
    fi
  done
fi

section 'Application-specific read-only checks'
if command -v testparm >/dev/null 2>&1; then
  run_sanitized testparm -s
else
  note 'host testparm is not installed; Samba may be containerized'
fi

printf '\n\n# End of report\n'
