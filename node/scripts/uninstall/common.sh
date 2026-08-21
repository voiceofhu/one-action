#!/bin/sh

# The uninstaller removes canonical installation paths and the complete state
# directory recorded by the installation manifest.

initialize_uninstall_config() {
	INSTALL_DIR="/opt/one-node"
	UNIT_FILE="/etc/systemd/system/one-node.service"
	COMPOSE_FILE="${INSTALL_DIR}/docker-compose.yml"
	INSTALL_RECORD="${INSTALL_DIR}/.installation"
	CONTAINER_NAME="one-node"
	REQUESTED_MODE=""
	installed_mode=""
}

log() {
	printf '%s\n' "[one-node] $*"
}

die() {
	printf '%s\n' "[one-node] error: $*" >&2
	exit 1
}

show_help() {
	printf '%s\n' \
		"Uninstall the One Node sing-box runtime." \
		"" \
		"Usage: uninstall.sh [--mode <native|docker>]" \
		"" \
		"Node credentials, runtime state, and pending telemetry are removed."
}

parse_uninstall_arguments() {
	while [ "$#" -gt 0 ]; do
		case "$1" in
		--mode)
			[ "$#" -ge 2 ] || die "--mode requires native or docker"
			[ -z "$REQUESTED_MODE" ] || die "--mode may be supplied only once"
			REQUESTED_MODE=$2
			shift 2
			;;
		--help|-h)
			show_help
			exit 0
			;;
		*) die "unknown argument: $1" ;;
		esac
	done
	case "$REQUESTED_MODE" in
	""|native|docker) ;;
	*) die "--mode must be native or docker" ;;
	esac
}

load_installation() {
	if [ ! -e "$INSTALL_RECORD" ]; then
		log "no One Node installation was found"
		return 1
	fi
	manifest_load "$INSTALL_RECORD" || die "refusing unknown or unsafe installation manifest"
	installed_mode=$MANIFEST_MODE
	if [ -n "$REQUESTED_MODE" ] && [ "$REQUESTED_MODE" != "$installed_mode" ]; then
		die "One Node is installed in ${installed_mode} mode, not ${REQUESTED_MODE}"
	fi
	return 0
}
