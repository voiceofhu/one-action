# shellcheck shell=bash
# Globals are shared with the installation metadata helpers.
# shellcheck disable=SC2034

install_manager() {
  local temporary
  temporary=$(mktemp "$INSTALL_DIR/.manager.XXXXXX")
  {
    printf '#!/usr/bin/env bash\nset +x\nset -Eeuo pipefail\numask 077\n'
    declare -f die normalize_version read_env_value validate_install_mode installed_runtime installed_version \
      manager_main manager_help manager_interactive manager_action manager_run_entrypoint
    printf '\nmanager_main "$@"\n'
  } >"$temporary"
  chown root:root "$temporary"
  chmod 0700 "$temporary"
  mv -f "$temporary" "$INSTALL_DIR/install.sh"
}

manager_run_entrypoint() (
  local entrypoint=$1 temporary base_url
  shift
  temporary=$(mktemp -d /tmp/one-browser-egress-manager.XXXXXX)
  trap 'rm -rf -- "$temporary"' EXIT
  # Pin the entrypoint and all its modules to the same Action revision.
  curl -q --proto '=https' --tlsv1.2 --fail --silent --show-error --no-location \
    --connect-timeout 10 --max-time 30 --max-filesize 262144 \
    https://api.github.com/repos/voiceofhu/one-action/git/ref/heads/main \
    --output "$temporary/revision.json"
  local revision
  revision=$(jq -er '.object.sha' "$temporary/revision.json")
  [[ "$revision" =~ ^[a-f0-9]{40}$ ]] || die "Invalid Action revision"
  base_url="https://raw.githubusercontent.com/voiceofhu/one-action/$revision/egress"
  curl -q --proto '=https' --tlsv1.2 --fail --silent --show-error --no-location \
    --connect-timeout 10 --max-time 30 --max-filesize 1048576 \
    "$base_url/$entrypoint" --output "$temporary/entrypoint.sh"
  bash -n "$temporary/entrypoint.sh"
  ONE_BROWSER_EGRESS_SCRIPT_BASE_URL="$base_url/scripts" \
    /bin/bash "$temporary/entrypoint.sh" "$@"
)

manager_help() {
  printf '%s\n' 'One Browser Egress' \
    'Usage: ./install.sh [--status|--doctor|--upgrade [latest|VERSION]|--restart|--logs [--follow]|--uninstall --yes]' \
    'Run without arguments in a terminal to open the management menu.'
}

manager_action() {
  local action=$1 mode state version
  shift
  mode=$(installed_runtime) || die "Managed Egress installation is missing or invalid"
  case "$action" in
    --status)
      version=$(installed_version) || die "Installed version is invalid"
      if [ "$mode" = native ]; then
        state=$(systemctl is-active one-browser-egress.service 2>/dev/null || true)
      else
        state=$(docker inspect -f '{{.State.Status}}' one-browser-egress 2>/dev/null || true)
      fi
      printf 'One Browser Egress\n  runtime: %s\n  version: %s\n  state: %s\n' "$mode" "$version" "${state:-unavailable}"
      ;;
    --doctor)
      manager_action --status
      [ -f "$INSTALL_DIR/.env" ] && [ ! -L "$INSTALL_DIR/.env" ] || die "Environment file is missing or unsafe"
      if [ "$mode" = native ]; then
        systemctl is-active --quiet one-browser-egress.service
      else
        [ "$(docker inspect -f '{{.State.Running}}' one-browser-egress)" = true ]
      fi
      systemctl is-active --quiet one-browser-egress-updater.path
      [ -x "$INSTALL_DIR/updater.sh" ] || die "Host updater is missing"
      printf 'Egress runtime and remote upgrade watcher checks passed.\n'
      ;;
    --upgrade)
      version=$(normalize_version "${1:-latest}") || die "Invalid upgrade version"
      manager_run_entrypoint install.sh --upgrade-existing --version "$version"
      ;;
    --restart)
      if [ "$mode" = native ]; then
        systemctl restart one-browser-egress.service
      else
        docker compose -f "$INSTALL_DIR/docker-compose.yml" up -d --force-recreate
      fi
      ;;
    --logs)
      local -a follow=()
      [ "${1:-}" != --follow ] || follow=(-f)
      if [ "$mode" = native ]; then
        journalctl -u one-browser-egress.service -n 100 --no-pager "${follow[@]}"
      else
        docker logs --tail 100 "${follow[@]}" one-browser-egress
      fi
      ;;
    --uninstall) manager_run_entrypoint uninstall.sh --mode "$mode" ;;
  esac
}

manager_interactive() {
  local choice version answer
  while :; do
    printf '\nOne Browser Egress\n  1. Status\n  2. Doctor\n  3. Upgrade to latest\n  4. Upgrade to version\n  5. Restart\n  6. Logs\n  7. Follow logs\n  8. Uninstall\n  0. Exit\nSelect: '
    read -r choice || return 0
    case "$choice" in
      1) (manager_action --status) ;;
      2) (manager_action --doctor) ;;
      3) (manager_action --upgrade latest) ;;
      4) printf 'Version: '; read -r version || return 0; (manager_action --upgrade "$version") ;;
      5) (manager_action --restart) ;;
      6) (manager_action --logs) ;;
      7) (manager_action --logs --follow) ;;
      8)
        printf 'Remove Egress, its identity and runtime state? [y/N] '
        read -r answer || return 0
        case "$answer" in y|Y|yes|YES) manager_action --uninstall; return ;; esac
        ;;
      0) return 0 ;;
      *) printf 'Invalid selection\n' ;;
    esac
  done
}

manager_main() {
  INSTALL_DIR=/opt/one-browser-egress
  INSTALL_RECORD=$INSTALL_DIR/.installation
  if [ "${1:-}" = --help ] || [ "${1:-}" = -h ]; then manager_help; return; fi
  [ "${EUID:-$(id -u)}" -eq 0 ] || die "Run the Egress manager as root"
  if [ "$#" -eq 0 ]; then
    if [ -t 0 ] && [ -t 1 ]; then manager_interactive; else manager_help; fi
    return
  fi
  case "$1" in
    --status|--doctor|--restart) [ "$#" -eq 1 ] || die "$1 takes no arguments" ;;
    --upgrade) [ "$#" -le 2 ] || die "--upgrade accepts one version" ;;
    --logs) [ "$#" -le 2 ] && [ "${2:---follow}" = --follow ] || die "--logs accepts only --follow" ;;
    --uninstall) [ "$#" -eq 2 ] && [ "$2" = --yes ] || die "--uninstall requires --yes" ;;
    *) die "Unknown management option: $1" ;;
  esac
  manager_action "$@"
}
