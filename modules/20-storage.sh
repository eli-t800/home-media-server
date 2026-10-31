#!/usr/bin/env bash

extract_lsblk_value() {
  local key="$1"
  local text="$2"
  local expression="${key}=\"([^\"]*)\""
  if [[ "$text" =~ $expression ]]; then
    printf '%s' "${BASH_REMATCH[1]}"
  fi
}

select_storage_partition() {
  local root_source
  local choice
  local index
  local line
  local path
  root_source="$(findmnt -rn -M / -o SOURCE 2>/dev/null || true)"
  mapfile -t STORAGE_PARTITIONS < <(
    lsblk -P -p -o PATH,TYPE,FSTYPE,SIZE,LABEL,UUID,MOUNTPOINTS |
      awk '$0 ~ /TYPE="part"/ && $0 ~ /FSTYPE="(ext4|ext3|ext2|xfs|btrfs)"/'
  )
  ((${#STORAGE_PARTITIONS[@]} > 0)) || die 'No supported data partitions were found.'
  printf '\nAvailable data partitions:\n'
  for index in "${!STORAGE_PARTITIONS[@]}"; do
    line="${STORAGE_PARTITIONS[$index]}"
    path="$(extract_lsblk_value PATH "$line")"
    printf '  %d) %s' "$((index + 1))" "$line"
    [[ "$path" == "$root_source" ]] && printf '  ROOT FILESYSTEM - DO NOT SELECT'
    printf '\n'
  done
  choice="$(choose_number 'Select the media partition' 1 "${#STORAGE_PARTITIONS[@]}")"
  SELECTED_PARTITION_LINE="${STORAGE_PARTITIONS[$((choice - 1))]}"
  DEVICE="$(extract_lsblk_value PATH "$SELECTED_PARTITION_LINE")"
  FSTYPE="$(extract_lsblk_value FSTYPE "$SELECTED_PARTITION_LINE")"
  DISK_UUID="$(extract_lsblk_value UUID "$SELECTED_PARTITION_LINE")"
  [[ "$DEVICE" != "$root_source" ]] || die 'The root filesystem cannot be used as the removable media partition.'
  [[ -n "$DISK_UUID" ]] || DISK_UUID="$(lsblk -dn -o UUID "$DEVICE" 2>/dev/null | head -n1)"
  [[ -n "$DISK_UUID" ]] || die "The selected filesystem has no UUID: $DEVICE"
}

collect_storage_configuration() {
  begin_step 'Storage selection' 'The media filesystem stays on the host and is mounted by UUID before any application starts.'
  MEDIA_PATH="$(prompt_default 'Media mount path' '/mnt/media')"
  validate_absolute_path "$MEDIA_PATH" || die 'Use an absolute path without spaces, for example /mnt/media.'
  REUSE_EXISTING_MOUNT='no'
  MOVE_EXISTING_MOUNT='no'
  local mounted_target
  local mounted_source
  mounted_target="$(findmnt -rn -M "$MEDIA_PATH" -o TARGET 2>/dev/null || true)"
  if [[ "$mounted_target" == "$MEDIA_PATH" ]]; then
    mounted_source="$(findmnt -rn -M "$MEDIA_PATH" -o SOURCE)"
    printf '\nA filesystem is already mounted at %s:\n' "$MEDIA_PATH"
    findmnt "$MEDIA_PATH"
    if ask_yes_no 'Reuse this mounted filesystem?' yes; then
      REUSE_EXISTING_MOUNT='yes'
      DEVICE="$(readlink -f "$mounted_source" 2>/dev/null || printf '%s' "$mounted_source")"
      FSTYPE="$(findmnt -rn -M "$MEDIA_PATH" -o FSTYPE)"
      DISK_UUID="$(findmnt -rn -M "$MEDIA_PATH" -o UUID 2>/dev/null || true)"
      [[ -n "$DISK_UUID" ]] || DISK_UUID="$(lsblk -dn -o UUID "$DEVICE" 2>/dev/null | head -n1)"
      [[ -n "$DISK_UUID" ]] || die "Cannot determine the UUID for $DEVICE"
      case "$FSTYPE" in
        ext2|ext3|ext4|xfs|btrfs) ;;
        *) die "The existing $FSTYPE filesystem is not supported by the automatic ACL workflow. Use ext4, xfs, or btrfs." ;;
      esac
      success "Reusing $DEVICE at $MEDIA_PATH."
      return 0
    fi
  fi
  select_storage_partition
  local current_target
  current_target="$(findmnt -rn -S "$DEVICE" -o TARGET 2>/dev/null | head -n1 || true)"
  if [[ -n "$current_target" && "$current_target" != "$MEDIA_PATH" ]]; then
    warning "$DEVICE is currently mounted at $current_target."
    if ask_yes_no "Unmount it and move it to $MEDIA_PATH?" no; then
      MOVE_EXISTING_MOUNT='yes'
      EXISTING_MOUNT_TARGET="$current_target"
    else
      die 'Select another partition or reuse its current mount path.'
    fi
  fi
  success "Selected $DEVICE ($FSTYPE, UUID $DISK_UUID)."
}

build_fstab_candidate() {
  local output_path="$1"
  local fsck_pass=0
  case "$FSTYPE" in
    ext2|ext3|ext4) fsck_pass=2 ;;
  esac
  awk -v uuid="$DISK_UUID" -v mount_path="$MEDIA_PATH" '
    /^[[:space:]]*#/ || NF == 0 { print; next }
    $1 == "UUID=" uuid || $2 == mount_path { next }
    { print }
  ' /etc/fstab >"$output_path"
  printf 'UUID=%s %s %s defaults,nofail,x-systemd.device-timeout=15 0 %s\n' \
    "$DISK_UUID" "$MEDIA_PATH" "$FSTYPE" "$fsck_pass" >>"$output_path"
}

apply_storage_configuration() {
  begin_step 'Storage configuration' 'The wizard creates the mount point, updates one fstab entry, mounts the filesystem, and verifies its UUID.'
  run_root mkdir -p "$MEDIA_PATH"
  if [[ "$MOVE_EXISTING_MOUNT" == 'yes' ]]; then
    run_root umount "$EXISTING_MOUNT_TARGET"
  fi
  local candidate="$TEMP_ROOT/fstab"
  build_fstab_candidate "$candidate"
  if cmp -s /etc/fstab "$candidate"; then
    success '/etc/fstab already contains the requested mount configuration.'
  else
    install_root_file "$candidate" /etc/fstab 0644 root root
    run_root systemctl daemon-reload
  fi
  if (( DRY_RUN )); then
    info "Would verify that UUID $DISK_UUID is mounted at $MEDIA_PATH."
    return 0
  fi
  if ! mountpoint -q "$MEDIA_PATH"; then
    sudo mount "$MEDIA_PATH"
  fi
  local mounted_uuid
  mounted_uuid="$(findmnt -rn -M "$MEDIA_PATH" -o UUID 2>/dev/null || true)"
  [[ "$mounted_uuid" == "$DISK_UUID" ]] || die "$MEDIA_PATH is not mounted from the selected UUID."
  findmnt "$MEDIA_PATH"
  success 'The media filesystem is mounted and persistent.'
}
