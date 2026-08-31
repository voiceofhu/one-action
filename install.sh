#!/usr/bin/env bash

# Legacy compatibility entrypoint. New commands use egress/install.sh.

set +x
set -Eeuo pipefail

readonly ONE_BROWSER_EGRESS_INSTALLER_URL='https://raw.githubusercontent.com/voiceofhu/one-action/main/egress/install.sh'
ONE_BROWSER_EGRESS_COMPAT_TEMP_FILE=

egress_compat_cleanup() {
  if [ -n "$ONE_BROWSER_EGRESS_COMPAT_TEMP_FILE" ]; then
    rm -f -- "$ONE_BROWSER_EGRESS_COMPAT_TEMP_FILE"
  fi
}

egress_compat_local_entrypoint() {
  local entrypoint_dir

  [ -n "${BASH_SOURCE[0]:-}" ] || return 1
  entrypoint_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd) ||
    return 1
  [ -f "$entrypoint_dir/egress/install.sh" ] || return 1
  printf '%s/egress/install.sh' "$entrypoint_dir"
}

egress_compat_run() {
  local entrypoint

  entrypoint=$(egress_compat_local_entrypoint 2>/dev/null || true)
  if [ -z "$entrypoint" ]; then
    command -v curl >/dev/null || {
      printf 'Error: curl is required to load the Egress installer\n' >&2
      exit 1
    }
    ONE_BROWSER_EGRESS_COMPAT_TEMP_FILE=$(mktemp "/tmp/one-browser-egress-entrypoint.XXXXXX")
    chmod 0600 "$ONE_BROWSER_EGRESS_COMPAT_TEMP_FILE"
    curl -q --proto '=https' --tlsv1.2 \
      --fail --silent --show-error --no-location \
      --connect-timeout 10 --max-time 30 --max-filesize 262144 \
      "$ONE_BROWSER_EGRESS_INSTALLER_URL" \
      --output "$ONE_BROWSER_EGRESS_COMPAT_TEMP_FILE"
    /bin/bash -n "$ONE_BROWSER_EGRESS_COMPAT_TEMP_FILE"
    entrypoint=$ONE_BROWSER_EGRESS_COMPAT_TEMP_FILE
  fi

  # shellcheck disable=SC1090
  . "$entrypoint" "$@"
}

trap egress_compat_cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM HUP
egress_compat_run "$@"
