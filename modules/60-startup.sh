#!/usr/bin/env bash

install_mount_dependency() {
  local service_name="$1"
  local directory_name="/etc/systemd/system/${service_name}.d"
  local target_path="$directory_name/99-media-mount.conf"
  local source_path="$TEMP_ROOT/${service_name}.99-media-mount.conf"
  printf '[Unit]\nRequiresMountsFor=%s\n' "$MEDIA_PATH" >"$source_path"
  run_root mkdir -p "$directory_name"
  install_root_file "$source_path" "$target_path" 0644 root root
}

apply_startup_configuration() {
  begin_step 'Startup ordering' 'systemd dependencies prevent applications from binding an empty directory before the USB filesystem is mounted.'
  install_mount_dependency docker.service
  if [[ "$TRANSMISSION_PROVIDER" == 'native' ]]; then
    install_mount_dependency transmission-daemon.service
    run_root systemctl enable transmission-daemon.service
  fi
  if [[ "$SAMBA_PROVIDER" == 'native' ]]; then
    if service_is_installed smbd.service; then
      install_mount_dependency smbd.service
      run_root systemctl enable smbd.service
    fi
    if service_is_installed nmbd.service; then
      install_mount_dependency nmbd.service
      run_root systemctl enable nmbd.service
    fi
  fi
  run_root systemctl daemon-reload
  success "Selected services now require $MEDIA_PATH."
}
