#!/bin/sh

validate_install_host() {
	[ "$(id -u)" -eq 0 ] || die "run this installer as root"
	for required_command in awk curl grep install mktemp sed stat sync uname; do
		command -v "$required_command" >/dev/null 2>&1 ||
			die "$required_command is required"
	done
	[ "$(uname -s)" = "Linux" ] || die "only Linux is supported"
	command -v systemctl >/dev/null 2>&1 ||
		die "systemd is required for One Node firewall management"
	command -v nft >/dev/null 2>&1 ||
		die "nftables is required for One Node firewall management"

	resolve_host_architecture
	if [ "$INSTALL_MODE" = "native" ]; then
		command -v sha256sum >/dev/null 2>&1 ||
			die "sha256sum is required (install coreutils)"
		command -v systemctl >/dev/null 2>&1 ||
			die "systemd is required for native installation"
	fi
}

resolve_host_architecture() {
	machine_architecture=$(uname -m)
	case "$machine_architecture" in
	x86_64|amd64)
		ONE_NODE_ARCH="amd64"
		ONE_NODE_BINARY_SHA256=$ONE_NODE_BINARY_SHA256_AMD64
		;;
	aarch64|arm64)
		ONE_NODE_ARCH="arm64"
		ONE_NODE_BINARY_SHA256=$ONE_NODE_BINARY_SHA256_ARM64
		;;
	*) die "only Linux amd64 and arm64 are supported" ;;
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
		preflight_owned_paths
		validate_node_state_files "$MANIFEST_STATE_DIR"
		INSTALL_OPERATION="replace"
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
		validate_reconfiguration_target
		INSTALL_OPERATION="replace"
		return
	fi
	if command -v docker >/dev/null 2>&1 &&
		docker inspect "$CONTAINER_NAME" >/dev/null 2>&1; then
		SHOW_UNINSTALL_ON_ERROR="true"
		UNINSTALL_MODE="docker"
		MANIFEST_MODE="docker"
		MANIFEST_STATE_DIR=$ONE_NODE_STATE_DIR
		INSTALL_MANIFEST_KIND="missing"
		validate_reconfiguration_target
		INSTALL_OPERATION="replace"
		return
	fi
}

# Replacement is transactional: the previous program, environment, units,
# manifest, and state (identity, runtime state, spools) are moved into a backup
# directory instead of being deleted. A failed new installation moves them back
# and restarts the previous runtime; a ready one discards the backup.
replace_backup_path() {
	backup_target=$1
	[ -n "$backup_target" ] || return 0
	[ -e "$backup_target" ] || [ -L "$backup_target" ] || return 0
	if awk -F'|' -v path="$backup_target" '$2 == path { found = 1 } END { exit !found }' \
		"${REPLACE_BACKUP_DIR}/moved"; then
		return 0
	fi
	REPLACE_BACKUP_COUNT=$((REPLACE_BACKUP_COUNT + 1))
	# Copy, record, then delete: the original is only removed once a complete
	# copy is recorded, even when the backup crosses filesystems.
	cp -pR -- "$backup_target" "${REPLACE_BACKUP_DIR}/${REPLACE_BACKUP_COUNT}" ||
		die "unable to back up $backup_target"
	printf '%s\n' "${REPLACE_BACKUP_COUNT}|${backup_target}" >>"${REPLACE_BACKUP_DIR}/moved" ||
		die "unable to record the previous installation backup"
	rm -rf -- "$backup_target" || die "unable to move $backup_target aside"
}

replace_record_directory() {
	backup_directory=$1
	[ -d "$backup_directory" ] && [ ! -L "$backup_directory" ] || return 0
	printf '%s\n' "d|$(file_mode "$backup_directory")|${backup_directory}" >>"${REPLACE_BACKUP_DIR}/directories" ||
		die "unable to record the previous installation backup"
}

replace_unit_is_enabled() {
	command -v systemctl >/dev/null 2>&1 || return 1
	systemctl is-enabled --quiet "$1" >/dev/null 2>&1
}

stop_replaced_runtime() {
	REPLACE_ENABLED_UNITS=""
	for replace_unit in one-node-firewall.path one-node-updater.path one-node.service; do
		if replace_unit_is_enabled "$replace_unit"; then
			REPLACE_ENABLED_UNITS="${REPLACE_ENABLED_UNITS} ${replace_unit}"
		fi
	done
	REPLACE_RUNTIME_WAS_ACTIVE="false"
	case "$REPLACE_PREVIOUS_MODE" in
	native)
		if command -v systemctl >/dev/null 2>&1 &&
			systemctl is-active --quiet one-node.service >/dev/null 2>&1; then
			REPLACE_RUNTIME_WAS_ACTIVE="true"
		fi
		;;
	docker)
		if command -v docker >/dev/null 2>&1 &&
			docker inspect -f '{{.State.Running}}' "$CONTAINER_NAME" 2>/dev/null | grep -qx true; then
			REPLACE_RUNTIME_WAS_ACTIVE="true"
		fi
		;;
	esac

	if command -v systemctl >/dev/null 2>&1; then
		systemctl disable --now one-node.service >/dev/null 2>&1 || true
		systemctl disable --now one-node-firewall.path >/dev/null 2>&1 || true
		systemctl disable --now one-node-updater.path >/dev/null 2>&1 || true
	fi
	if command -v docker >/dev/null 2>&1; then
		if [ "$REPLACE_PREVIOUS_MODE" = "docker" ] && [ -f "$COMPOSE_FILE" ] && [ ! -L "$COMPOSE_FILE" ]; then
			docker compose -f "$COMPOSE_FILE" down --remove-orphans >/dev/null 2>&1 || true
		fi
		docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
	fi
	# ufw/firewalld rules are re-added from the next runtime's port request.
	remove_host_firewall_rules
	if command -v nft >/dev/null 2>&1; then
		nft delete table inet one_node >/dev/null 2>&1 || true
	fi
}

replace_existing_installation() {
	[ "$INSTALL_OPERATION" = "replace" ] || return 0
	log "moving the existing ${MANIFEST_MODE} installation aside before applying the new installation command"
	if [ "$INSTALL_MANIFEST_KIND" = "current" ]; then
		preflight_owned_paths
	fi
	REPLACE_PREVIOUS_MODE=$MANIFEST_MODE
	REPLACE_PREVIOUS_STATE_DIR=${MANIFEST_STATE_DIR:-$ONE_NODE_STATE_DIR}
	REPLACE_PREVIOUS_KIND=$INSTALL_MANIFEST_KIND
	REPLACE_SWITCHED="false"
	REPLACE_BACKUP_COUNT=0
	replace_backup_parent=$(dirname "$INSTALL_DIR")
	install -d -m 0755 "$replace_backup_parent"
	REPLACE_BACKUP_DIR=$(mktemp -d "${replace_backup_parent}/.one-node-replace.XXXXXX") ||
		die "unable to create the previous installation backup directory"
	chmod 0700 "$REPLACE_BACKUP_DIR"
	: >"${REPLACE_BACKUP_DIR}/moved"
	: >"${REPLACE_BACKUP_DIR}/directories"
	trap on_replace_install_exit EXIT
	trap 'exit 1' HUP INT TERM

	stop_replaced_runtime
	if [ "$REPLACE_PREVIOUS_KIND" = "current" ]; then
		replace_backup_old_ifs=$IFS
		IFS='
'
		for owned_path in $MANIFEST_OWNED_PATHS; do
			case "$(uninstall_path_kind "$owned_path")" in
			file) replace_backup_path "$owned_path" ;;
			directory)
				[ "$owned_path" = "$MANIFEST_INSTALL_DIR" ] || replace_record_directory "$owned_path"
				;;
			esac
		done
		IFS=$replace_backup_old_ifs
		replace_backup_path "$REPLACE_PREVIOUS_STATE_DIR"
		if manifest_has_owned_path "$MANIFEST_PREVIOUS_DIR"; then
			rmdir -- "$MANIFEST_PREVIOUS_DIR" 2>/dev/null || true
		fi
	else
		replace_backup_path "$INSTALL_DIR"
		replace_backup_path "$ONE_NODE_STATE_DIR"
		replace_backup_path "$UNIT_FILE"
	fi
	# Host units outside the manifest are overwritten by the new installation.
	for replace_host_file in \
		"${FIREWALL_FILE:-}" "${FIREWALL_SERVICE_FILE:-}" "${FIREWALL_PATH_FILE:-}" \
		"${UPDATER_FILE:-}" "${UPDATER_SERVICE_FILE:-}" "${UPDATER_PATH_FILE:-}"
	do
		replace_backup_path "$replace_host_file"
	done
	if command -v systemctl >/dev/null 2>&1; then
		systemctl daemon-reload
	fi

	manifest_reset
	INSTALL_MANIFEST_KIND=""
	INSTALL_OPERATION="fresh"
	SHOW_UNINSTALL_ON_ERROR="false"
	REPLACE_SWITCHED="true"
	log "previous One Node program, identity, runtime state, and pending telemetry were moved to ${REPLACE_BACKUP_DIR}; they are restored if the new installation fails"
}

# Removes whatever the new installation left at the shared paths so the backup
# can be moved back; called only after the switch to the new installation.
remove_replacement_installation() {
	if command -v systemctl >/dev/null 2>&1; then
		systemctl disable --now one-node.service >/dev/null 2>&1
		systemctl disable --now one-node-updater.path >/dev/null 2>&1
	fi
	if command -v docker >/dev/null 2>&1; then
		docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1
	fi
	remove_host_firewall
	if [ "$INSTALL_MODE" = "native" ]; then
		rm -f -- "${BINARY_FILE:-}" "$UNIT_FILE"
	else
		rm -f -- "$COMPOSE_FILE"
	fi
	rm -f -- "$MANIFEST_INSTALLER_PATH" "$ENV_FILE" "$INSTALL_RECORD" \
		"${FIREWALL_FILE:-}" "${FIREWALL_SERVICE_FILE:-}" "${FIREWALL_PATH_FILE:-}" \
		"${UPDATER_FILE:-}" "${UPDATER_SERVICE_FILE:-}" "${UPDATER_PATH_FILE:-}"
	if [ "$ONE_NODE_STATE_DIR" = "$REPLACE_PREVIOUS_STATE_DIR" ] ||
		[ "${STATE_DIR_CREATED:-false}" = "true" ]; then
		rm -rf -- "$ONE_NODE_STATE_DIR"
	fi
}

restart_replaced_runtime() {
	restart_status=0
	command -v systemctl >/dev/null 2>&1 && systemctl daemon-reload >/dev/null 2>&1
	replaced_firewall_file=${FIREWALL_FILE:-${INSTALL_DIR}/firewall.sh}
	if [ -x "$replaced_firewall_file" ] && [ ! -L "$replaced_firewall_file" ] &&
		command -v nft >/dev/null 2>&1; then
		ONE_NODE_FIREWALL_DIR="${REPLACE_PREVIOUS_STATE_DIR}/firewall" "$replaced_firewall_file" --initialize ||
			restart_status=1
	fi
	for replace_unit in $REPLACE_ENABLED_UNITS; do
		systemctl enable --now "$replace_unit" >/dev/null 2>&1 || restart_status=1
	done
	[ "$REPLACE_RUNTIME_WAS_ACTIVE" = "true" ] || return "$restart_status"
	case "$REPLACE_PREVIOUS_MODE" in
	native)
		systemctl start one-node.service >/dev/null 2>&1 &&
			systemctl is-active --quiet one-node.service || restart_status=1
		;;
	docker)
		{ command -v docker >/dev/null 2>&1 &&
			docker compose -f "$COMPOSE_FILE" up -d >/dev/null 2>&1 &&
			docker inspect -f '{{.State.Running}}' "$CONTAINER_NAME" 2>/dev/null | grep -qx true; } ||
			restart_status=1
		;;
	esac
	return "$restart_status"
}

restore_replaced_installation() {
	[ -n "${REPLACE_BACKUP_DIR:-}" ] && [ -d "$REPLACE_BACKUP_DIR" ] || return 0
	restore_status=0
	log "restoring the previous One Node installation from ${REPLACE_BACKUP_DIR}"
	if [ "$REPLACE_SWITCHED" = "true" ]; then
		remove_replacement_installation
	fi
	while IFS='|' read -r restore_kind restore_mode restore_path; do
		[ "$restore_kind" = d ] || continue
		[ -d "$restore_path" ] || install -d -m "$restore_mode" "$restore_path" || restore_status=1
	done <"${REPLACE_BACKUP_DIR}/directories"
	# Restore in reverse backup order; each entry replaces whatever now occupies its path.
	restore_entries=$(awk '{ lines[NR] = $0 } END { for (i = NR; i > 0; i--) print lines[i] }' \
		"${REPLACE_BACKUP_DIR}/moved")
	restore_old_ifs=$IFS
	IFS='
'
	for restore_entry in $restore_entries; do
		IFS=$restore_old_ifs
		restore_index=${restore_entry%%|*}
		restore_path=${restore_entry#*|}
		restore_parent=$(dirname "$restore_path")
		rm -rf -- "$restore_path"
		{ [ -d "$restore_parent" ] || install -d -m 0755 "$restore_parent"; } &&
			mv -f -- "${REPLACE_BACKUP_DIR}/${restore_index}" "$restore_path" || restore_status=1
	done
	IFS=$restore_old_ifs
	restart_replaced_runtime || restore_status=1
	if [ "$restore_status" -eq 0 ]; then
		rm -rf -- "$REPLACE_BACKUP_DIR"
		REPLACE_BACKUP_DIR=""
		log "the previous ${REPLACE_PREVIOUS_MODE} installation, identity, and runtime state were restored and restarted"
		return 0
	fi
	log "the previous installation could not be fully restored; its remaining files are kept in ${REPLACE_BACKUP_DIR}"
	return 1
}

discard_replaced_installation() {
	[ -n "${REPLACE_BACKUP_DIR:-}" ] && [ -d "$REPLACE_BACKUP_DIR" ] || return 0
	rm -rf -- "$REPLACE_BACKUP_DIR"
	REPLACE_BACKUP_DIR=""
	log "previous One Node program, identity, runtime state, and pending telemetry were removed"
}

# Wraps on_install_exit (which removes the failed new installation and the
# workspace) and then restores or discards the previous installation.
on_replace_install_exit() {
	replace_exit_status=$?
	trap - EXIT HUP INT TERM
	set +e
	if [ "${INSTALL_COMMITTED:-false}" = "true" ]; then
		if command -v on_install_exit >/dev/null 2>&1; then
			( (exit "$replace_exit_status"); on_install_exit )
		fi
		discard_replaced_installation
		exit "$replace_exit_status"
	fi
	[ "$replace_exit_status" -ne 0 ] || replace_exit_status=1
	if command -v on_install_exit >/dev/null 2>&1; then
		( (exit "$replace_exit_status"); on_install_exit )
	fi
	restore_replaced_installation
	exit "$replace_exit_status"
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
	# Modules must come from the same commit as the entrypoint.
	uninstall_shell="env ONE_ACTION_COMMIT='${action_commit}' sh"
	case "${ONE_NODE_RELEASE_BASE_URL:-}" in
	http://*)
		uninstall_url="${ONE_NODE_RELEASE_BASE_URL%/}/uninstall.sh"
		uninstall_protocols="'=http,https'"
		uninstall_shell="sh"
		;;
	esac
	printf '%s\n' \
		"[one-node] uninstall the current installation, then retry:" \
		"curl -fsSL --proto ${uninstall_protocols} --proto-redir ${uninstall_protocols} --tlsv1.2 '${uninstall_url}' | ${uninstall_shell} -s -- --mode '${uninstall_mode}'" >&2
}

validate_managed_native_unit() {
	[ -f "$UNIT_FILE" ] && [ ! -L "$UNIT_FILE" ] ||
		die "one-node.service is missing or unsafe"
	[ "$(file_mode "$UNIT_FILE")" = "644" ] ||
		die "one-node.service permissions must be 0644"
	for unit_record in \
		'EnvironmentFile=/opt/one-node/.env' \
		'ExecStart=/opt/one-node/one-node start'
	do
		[ "$(grep -Fxc "$unit_record" "$UNIT_FILE")" -eq 1 ] ||
			die "one-node.service is not a recognized One Node unit"
	done
	# Root-run units work in the install directory; service-account units work
	# in the state directory and hand it over with exactly one managed chown.
	[ "$(grep -c '^WorkingDirectory=' "$UNIT_FILE")" -eq 1 ] ||
		die "one-node.service is not a recognized One Node unit"
	managed_start_pre="ExecStartPre=+/bin/chown -hR one-node:one-node ${ONE_NODE_STATE_DIR}"
	if grep -Fxq 'WorkingDirectory=/opt/one-node' "$UNIT_FILE"; then
		unit_start_pre_count=0
	elif grep -Fxq "WorkingDirectory=${ONE_NODE_STATE_DIR}" "$UNIT_FILE"; then
		unit_start_pre_count=$(grep -Fxc "$managed_start_pre" "$UNIT_FILE" || true)
		[ "$unit_start_pre_count" -le 1 ] ||
			die "one-node.service contains unmanaged lifecycle commands"
	else
		die "one-node.service is not a recognized One Node unit"
	fi
	if [ "$(grep -Ec '^(ExecStartPre|ExecStartPost|ExecStop|ExecStopPost|ExecReload)=' "$UNIT_FILE" || true)" -ne "$unit_start_pre_count" ]; then
		die "one-node.service contains unmanaged lifecycle commands"
	fi
}

reset_existing_installation() {
	log "removing the existing One Node installation and runtime state"
	if command -v systemctl >/dev/null 2>&1; then
		systemctl disable --now one-node.service >/dev/null 2>&1 || true
	fi
	if command -v docker >/dev/null 2>&1; then
		docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
	fi
	if command -v nft >/dev/null 2>&1; then
		nft delete table inet one_node >/dev/null 2>&1 || true
	fi
	rm -f -- "$UNIT_FILE"
	rm -rf -- "$INSTALL_DIR" "$ONE_NODE_STATE_DIR"
	if command -v systemctl >/dev/null 2>&1; then
		systemctl daemon-reload
	fi
}

validate_node_state_files() {
	IDENTITY_FILE="${1}/node-secret"
	RUNTIME_STATE_FILE="${1}/runtime-active.json"
	for state_file in "$IDENTITY_FILE" "$RUNTIME_STATE_FILE"; do
		if [ -e "$state_file" ] || [ -L "$state_file" ]; then
			[ -f "$state_file" ] && [ ! -L "$state_file" ] ||
				die "existing node state file is unsafe: $state_file"
			[ "$(file_mode "$state_file")" = "600" ] ||
				die "existing node state file permissions must be 0600: $state_file"
		fi
	done
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

	validate_node_state_files "$ONE_NODE_STATE_DIR"

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
