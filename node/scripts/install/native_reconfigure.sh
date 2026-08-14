#!/bin/sh

# Installer globals are shared across sourced modules.
# shellcheck disable=SC2034

initialize_native_reconfiguration() {
	RECONFIGURE_TEMP_DIR=$(mktemp -d "/tmp/one-node-reconfigure.XXXXXX")
	chmod 0700 "$RECONFIGURE_TEMP_DIR"
	RECONFIGURE_ENV_BACKUP="${RECONFIGURE_TEMP_DIR}/.env.previous"
	RECONFIGURE_RECORD_BACKUP="${RECONFIGURE_TEMP_DIR}/installation.previous"
	RECONFIGURE_BINARY_BACKUP="${RECONFIGURE_TEMP_DIR}/one-node.previous"
	RECONFIGURE_UNIT_BACKUP="${RECONFIGURE_TEMP_DIR}/one-node.service.previous"
	RECONFIGURE_PREVIOUS_BINARY_BACKUP="${RECONFIGURE_TEMP_DIR}/rollback-binary.previous"
	RECONFIGURE_IDENTITY_BACKUP="${RECONFIGURE_TEMP_DIR}/node-secret.previous"
	RECONFIGURE_RUNTIME_STATE_BACKUP="${RECONFIGURE_TEMP_DIR}/runtime-active.previous"
	RECONFIGURE_ENV_EXISTED="false"
	RECONFIGURE_RECORD_EXISTED="false"
	RECONFIGURE_BINARY_EXISTED="false"
	RECONFIGURE_UNIT_EXISTED="false"
	RECONFIGURE_PREVIOUS_DIR_EXISTED="false"
	RECONFIGURE_PREVIOUS_BINARY_EXISTED="false"
	RECONFIGURE_IDENTITY_EXISTED="false"
	RECONFIGURE_RUNTIME_STATE_EXISTED="false"
	RECONFIGURE_SERVICE_ACTIVE="false"
	RECONFIGURE_SERVICE_ENABLED="false"
	RECONFIGURE_INSTALL_DIR_CREATED="false"
	RECONFIGURE_STATE_DIR_CREATED="false"
	RECONFIGURE_BINARY_CHANGED="false"
	RECONFIGURE_COMMITTED="false"

	if systemctl is-active --quiet one-node.service; then
		RECONFIGURE_SERVICE_ACTIVE="true"
	fi
	if systemctl is-enabled --quiet one-node.service; then
		RECONFIGURE_SERVICE_ENABLED="true"
	fi
	if [ -e "$ENV_FILE" ]; then
		install -m 0600 "$ENV_FILE" "$RECONFIGURE_ENV_BACKUP"
		RECONFIGURE_ENV_EXISTED="true"
	fi
	if [ -e "$INSTALL_RECORD" ]; then
		install -m 0600 "$INSTALL_RECORD" "$RECONFIGURE_RECORD_BACKUP"
		RECONFIGURE_RECORD_EXISTED="true"
	fi
	if [ -e "$MANIFEST_BINARY_PATH" ]; then
		install -m 0755 "$MANIFEST_BINARY_PATH" "$RECONFIGURE_BINARY_BACKUP"
		RECONFIGURE_BINARY_EXISTED="true"
	fi
	if [ -e "$UNIT_FILE" ]; then
		install -m 0644 "$UNIT_FILE" "$RECONFIGURE_UNIT_BACKUP"
		RECONFIGURE_UNIT_EXISTED="true"
	fi
	if [ -d "$MANIFEST_PREVIOUS_DIR" ] && [ ! -L "$MANIFEST_PREVIOUS_DIR" ]; then
		RECONFIGURE_PREVIOUS_DIR_EXISTED="true"
	fi
	if [ -e "$MANIFEST_PREVIOUS_BINARY_PATH_FIXED" ]; then
		[ -f "$MANIFEST_PREVIOUS_BINARY_PATH_FIXED" ] &&
			[ ! -L "$MANIFEST_PREVIOUS_BINARY_PATH_FIXED" ] ||
			die "previous native binary is unsafe"
		install -m 0755 "$MANIFEST_PREVIOUS_BINARY_PATH_FIXED" \
			"$RECONFIGURE_PREVIOUS_BINARY_BACKUP"
		RECONFIGURE_PREVIOUS_BINARY_EXISTED="true"
	fi
	if [ -e "$IDENTITY_FILE" ]; then
		install -m 0600 "$IDENTITY_FILE" "$RECONFIGURE_IDENTITY_BACKUP"
		RECONFIGURE_IDENTITY_EXISTED="true"
	fi
	if [ -e "$RUNTIME_STATE_FILE" ]; then
		install -m 0600 "$RUNTIME_STATE_FILE" "$RECONFIGURE_RUNTIME_STATE_BACKUP"
		RECONFIGURE_RUNTIME_STATE_EXISTED="true"
	fi

	trap on_native_reconfigure_exit EXIT
	trap 'exit 1' HUP INT TERM
}

restore_reconfiguration_file() {
	restore_existed=$1
	restore_backup=$2
	restore_target=$3
	restore_mode=$4
	if [ "$restore_existed" = "true" ]; then
		replace_managed_file "$restore_backup" "$restore_target" "$restore_mode"
	else
		rm -f -- "$restore_target"
	fi
}

restore_native_reconfiguration() {
	restore_status=0
	systemctl stop one-node.service >/dev/null 2>&1 || true
	restore_reconfiguration_file "$RECONFIGURE_BINARY_EXISTED" \
		"$RECONFIGURE_BINARY_BACKUP" "$MANIFEST_BINARY_PATH" 0755 || restore_status=1
	restore_reconfiguration_file "$RECONFIGURE_ENV_EXISTED" \
		"$RECONFIGURE_ENV_BACKUP" "$ENV_FILE" 0600 || restore_status=1
	restore_reconfiguration_file "$RECONFIGURE_RECORD_EXISTED" \
		"$RECONFIGURE_RECORD_BACKUP" "$INSTALL_RECORD" 0600 || restore_status=1
	restore_reconfiguration_file "$RECONFIGURE_UNIT_EXISTED" \
		"$RECONFIGURE_UNIT_BACKUP" "$UNIT_FILE" 0644 || restore_status=1
	restore_reconfiguration_file "$RECONFIGURE_PREVIOUS_BINARY_EXISTED" \
		"$RECONFIGURE_PREVIOUS_BINARY_BACKUP" \
		"$MANIFEST_PREVIOUS_BINARY_PATH_FIXED" 0755 || restore_status=1
	restore_reconfiguration_file "$RECONFIGURE_IDENTITY_EXISTED" \
		"$RECONFIGURE_IDENTITY_BACKUP" "$IDENTITY_FILE" 0600 || restore_status=1
	restore_reconfiguration_file "$RECONFIGURE_RUNTIME_STATE_EXISTED" \
		"$RECONFIGURE_RUNTIME_STATE_BACKUP" "$RUNTIME_STATE_FILE" 0600 || restore_status=1

	if [ "$RECONFIGURE_PREVIOUS_DIR_EXISTED" != "true" ]; then
		rmdir -- "$MANIFEST_PREVIOUS_DIR" 2>/dev/null || true
	fi
	if [ "$RECONFIGURE_INSTALL_DIR_CREATED" = "true" ]; then
		rmdir -- "$INSTALL_DIR" 2>/dev/null || true
	fi
	if [ "$RECONFIGURE_STATE_DIR_CREATED" = "true" ]; then
		rmdir -- "$ONE_NODE_STATE_DIR" 2>/dev/null || true
	fi

	systemctl daemon-reload >/dev/null 2>&1 || restore_status=1
	if [ "$RECONFIGURE_UNIT_EXISTED" = "true" ]; then
		if [ "$RECONFIGURE_SERVICE_ENABLED" = "true" ]; then
			systemctl enable one-node.service >/dev/null 2>&1 || restore_status=1
		else
			systemctl disable one-node.service >/dev/null 2>&1 || restore_status=1
		fi
		if [ "$RECONFIGURE_SERVICE_ACTIVE" = "true" ]; then
			systemctl start one-node.service >/dev/null 2>&1 || restore_status=1
		fi
	else
		systemctl disable one-node.service >/dev/null 2>&1 || true
	fi
	return "$restore_status"
}

on_native_reconfigure_exit() {
	reconfigure_status=$?
	trap - EXIT HUP INT TERM
	if [ "$RECONFIGURE_COMMITTED" != "true" ]; then
		[ "$reconfigure_status" -ne 0 ] || reconfigure_status=1
		set +e
		restore_native_reconfiguration
		restore_status=$?
		set -e
		if [ "$restore_status" -ne 0 ]; then
			log "registration update failed and the previous installation could not be fully restored"
		else
			log "registration update failed; the previous installation was restored"
		fi
	fi
	rm -rf -- "$RECONFIGURE_TEMP_DIR"
	if [ -n "${TEMP_DIR:-}" ] && [ "$TEMP_DIR" != "$RECONFIGURE_TEMP_DIR" ]; then
		rm -rf -- "$TEMP_DIR"
	fi
	exit "$reconfigure_status"
}

prepare_native_reconfiguration_directories() {
	if [ ! -e "$INSTALL_DIR" ]; then
		install -d -m 0755 "$INSTALL_DIR"
		RECONFIGURE_INSTALL_DIR_CREATED="true"
	else
		[ -d "$INSTALL_DIR" ] && [ ! -L "$INSTALL_DIR" ] ||
			die "installation directory is unsafe"
	fi
	if [ ! -e "$ONE_NODE_STATE_DIR" ]; then
		install -d -m 0700 "$ONE_NODE_STATE_DIR"
		RECONFIGURE_STATE_DIR_CREATED="true"
	else
		[ -d "$ONE_NODE_STATE_DIR" ] && [ ! -L "$ONE_NODE_STATE_DIR" ] ||
			die "One Node state directory is unsafe"
		chmod 0700 "$ONE_NODE_STATE_DIR"
	fi
}

manifest_initialize_recovered_native() {
	manifest_reset
	MANIFEST_MODE="native"
	MANIFEST_STATE_DIR=$ONE_NODE_STATE_DIR
	for recovered_owned_path in \
		"$MANIFEST_INSTALL_DIR" "$MANIFEST_ENV_PATH" "$MANIFEST_RECORD_PATH" \
		"$MANIFEST_STATE_DIR" "$MANIFEST_BINARY_PATH" "$MANIFEST_UNIT_PATH"
	do
		manifest_append_owned_path "$recovered_owned_path" ||
			die "unable to construct the recovered installation manifest"
	done
	MANIFEST_OWNED_COUNT=6
}

prepare_native_reconfiguration_manifest() {
	if [ "$INSTALL_MANIFEST_KIND" = "current" ]; then
		MANIFEST_FORMAT=$MANIFEST_FORMAT_NAME
		if [ "$RECONFIGURE_BINARY_CHANGED" = "true" ]; then
			[ ! -L "$MANIFEST_PREVIOUS_DIR" ] || die "previous runtime directory is unsafe"
			install -d -m 0755 "$MANIFEST_PREVIOUS_DIR"
			replace_managed_file "$RECONFIGURE_BINARY_BACKUP" \
				"$MANIFEST_PREVIOUS_BINARY_PATH_FIXED" 0755 ||
				die "unable to preserve the previous native binary"
			MANIFEST_PREVIOUS_VERSION=$MANIFEST_CURRENT_VERSION
			MANIFEST_PREVIOUS_BINARY_PATH=$MANIFEST_PREVIOUS_BINARY_PATH_FIXED
			MANIFEST_PREVIOUS_BINARY_SHA256=$MANIFEST_CURRENT_BINARY_SHA256
			MANIFEST_PREVIOUS_IMAGE=""
			if ! manifest_has_owned_path "$MANIFEST_PREVIOUS_DIR"; then
				manifest_append_owned_path "$MANIFEST_PREVIOUS_DIR" ||
					die "unable to record the previous runtime directory"
				MANIFEST_OWNED_COUNT=$((MANIFEST_OWNED_COUNT + 1))
			fi
			if ! manifest_has_owned_path "$MANIFEST_PREVIOUS_BINARY_PATH_FIXED"; then
				manifest_append_owned_path "$MANIFEST_PREVIOUS_BINARY_PATH_FIXED" ||
					die "unable to record the previous native binary"
				MANIFEST_OWNED_COUNT=$((MANIFEST_OWNED_COUNT + 1))
			fi
		fi
	else
		manifest_initialize_recovered_native
	fi
	MANIFEST_FORMAT=$MANIFEST_FORMAT_NAME
	MANIFEST_DESIRED_CONFIG_REVISION=$ONE_NODE_EXPECTED_CONFIG_REVISION
	MANIFEST_DESIRED_BINDINGS_REVISION=$ONE_NODE_EXPECTED_BINDINGS_REVISION
	MANIFEST_CURRENT_VERSION=$ONE_NODE_VERSION
	MANIFEST_CURRENT_BINARY_PATH=$MANIFEST_BINARY_PATH
	MANIFEST_CURRENT_BINARY_SHA256=$ONE_NODE_BINARY_SHA256
	MANIFEST_CURRENT_IMAGE=""
}

reconfigure_native_installation() {
	initialize_native_reconfiguration
	prepare_native_reconfiguration_directories
	ENV_SOURCE="${RECONFIGURE_TEMP_DIR}/.env.next"
	write_environment_source

	current_binary_sha256=""
	if [ "$RECONFIGURE_BINARY_EXISTED" = "true" ]; then
		current_binary_sha256=$(sha256sum "$MANIFEST_BINARY_PATH" | awk '{ print $1 }')
	fi
	if [ "$current_binary_sha256" != "$ONE_NODE_BINARY_SHA256" ]; then
		RECONFIGURE_BINARY_CHANGED="true"
	fi
	prepare_native_reconfiguration_manifest

	systemctl stop one-node.service || die "unable to stop the existing native runtime"
	if [ "$RECONFIGURE_BINARY_CHANGED" = "true" ]; then
		replace_managed_file "$BINARY_SOURCE" "$MANIFEST_BINARY_PATH" 0755 ||
			die "unable to replace the native runtime binary"
		log "native runtime upgraded to One Node product version $ONE_NODE_VERSION"
	else
		log "native runtime One Node product version $ONE_NODE_VERSION is already current"
	fi
	replace_managed_file "$ENV_SOURCE" "$ENV_FILE" 0600 ||
		die "unable to replace the One Node environment"
	replace_managed_file "$UNIT_SOURCE" "$UNIT_FILE" 0644 ||
		die "unable to replace one-node.service"
	manifest_write "$INSTALL_RECORD" || die "unable to update the installation manifest"
	reset_registration_state_for_reenrollment
	restart_reconfigured_runtime || die "unable to restart the existing native runtime"
	wait_for_ready_heartbeat || die "existing installation did not accept the updated registration"

	RECONFIGURE_COMMITTED="true"
	log "existing native installation is registered as node $ONE_NODE_ID"
}
