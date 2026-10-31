#!/usr/bin/env bash

collect_permissions_configuration() {
  begin_step 'Permission model' 'A shared media group and inherited ACLs allow services to share storage without chmod 777.'
  MEDIA_GROUP='media'
  MEDIA_GID='assigned-during-run'
  if getent group "$MEDIA_GROUP" >/dev/null 2>&1; then
    MEDIA_GID="$(getent group "$MEDIA_GROUP" | cut -d: -f3)"
  fi
  APPLY_RECURSIVE_ACL='no'
  printf '\nThe root ACL is quick. Applying ACLs to every existing file can take a long time on a large disk.\n'
  if ask_yes_no "Apply media-group access to every existing file below $MEDIA_PATH?" no; then
    APPLY_RECURSIVE_ACL='yes'
  fi
}

apply_permissions_configuration() {
  begin_step 'Permissions configuration' 'The wizard installs ACL support, creates the media group when needed, and configures inherited access.'
  ensure_apt_packages acl
  if ! getent group "$MEDIA_GROUP" >/dev/null 2>&1; then
    run_root groupadd "$MEDIA_GROUP"
  fi
  run_root usermod -aG "$MEDIA_GROUP" "$LOGIN_USER"
  if (( DRY_RUN )); then
    info "Would configure inherited ACLs for group $MEDIA_GROUP on $MEDIA_PATH."
    return 0
  fi
  MEDIA_GID="$(getent group "$MEDIA_GROUP" | cut -d: -f3)"
  sudo setfacl -m "g:${MEDIA_GROUP}:rwx,d:g:${MEDIA_GROUP}:rwx,d:m:rwx" "$MEDIA_PATH"
  if [[ "$APPLY_RECURSIVE_ACL" == 'yes' ]]; then
    sudo setfacl -Rm "g:${MEDIA_GROUP}:rwX" "$MEDIA_PATH"
    sudo find "$MEDIA_PATH" -type d -exec setfacl -m "d:g:${MEDIA_GROUP}:rwx,d:m:rwx" {} +
  fi
  sudo mkdir -p "$MEDIA_PATH/Downloads/complete" "$MEDIA_PATH/Downloads/incomplete"
  sudo setfacl -m "g:${MEDIA_GROUP}:rwx,d:g:${MEDIA_GROUP}:rwx,d:m:rwx" "$MEDIA_PATH/Downloads"
  success "Media access is shared through group $MEDIA_GROUP (GID $MEDIA_GID)."
}
