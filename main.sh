#!/usr/bin/env bash
set -Eeuo pipefail
export LC_ALL=C
export LANG=C

SCRIPT_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_ROOT

for module_file in \
  00-common.sh \
  10-preflight.sh \
  20-storage.sh \
  30-permissions.sh \
  40-docker.sh \
  50-applications.sh \
  60-startup.sh \
  70-firewall.sh \
  80-verify.sh; do
  module_path="$SCRIPT_ROOT/modules/$module_file"
  [[ -r "$module_path" ]] || {
    printf '[FAIL] Required module is missing: %s\n' "$module_path" >&2
    exit 1
  }
  source "$module_path"
done

run_wizard() {
  parse_arguments "$@"
  handle_information_request
  initialize_runtime
  print_welcome
  collect_preflight
  collect_storage_configuration
  collect_permissions_configuration
  collect_docker_configuration
  collect_application_configuration
  collect_firewall_configuration
  print_configuration_plan
  confirm_execution
  open_sudo_session
  apply_storage_configuration
  apply_permissions_configuration
  apply_docker_configuration
  apply_application_configuration
  apply_startup_configuration
  apply_firewall_configuration
  verify_configuration
  print_completion_summary
}

run_wizard "$@"
