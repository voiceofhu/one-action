#!/bin/sh

validate_install_host() {
	[ "$(id -u)" -eq 0 ] || die "run this installer as root"
	[ -r /etc/os-release ] || die "cannot identify the operating system"
	# /etc/os-release is controlled by the installed operating system.
	# shellcheck disable=SC1091
	. /etc/os-release
	[ "${ID:-}" = "debian" ] || die "only Debian is supported"
	command -v dpkg >/dev/null 2>&1 || die "dpkg is required"
	command -v curl >/dev/null 2>&1 || die "curl is required"
	command -v stat >/dev/null 2>&1 || die "stat is required (install coreutils)"
	command -v awk >/dev/null 2>&1 || die "awk is required"

	resolve_host_architecture
	if [ "$INSTALL_MODE" = "native" ]; then
		command -v sha256sum >/dev/null 2>&1 ||
			die "sha256sum is required (install coreutils)"
		command -v systemctl >/dev/null 2>&1 ||
			die "systemd is required for native installation"
	fi
}

resolve_host_architecture() {
	dpkg_architecture=$(dpkg --print-architecture)
	machine_architecture=$(uname -m)
	case "$dpkg_architecture:$machine_architecture" in
	amd64:x86_64|amd64:amd64)
		ONE_NODE_ARCH="amd64"
		ONE_NODE_BINARY_SHA256=$ONE_NODE_BINARY_SHA256_AMD64
		;;
	arm64:aarch64|arm64:arm64)
		ONE_NODE_ARCH="arm64"
		ONE_NODE_BINARY_SHA256=$ONE_NODE_BINARY_SHA256_ARM64
		;;
	amd64:*|arm64:*) die "dpkg and kernel architectures do not match" ;;
	*) die "only Debian amd64 and arm64 are supported" ;;
	esac
	ONE_NODE_BINARY_NAME="one-node-linux-${ONE_NODE_ARCH}"
}

validate_install_target() {
	if [ -L "$INSTALL_DIR" ]; then
		SHOW_UNINSTALL_ON_ERROR="true"
		die "installation directory must not be a symlink"
	fi
	if [ -L "$ONE_NODE_STATE_DIR" ]; then
		SHOW_UNINSTALL_ON_ERROR="true"
		die "One Node state directory must not be a symlink"
	fi
	if [ "$RESET_EXISTING" = "true" ]; then
		reset_existing_installation
	fi
	if [ -e "$INSTALL_RECORD" ]; then
		SHOW_UNINSTALL_ON_ERROR="true"
		manifest_load "$INSTALL_RECORD" || die "refusing unknown or unsafe installation manifest"
		INSTALL_MANIFEST_KIND="current"
		UNINSTALL_MODE=$MANIFEST_MODE
		[ "$MANIFEST_MODE" = "$INSTALL_MODE" ] ||
			die "existing installation mode is $MANIFEST_MODE; requested mode is $INSTALL_MODE"
		ONE_NODE_STATE_DIR=$MANIFEST_STATE_DIR
		INSTALL_OPERATION="reconfigure"
		validate_reconfiguration_target
		return
	fi
	if [ -e "$UNIT_FILE" ]; then
		SHOW_UNINSTALL_ON_ERROR="true"
		UNINSTALL_MODE="native"
		[ "$INSTALL_MODE" = "native" ] ||
			die "One Node is installed in native mode; requested mode is $INSTALL_MODE"
		if command -v docker >/dev/null 2>&1 &&
			docker inspect "$CONTAINER_NAME" >/dev/null 2>&1; then
			die "both native and Docker One Node runtimes exist; refusing ambiguous recovery"
		fi
		MANIFEST_MODE="native"
		MANIFEST_STATE_DIR=$ONE_NODE_STATE_DIR
		INSTALL_MANIFEST_KIND="missing"
		INSTALL_OPERATION="reconfigure"
		validate_reconfiguration_target
		return
	fi
	if command -v docker >/dev/null 2>&1 &&
		docker inspect "$CONTAINER_NAME" >/dev/null 2>&1; then
		SHOW_UNINSTALL_ON_ERROR="true"
		UNINSTALL_MODE="docker"
		die "one-node container already exists"
	fi
}

print_installation_uninstall_command() {
	uninstall_mode=${UNINSTALL_MODE:-$INSTALL_MODE}
	action_commit=${ONE_ACTION_COMMIT:-}
	case "$action_commit" in
	''|*[!0-9a-f]*) return 1 ;;
	esac
	[ "${#action_commit}" -eq 40 ] || return 1
	uninstall_url="https://raw.githubusercontent.com/voiceofhu/one-action/${action_commit}/node/uninstall.sh"
	uninstall_protocols="'=https'"
	case "${ONE_NODE_RELEASE_BASE_URL:-}" in
	http://*)
		uninstall_url="${ONE_NODE_RELEASE_BASE_URL%/}/uninstall.sh"
		uninstall_protocols="'=http,https'"
		;;
	esac
	printf '%s\n' \
		"[one-node] uninstall the current installation, then retry:" \
		"curl -fsSL --proto ${uninstall_protocols} --proto-redir ${uninstall_protocols} --tlsv1.2 '${uninstall_url}' | sh -s -- --mode '${uninstall_mode}'" >&2
}

validate_managed_native_unit() {
	[ -f "$UNIT_FILE" ] && [ ! -L "$UNIT_FILE" ] ||
		die "one-node.service is missing or unsafe"
	[ "$(file_mode "$UNIT_FILE")" = "644" ] ||
		die "one-node.service permissions must be 0644"
	for unit_record in \
		'WorkingDirectory=/opt/one-node' \
		'EnvironmentFile=/opt/one-node/.env' \
		'ExecStart=/opt/one-node/one-node start'
	do
		[ "$(grep -Fxc "$unit_record" "$UNIT_FILE")" -eq 1 ] ||
			die "one-node.service is not a recognized One Node unit"
	done
	if grep -Eq '^(ExecStartPre|ExecStartPost|ExecStop|ExecStopPost|ExecReload)=' "$UNIT_FILE"; then
		die "one-node.service contains unmanaged lifecycle commands"
	fi
}

reset_existing_installation() {
	log "resetting the existing One Node development installation"
	if command -v systemctl >/dev/null 2>&1; then
		systemctl disable --now one-node.service >/dev/null 2>&1 || true
	fi
	if command -v docker >/dev/null 2>&1; then
		docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
	fi
	rm -f -- "$UNIT_FILE"
	rm -rf -- "$INSTALL_DIR" "$ONE_NODE_STATE_DIR"
	if command -v systemctl >/dev/null 2>&1; then
		systemctl daemon-reload
	fi
}

validate_reconfiguration_target() {
	if [ "$INSTALL_MANIFEST_KIND" = "missing" ]; then
		if [ -e "$ENV_FILE" ]; then
			[ -f "$ENV_FILE" ] && [ ! -L "$ENV_FILE" ] ||
				die "existing One Node environment file is unsafe"
			[ "$(file_mode "$ENV_FILE")" = "600" ] ||
				die "existing One Node environment file permissions must be 0600"
		fi
		if [ -e "$ONE_NODE_STATE_DIR" ]; then
			[ -d "$ONE_NODE_STATE_DIR" ] && [ ! -L "$ONE_NODE_STATE_DIR" ] ||
				die "existing One Node state directory is unsafe"
			[ "$(file_mode "$ONE_NODE_STATE_DIR")" = "700" ] ||
				die "existing One Node state directory permissions must be 0700"
		fi
	else
		[ -f "$ENV_FILE" ] && [ ! -L "$ENV_FILE" ] ||
			die "One Node environment file is missing or unsafe"
		[ "$(file_mode "$ENV_FILE")" = "600" ] ||
			die "One Node environment file permissions must be 0600"
		[ -d "$ONE_NODE_STATE_DIR" ] && [ ! -L "$ONE_NODE_STATE_DIR" ] ||
			die "One Node state directory is missing or unsafe"
		[ "$(file_mode "$ONE_NODE_STATE_DIR")" = "700" ] ||
			die "One Node state directory permissions must be 0700"
	fi

	IDENTITY_FILE="${ONE_NODE_STATE_DIR}/node-secret"
	RUNTIME_STATE_FILE="${ONE_NODE_STATE_DIR}/runtime-active.json"
	for state_file in "$IDENTITY_FILE" "$RUNTIME_STATE_FILE"; do
		if [ -e "$state_file" ]; then
			[ -f "$state_file" ] && [ ! -L "$state_file" ] ||
				die "existing node state file is unsafe: $state_file"
			[ "$(file_mode "$state_file")" = "600" ] ||
				die "existing node state file permissions must be 0600: $state_file"
		fi
	done

	case "$INSTALL_MODE" in
	native)
		if [ "$INSTALL_MANIFEST_KIND" = "missing" ]; then
			if [ -e "$MANIFEST_BINARY_PATH" ]; then
				[ -f "$MANIFEST_BINARY_PATH" ] && [ ! -L "$MANIFEST_BINARY_PATH" ] ||
					die "existing native binary is unsafe"
			fi
		else
			[ -f "$MANIFEST_BINARY_PATH" ] && [ ! -L "$MANIFEST_BINARY_PATH" ] ||
				die "current native binary is missing or unsafe"
		fi
		if [ "$INSTALL_MANIFEST_KIND" = "current" ]; then
			current_sha256=$(sha256sum "$MANIFEST_BINARY_PATH" | awk '{ print $1 }')
			[ "$current_sha256" = "$MANIFEST_CURRENT_BINARY_SHA256" ] ||
				die "current native binary does not match its manifest"
		fi
		validate_managed_native_unit
		;;
	docker)
		command -v docker >/dev/null 2>&1 || die "Docker is required for Docker reconfiguration"
		docker compose version >/dev/null 2>&1 || die "Docker Compose plugin is required"
		[ -f "$COMPOSE_FILE" ] && [ ! -L "$COMPOSE_FILE" ] ||
			die "current Docker compose file is missing or unsafe"
		docker inspect "$CONTAINER_NAME" >/dev/null 2>&1 ||
			die "current One Node container is missing"
		;;
	esac
}
