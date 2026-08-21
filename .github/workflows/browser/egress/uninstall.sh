#!/usr/bin/env bash

set -Eeuo pipefail
set +x

readonly DRY_RUN="${DRY_RUN:-true}"

die() {
  printf 'Error: %s\n' "$*" >&2
  exit 1
}

log() {
  printf '==> %s\n' "$*"
}

show_help() {
  cat <<'EOF'
Uninstall One Browser Egress while preserving operator data by default.

Usage:
  DRY_RUN=true ./uninstall.sh --mode <native|docker> [--purge]
  DRY_RUN=false ./uninstall.sh --mode <native|docker> \
    --confirm uninstall:<mode>
  DRY_RUN=false ./uninstall.sh --mode <native|docker> --purge \
    --confirm purge:<mode>

The default removes only the managed runtime/service and installation record.
It preserves /etc/one-browser-egress and /var/lib/one-browser-egress. --purge
removes exactly those two guarded directories as well. Docker itself and pulled
images are never removed.
EOF
}

validate_boolean() {
  [[ "${1-}" == true || "${1-}" == false ]]
}

validate_mode() {
  [[ "${1-}" == native || "${1-}" == docker ]]
}

detect_platform() {
  local kernel
  if [[ "${ONE_EGRESS_TESTING:-false}" == true ]]; then
    kernel=${ONE_EGRESS_TEST_KERNEL:-$(uname -s)}
  else
    kernel=$(uname -s)
  fi
  [[ "$kernel" == Linux ]] ||
    die "Egress uninstall lifecycle is unsupported on $kernel; no verified launchd or Docker Desktop service contract exists"
}

configure_paths() {
  local prefix=
  if [[ "${ONE_EGRESS_TESTING:-false}" == true ]]; then
    prefix=${ONE_EGRESS_TEST_ROOT:-}
    case "$prefix" in
      /tmp/one-egress-test.*|/private/tmp/one-egress-test.*) ;;
      *) die 'ONE_EGRESS_TEST_ROOT must be a narrow /tmp/one-egress-test.* path' ;;
    esac
  fi
  INSTALL_DIR="$prefix/opt/one-browser-egress"
  BINARY="$INSTALL_DIR/bin/one-browser-egress"
  RECORD="$INSTALL_DIR/installation.env"
  COMPOSE_FILE="$INSTALL_DIR/compose.yml"
  CONFIG_DIR="$prefix/etc/one-browser-egress"
  STATE_DIR="$prefix/var/lib/one-browser-egress"
  SERVICE_FILE="$prefix/etc/systemd/system/one-browser-egress.service"
}

read_record() {
  local key=$1
  [[ -f "$RECORD" && ! -L "$RECORD" ]] || return 1
  awk -F= -v wanted="$key" '
    $1 == wanted { if (seen++) exit 2; sub(/^[^=]*=/, ""); value=$0 }
    END { if (seen != 1) exit 1; print value }
  ' "$RECORD"
}

detect_mode() {
  local recorded native=0 docker=0
  recorded=$(read_record mode 2>/dev/null || true)
  [[ -e "$SERVICE_FILE" || -e "$BINARY" ]] && native=1
  [[ -e "$COMPOSE_FILE" ]] && docker=1
  [[ "$native" -eq 0 || "$docker" -eq 0 ]] ||
    die 'both Native and Docker artifacts exist; refusing ambiguous uninstall'
  if validate_mode "$recorded"; then
    [[ "$recorded" != native || "$docker" -eq 0 ]] ||
      die 'installation record says Native but Docker artifacts also exist'
    [[ "$recorded" != docker || "$native" -eq 0 ]] ||
      die 'installation record says Docker but Native artifacts also exist'
    printf '%s' "$recorded"
    return
  fi
  [[ "$native" -eq 1 ]] && printf native
  [[ "$docker" -eq 1 ]] && printf docker
  return 0
}

require_confirmation() {
  local expected="uninstall:$MODE"
  validate_boolean "$DRY_RUN" || die 'DRY_RUN must be true or false'
  [[ "$PURGE" == false ]] || expected="purge:$MODE"
  if [[ "$DRY_RUN" == false ]]; then
    [[ "$CONFIRMATION" == "$expected" ]] ||
      die "real uninstall requires --confirm $expected"
    if [[ "${ONE_EGRESS_TESTING:-false}" != true && ${EUID:-$(id -u)} -ne 0 ]]; then
      die 'real uninstall must run as root'
    fi
  fi
}

remove_empty_runtime_dirs() {
  rmdir "$INSTALL_DIR/bin" 2>/dev/null || true
  rmdir "$INSTALL_DIR" 2>/dev/null || true
}

uninstall_native() {
  command -v systemctl >/dev/null 2>&1 || die 'systemctl is required for native uninstall'
  systemctl stop one-browser-egress.service >/dev/null 2>&1 || true
  systemctl disable one-browser-egress.service >/dev/null 2>&1 || true
  rm -f -- "$SERVICE_FILE"
  systemctl daemon-reload
  systemctl reset-failed one-browser-egress.service >/dev/null 2>&1 || true
  rm -f -- "$BINARY" "$RECORD"
  remove_empty_runtime_dirs
}

uninstall_docker() {
  command -v docker >/dev/null 2>&1 || die 'docker is required for Docker uninstall'
  docker info >/dev/null 2>&1 || die 'Docker daemon is unavailable'
  if [[ -f "$COMPOSE_FILE" && ! -L "$COMPOSE_FILE" ]]; then
    docker compose --project-name one-browser-egress -f "$COMPOSE_FILE" \
      down --remove-orphans >/dev/null
  elif docker container inspect one-browser-egress >/dev/null 2>&1; then
    docker rm --force one-browser-egress >/dev/null
  fi
  docker container inspect one-browser-egress >/dev/null 2>&1 &&
    die 'Docker Egress container still exists after uninstall'
  rm -f -- "$COMPOSE_FILE" "$RECORD"
  remove_empty_runtime_dirs
}

purge_operator_data() {
  local expected path
  for path in "$CONFIG_DIR" "$STATE_DIR"; do
    case "$path" in
      */etc/one-browser-egress) expected=$CONFIG_DIR ;;
      */var/lib/one-browser-egress) expected=$STATE_DIR ;;
      *) die "refusing broad purge path: $path" ;;
    esac
    [[ "$path" == "$expected" && "$path" != / && "$path" != "${HOME:-/nonexistent}" ]] ||
      die "refusing unsafe purge path: $path"
    [[ ! -L "$path" ]] || die "refusing to purge symlink: $path"
    rm -rf -- "$path"
  done
}

main() {
  local detected expected_confirmation
  MODE=
  CONFIRMATION=
  PURGE=false
  while [[ "$#" -gt 0 ]]; do
    case "$1" in
      --mode) [[ "$#" -ge 2 ]] || die '--mode requires a value'; MODE=$2; shift 2 ;;
      --purge) [[ "$PURGE" == false ]] || die '--purge may be supplied once'; PURGE=true; shift ;;
      --confirm) [[ "$#" -ge 2 ]] || die '--confirm requires a value'; CONFIRMATION=$2; shift 2 ;;
      -h|--help) show_help; return 0 ;;
      *) die "unknown argument: $1" ;;
    esac
  done
  validate_mode "$MODE" || die '--mode must be native or docker'
  configure_paths
  require_confirmation
  detect_platform
  detected=$(detect_mode)
  if [[ -z "$detected" ]]; then
    log 'No One Browser Egress installation was found'
    if [[ "$PURGE" == false || "$DRY_RUN" == true ]]; then
      return 0
    fi
  elif [[ "$detected" != "$MODE" ]]; then
    die "installed mode is $detected, not $MODE"
  fi
  expected_confirmation="uninstall:$MODE"
  [[ "$PURGE" == false ]] || expected_confirmation="purge:$MODE"
  log "Plan: $expected_confirmation"
  log "Preserve by default: $CONFIG_DIR and $STATE_DIR"
  if [[ "$DRY_RUN" == true ]]; then
    log 'DRY_RUN=true: no service, container, or file mutation was performed'
    return 0
  fi
  if [[ -n "$detected" ]]; then
    if [[ "$MODE" == native ]]; then
      uninstall_native
    else
      uninstall_docker
    fi
  fi
  [[ "$PURGE" == false ]] || purge_operator_data
  if [[ "$PURGE" == true ]]; then
    log 'Egress runtime, configuration, and state were removed'
  else
    log 'Egress runtime was removed; configuration and state were preserved'
  fi
}

if [[ "${ONE_EGRESS_LIBRARY_ONLY:-false}" != true ]]; then
  main "$@"
fi
