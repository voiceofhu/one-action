#!/bin/sh

# Fresh-install workspace and exact file ownership. Upgrade rollback is A03.
# shellcheck disable=SC2034

initialize_install_workspace() {
	TEMP_DIR=$(mktemp -d "/tmp/one-node-install.XXXXXX")
	chmod 0700 "$TEMP_DIR"
	[ -f "$ONE_NODE_INSTALLER_SOURCE" ] && [ ! -L "$ONE_NODE_INSTALLER_SOURCE" ] ||
		die "installer source is missing or unsafe"
	install -m 0700 "$ONE_NODE_INSTALLER_SOURCE" "${TEMP_DIR}/install.sh"
	ONE_NODE_INSTALLER_SOURCE="${TEMP_DIR}/install.sh"
	if command -v entrypoint_cleanup >/dev/null 2>&1; then
		entrypoint_cleanup
		ONE_NODE_ENTRYPOINT_TEMP_DIR=""
	fi
	BINARY_SOURCE="${TEMP_DIR}/${PROGRAM}"
	ENV_SOURCE="${TEMP_DIR}/${PROGRAM}.env"
	UNIT_SOURCE="${TEMP_DIR}/${PROGRAM}.service"
	COMPOSE_SOURCE="${TEMP_DIR}/docker-compose.yml"
	RECORD_SOURCE="${TEMP_DIR}/.installation"
	BINARY_FILE="${INSTALL_DIR}/${PROGRAM}"
	IDENTITY_FILE="${ONE_NODE_STATE_DIR}/node-secret"
	RUNTIME_STATE_FILE="${ONE_NODE_STATE_DIR}/runtime-active.json"
	INSTALL_STARTED="false"
	INSTALL_COMMITTED="false"
	STATE_DIR_CREATED="false"
	trap on_install_exit EXIT
	trap 'exit 1' HUP INT TERM
}

on_install_exit() {
	exit_status=$?
	trap - EXIT HUP INT TERM
	if [ "$INSTALL_STARTED" = "true" ] && [ "$INSTALL_COMMITTED" != "true" ]; then
		set +e
		if [ "$INSTALL_MODE" = "native" ]; then
			systemctl disable --now one-node.service >/dev/null 2>&1
			rm -f -- "$UNIT_FILE"
			systemctl daemon-reload >/dev/null 2>&1
		else
			if command -v docker >/dev/null 2>&1; then
				docker compose -f "$COMPOSE_FILE" down --remove-orphans >/dev/null 2>&1
				docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1
			fi
		fi
		rm -f -- "$BINARY_FILE" "$MANIFEST_INSTALLER_PATH" "$ENV_FILE" "$COMPOSE_FILE" "$INSTALL_RECORD"
		if [ "$STATE_DIR_CREATED" = "true" ]; then
			rmdir -- "$ONE_NODE_STATE_DIR" 2>/dev/null || true
		fi
		set -e
		log "installation did not become ready; credential state was preserved for a safe retry"
	fi
	rm -rf -- "$TEMP_DIR"
	exit "$exit_status"
}

prepare_native_binary() {
	log "downloading ${ONE_NODE_BINARY_NAME}"
	if [ -z "$ONE_NODE_BINARY_SHA256" ]; then
		checksum_source="${TEMP_DIR}/SHA256SUMS"
		download_file "${ONE_NODE_RELEASE_BASE_URL%/}/SHA256SUMS" "$checksum_source"
		ONE_NODE_BINARY_SHA256=$(awk -v name="$ONE_NODE_BINARY_NAME" '
			$2 == name || $2 == "*" name {
				if (found++) { exit 1 }
				value = tolower($1)
			}
			END {
				if (found != 1) exit 1
				print value
			}
		' "$checksum_source") || die "release checksum is missing ${ONE_NODE_BINARY_NAME}"
		validate_sha256 "$ONE_NODE_BINARY_SHA256" ||
			die "release checksum for ${ONE_NODE_BINARY_NAME} is invalid"
	fi
	download_file "$ONE_NODE_BINARY_URL" "$BINARY_SOURCE"
	actual_sha256=$(sha256sum "$BINARY_SOURCE" | awk '{ print $1 }')
	[ "$actual_sha256" = "$ONE_NODE_BINARY_SHA256" ] ||
		die "binary SHA256 verification failed"
	chmod 0755 "$BINARY_SOURCE"
	product_version=$("$BINARY_SOURCE" version --product-name) ||
		die "downloaded binary cannot report its One Node product version"
	set_product_version "$product_version" "downloaded binary"
}

set_product_version() {
	product_version=$1
	asset_name=$2
	manifest_validate_version "$product_version" ||
		die "$asset_name returned an invalid One Node product version"
	if [ -n "$ONE_NODE_VERSION" ] && [ "$ONE_NODE_VERSION" != "$product_version" ]; then
		die "$asset_name One Node product version $product_version does not match requested release $ONE_NODE_VERSION"
	fi
	ONE_NODE_VERSION=$product_version
}

write_environment_source() {
	: >"$ENV_SOURCE"
	chmod 0600 "$ENV_SOURCE"
	write_env "NODE_NODE_ID" "$ONE_NODE_ID"
	write_env "NODE_HEARTBEAT_INTERVAL" "60s"
	write_env "NODE_STATE_DIR" "$ONE_NODE_STATE_DIR"
	write_env "CONTROL_ADDR" "$ONE_NODE_SERVER"
	write_env "CONTROL_BOOTSTRAP_TOKEN" "$ONE_NODE_BOOTSTRAP_TOKEN"
	write_env "CONTROL_BOOTSTRAP_ENV_FILE" "$ENV_FILE"
	write_env "LOG_LEVEL" "info"
}

write_common_sources() {
	write_environment_source

	manifest_reset
	MANIFEST_FORMAT=$MANIFEST_FORMAT_NAME
	MANIFEST_MODE=$INSTALL_MODE
	MANIFEST_STATE_DIR=$ONE_NODE_STATE_DIR
	MANIFEST_DESIRED_CONFIG_REVISION=$ONE_NODE_EXPECTED_CONFIG_REVISION
	MANIFEST_CURRENT_VERSION=$ONE_NODE_VERSION
	if [ "$INSTALL_MODE" = "native" ]; then
		MANIFEST_CURRENT_BINARY_PATH=$MANIFEST_BINARY_PATH
		MANIFEST_CURRENT_BINARY_SHA256=$ONE_NODE_BINARY_SHA256
	else
		MANIFEST_CURRENT_IMAGE=$ONE_NODE_DOCKER_IMAGE
	fi
	manifest_append_owned_path "$MANIFEST_INSTALL_DIR"
	manifest_append_owned_path "$MANIFEST_INSTALLER_PATH"
	manifest_append_owned_path "$MANIFEST_ENV_PATH"
	manifest_append_owned_path "$MANIFEST_RECORD_PATH"
	if [ "$STATE_DIR_CREATED" = "true" ]; then
		manifest_append_owned_path "$MANIFEST_STATE_DIR"
	fi
	if [ "$INSTALL_MODE" = "native" ]; then
		manifest_append_owned_path "$MANIFEST_BINARY_PATH"
		manifest_append_owned_path "$MANIFEST_UNIT_PATH"
	else
		manifest_append_owned_path "$MANIFEST_COMPOSE_PATH"
	fi
	MANIFEST_OWNED_COUNT=$(printf '%s\n' "$MANIFEST_OWNED_PATHS" | awk 'NF { count++ } END { print count + 0 }')
	manifest_write "$RECORD_SOURCE" || die "unable to write the installation manifest"
}

prepare_install_directories() {
	install -d -m 0755 "$INSTALL_DIR"
	if [ -e "$ONE_NODE_STATE_DIR" ]; then
		[ -d "$ONE_NODE_STATE_DIR" ] && [ ! -L "$ONE_NODE_STATE_DIR" ] ||
			die "ONE_NODE_STATE_DIR must be a real directory"
		chmod 0700 "$ONE_NODE_STATE_DIR"
	else
		install -d -m 0700 "$ONE_NODE_STATE_DIR"
		STATE_DIR_CREATED="true"
	fi
}

install_common_files() {
	INSTALL_STARTED="true"
	install_persistent_installer
	if [ "$INSTALL_MODE" = "native" ]; then
		install -m 0755 "$BINARY_SOURCE" "$BINARY_FILE"
	fi
	install -m 0600 "$ENV_SOURCE" "$ENV_FILE"
	install -m 0600 "$RECORD_SOURCE" "$INSTALL_RECORD"
}

install_persistent_installer() {
	[ -f "$ONE_NODE_INSTALLER_SOURCE" ] && [ ! -L "$ONE_NODE_INSTALLER_SOURCE" ] ||
		die "installer source is missing or unsafe"
	install -m 0755 "$ONE_NODE_INSTALLER_SOURCE" "$MANIFEST_INSTALLER_PATH" ||
		die "unable to install the persistent installer"
	if [ -f "$INSTALL_RECORD" ] && ! manifest_has_owned_path "$MANIFEST_INSTALLER_PATH"; then
		manifest_append_owned_path "$MANIFEST_INSTALLER_PATH" ||
			die "unable to record the persistent installer"
		MANIFEST_OWNED_COUNT=$((MANIFEST_OWNED_COUNT + 1))
		manifest_write "$INSTALL_RECORD" || die "unable to update the installation manifest"
	fi
}

replace_managed_file() {
	replacement_source=$1
	replacement_target=$2
	replacement_mode=$3
	replacement_temp=$(mktemp "${replacement_target}.XXXXXX") || return 1
	if ! install -m "$replacement_mode" "$replacement_source" "$replacement_temp" ||
		! sync -f "$replacement_temp" ||
		! mv -f -- "$replacement_temp" "$replacement_target"; then
		rm -f -- "$replacement_temp"
		return 1
	fi
	sync -f "$(dirname "$replacement_target")"
}

restart_reconfigured_runtime() {
	case "$INSTALL_MODE" in
	native)
		systemctl daemon-reload &&
			systemctl enable one-node.service &&
			systemctl restart one-node.service &&
			systemctl is-active --quiet one-node.service
		;;
	docker)
		docker compose -f "$COMPOSE_FILE" up -d --force-recreate &&
			docker inspect -f '{{.State.Running}}' "$CONTAINER_NAME" | grep -qx true
		;;
	*) return 1 ;;
	esac
}

reset_registration_state_for_reenrollment() {
	previous_node_id=""
	if [ -f "$RECONFIGURE_ENV_BACKUP" ] && [ ! -L "$RECONFIGURE_ENV_BACKUP" ]; then
		previous_node_id=$(sed -n 's/^NODE_NODE_ID="\([1-9][0-9]*\)"$/\1/p' \
			"$RECONFIGURE_ENV_BACKUP")
	fi
	discarded_spools=""
	for spool_name in traffic-spool access-event-spool; do
		spool_dir="${ONE_NODE_STATE_DIR}/${spool_name}"
		[ -e "$spool_dir" ] || continue
		[ -d "$spool_dir" ] && [ ! -L "$spool_dir" ] ||
			die "existing ${spool_name} directory is unsafe"
		spool_node_id=""
		pending_file="${spool_dir}/pending.jsonl"
		if [ -e "$pending_file" ]; then
			[ -f "$pending_file" ] && [ ! -L "$pending_file" ] ||
				die "existing ${spool_name} pending file is unsafe"
			spool_node_id=$(sed -n \
				's/^.*"report_key":"\([1-9][0-9]*\):[^\"]*".*$/\1/p' \
				"$pending_file" | sed -n '1p')
		fi
		if { [ -n "$previous_node_id" ] && [ "$previous_node_id" != "$ONE_NODE_ID" ]; } ||
			{ [ -n "$spool_node_id" ] && [ "$spool_node_id" != "$ONE_NODE_ID" ]; }; then
			rm -rf -- "$spool_dir"
			discarded_spools="${discarded_spools} ${spool_name}"
		fi
	done
	if [ -n "$discarded_spools" ]; then
		log "discarded telemetry spool(s)${discarded_spools} before reconnecting as node $ONE_NODE_ID"
	fi
	rm -f -- "$IDENTITY_FILE" "$RUNTIME_STATE_FILE" ||
		die "unable to reset the previous node registration state"
	log "reset previous registration state; reconnecting as node $ONE_NODE_ID"
}

restore_reconfiguration() {
	restore_status=0
	replace_managed_file "$RECONFIGURE_ENV_BACKUP" "$ENV_FILE" 0600 || restore_status=1
	replace_managed_file "$RECONFIGURE_RECORD_BACKUP" "$INSTALL_RECORD" 0600 || restore_status=1
	if [ "$RECONFIGURE_IDENTITY_EXISTED" = "true" ]; then
		replace_managed_file "$RECONFIGURE_IDENTITY_BACKUP" "$IDENTITY_FILE" 0600 || restore_status=1
	else
		rm -f -- "$IDENTITY_FILE" || restore_status=1
	fi
	if [ "$RECONFIGURE_RUNTIME_STATE_EXISTED" = "true" ]; then
		replace_managed_file "$RECONFIGURE_RUNTIME_STATE_BACKUP" "$RUNTIME_STATE_FILE" 0600 || restore_status=1
	else
		rm -f -- "$RUNTIME_STATE_FILE" || restore_status=1
	fi
	restart_reconfigured_runtime || restore_status=1
	return "$restore_status"
}

on_reconfigure_exit() {
	reconfigure_status=$?
	trap - EXIT HUP INT TERM
	if [ "$RECONFIGURE_COMMITTED" != "true" ]; then
		[ "$reconfigure_status" -ne 0 ] || reconfigure_status=1
		set +e
		restore_reconfiguration
		restore_status=$?
		set -e
		if [ "$restore_status" -ne 0 ]; then
			log "registration update failed and the previous installation could not be fully restored"
		elif [ "$reconfigure_status" -ne 0 ]; then
			log "registration update failed; the previous installation was restored"
		fi
	fi
	rm -rf -- "$RECONFIGURE_TEMP_DIR"
	exit "$reconfigure_status"
}

reconfigure_existing_installation() {
	RECONFIGURE_TEMP_DIR=$(mktemp -d "/tmp/one-node-reconfigure.XXXXXX")
	chmod 0700 "$RECONFIGURE_TEMP_DIR"
	RECONFIGURE_ENV_BACKUP="${RECONFIGURE_TEMP_DIR}/.env.previous"
	RECONFIGURE_RECORD_BACKUP="${RECONFIGURE_TEMP_DIR}/installation.previous"
	RECONFIGURE_IDENTITY_BACKUP="${RECONFIGURE_TEMP_DIR}/node-secret.previous"
	RECONFIGURE_RUNTIME_STATE_BACKUP="${RECONFIGURE_TEMP_DIR}/runtime-active.previous"
	RECONFIGURE_IDENTITY_EXISTED="false"
	RECONFIGURE_RUNTIME_STATE_EXISTED="false"
	RECONFIGURE_COMMITTED="false"

	install -m 0600 "$ENV_FILE" "$RECONFIGURE_ENV_BACKUP"
	install -m 0600 "$INSTALL_RECORD" "$RECONFIGURE_RECORD_BACKUP"
	if [ -e "$IDENTITY_FILE" ]; then
		install -m 0600 "$IDENTITY_FILE" "$RECONFIGURE_IDENTITY_BACKUP"
		RECONFIGURE_IDENTITY_EXISTED="true"
	fi
	if [ -e "$RUNTIME_STATE_FILE" ]; then
		install -m 0600 "$RUNTIME_STATE_FILE" "$RECONFIGURE_RUNTIME_STATE_BACKUP"
		RECONFIGURE_RUNTIME_STATE_EXISTED="true"
	fi
	trap on_reconfigure_exit EXIT
	trap 'exit 1' HUP INT TERM

	ENV_SOURCE="${RECONFIGURE_TEMP_DIR}/.env.next"
	write_environment_source
	replace_managed_file "$ENV_SOURCE" "$ENV_FILE" 0600 ||
		die "unable to replace the One Node environment"
	MANIFEST_DESIRED_CONFIG_REVISION=$ONE_NODE_EXPECTED_CONFIG_REVISION
	manifest_write "$INSTALL_RECORD" || die "unable to update the installation manifest"
	reset_registration_state_for_reenrollment
	restart_reconfigured_runtime || die "unable to restart the existing $INSTALL_MODE runtime"
	wait_for_ready_heartbeat || die "existing installation did not accept the updated registration"

	RECONFIGURE_COMMITTED="true"
	log "existing $INSTALL_MODE installation is registered as node $ONE_NODE_ID"
}
