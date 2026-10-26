#!/bin/sh

stage_native_upgrade() {
	prepare_native_binary || return 1
	[ ! -L "$STAGED_BINARY" ] || return 1
	install -m 0755 "$BINARY_SOURCE" "$STAGED_BINARY" || return 1
	staged_sha256=$(sha256sum "$STAGED_BINARY" | awk '{ print $1 }')
	[ "$staged_sha256" = "$ONE_NODE_BINARY_SHA256" ] || return 1
	sync -f "$STAGED_BINARY" || return 1
	sync -f "$INSTALL_DIR"
}

# Installs that predate the unprivileged runtime kept the bootstrap token in
# the root-owned install directory, where the service account cannot remove
# it; move it (and the pointer to it) into the state directory.
migrate_native_bootstrap_environment() {
	bootstrap_env="${ONE_NODE_STATE_DIR}/bootstrap.env"
	bootstrap_pointer="CONTROL_BOOTSTRAP_ENV_FILE=\"${bootstrap_env}\""
	[ ! -L "$bootstrap_env" ] || return 1
	if [ -e "$bootstrap_env" ]; then
		[ -f "$bootstrap_env" ] || return 1
	fi
	token_source="${UPGRADE_TEMP_DIR}/bootstrap.env.next"
	: >"$token_source" || return 1
	chmod 0600 "$token_source" || return 1
	grep '^CONTROL_BOOTSTRAP_TOKEN=' "$ENV_FILE" >>"$token_source" || true
	if [ -s "$token_source" ]; then
		replace_managed_file "$token_source" "$bootstrap_env" 0600 || return 1
	elif [ ! -e "$bootstrap_env" ]; then
		install -m 0600 "$token_source" "$bootstrap_env" || return 1
	fi
	if grep -Fx "$bootstrap_pointer" "$ENV_FILE" >/dev/null &&
		! grep '^CONTROL_BOOTSTRAP_TOKEN=' "$ENV_FILE" >/dev/null; then
		return 0
	fi
	env_source="${UPGRADE_TEMP_DIR}/.env.next"
	sed '/^CONTROL_BOOTSTRAP_ENV_FILE=/d; /^CONTROL_BOOTSTRAP_TOKEN=/d' "$ENV_FILE" >"$env_source" || return 1
	chmod 0600 "$env_source" || return 1
	printf '%s\n' "$bootstrap_pointer" >>"$env_source" || return 1
	replace_managed_file "$env_source" "$ENV_FILE" 0600
}

# Runs while the old process is still up, so a failure leaves it serving; the
# rewritten unit takes effect at the restart below and also covers rollbacks.
migrate_native_service_hardening() {
	ensure_native_service_user || return 1
	migrate_native_bootstrap_environment || return 1
	install -d -m 0700 "${ONE_NODE_STATE_DIR}/firewall" || return 1
	if [ "${HOST_UPDATER_ENABLED:-false}" = "true" ]; then
		install -d -m 0700 "${ONE_NODE_STATE_DIR}/update" || return 1
	fi
	UNIT_SOURCE="${UPGRADE_TEMP_DIR}/one-node.service"
	write_native_source
	replace_managed_file "$UNIT_SOURCE" "$UNIT_FILE" 0644 || return 1
	systemctl daemon-reload
}

switch_native_runtime() {
	migrate_native_service_hardening || return 1
	[ ! -L "$MANIFEST_PREVIOUS_DIR" ] || return 1
	install -d -m 0755 "$MANIFEST_PREVIOUS_DIR" || return 1
	[ ! -L "$MANIFEST_PREVIOUS_BINARY_PATH_FIXED" ] || return 1
	prior_previous="${MANIFEST_PREVIOUS_DIR}/.one-node.prior"
	[ ! -L "$prior_previous" ] || return 1
	had_prior_previous="false"
	if [ -n "$MANIFEST_PREVIOUS_VERSION" ]; then
		install -m 0755 "$MANIFEST_PREVIOUS_BINARY_PATH_FIXED" "$prior_previous" || return 1
		sync -f "$prior_previous" || return 1
		had_prior_previous="true"
	fi
	previous_temp="${MANIFEST_PREVIOUS_DIR}/.one-node.previous"
	[ ! -L "$previous_temp" ] || return 1
	install -m 0755 "$MANIFEST_BINARY_PATH" "$previous_temp" || return 1
	previous_sha256=$(sha256sum "$previous_temp" | awk '{ print $1 }')
	[ "$previous_sha256" = "$MANIFEST_CURRENT_BINARY_SHA256" ] || return 1
	sync -f "$previous_temp" || return 1
	if ! mv -f -- "$previous_temp" "$MANIFEST_PREVIOUS_BINARY_PATH_FIXED" ||
		! sync -f "$MANIFEST_PREVIOUS_DIR"; then
		if [ "$had_prior_previous" = true ]; then
			mv -f -- "$prior_previous" "$MANIFEST_PREVIOUS_BINARY_PATH_FIXED" || true
		else
			rm -f -- "$MANIFEST_PREVIOUS_BINARY_PATH_FIXED"
		fi
		return 1
	fi
	if ! record_native_previous_checkpoint; then
		if ! manifest_load "$INSTALL_RECORD" ||
			[ "$MANIFEST_CURRENT_BINARY_SHA256" != "$UPGRADE_OLD_BINARY_SHA256" ] ||
			[ "$MANIFEST_PREVIOUS_BINARY_SHA256" != "$UPGRADE_OLD_BINARY_SHA256" ]; then
			if [ "$had_prior_previous" = true ]; then
				mv -f -- "$prior_previous" "$MANIFEST_PREVIOUS_BINARY_PATH_FIXED" || true
			else
				rm -f -- "$MANIFEST_PREVIOUS_BINARY_PATH_FIXED"
			fi
			return 1
		fi
	fi
	rm -f -- "$prior_previous"
	if ! record_upgrade_target; then
		if ! manifest_load "$INSTALL_RECORD" ||
			[ "$MANIFEST_CURRENT_VERSION" != "$ONE_NODE_VERSION" ] ||
			[ "$MANIFEST_CURRENT_BINARY_SHA256" != "$ONE_NODE_BINARY_SHA256" ]; then
			return 1
		fi
	fi
	UPGRADE_MANIFEST_ADVANCED="true"
	UPGRADE_SWITCHED="true"

	systemctl stop one-node.service || return 1
	if ! mv -f -- "$STAGED_BINARY" "$MANIFEST_BINARY_PATH"; then
		systemctl start one-node.service || true
		return 1
	fi
	sync -f "$MANIFEST_BINARY_PATH" || return 1
	systemctl start one-node.service
}

rollback_native_runtime() {
	[ -f "$MANIFEST_PREVIOUS_BINARY_PATH_FIXED" ] && [ ! -L "$MANIFEST_PREVIOUS_BINARY_PATH_FIXED" ] || return 1
	rollback_sha256=$(sha256sum "$MANIFEST_PREVIOUS_BINARY_PATH_FIXED" | awk '{ print $1 }')
	[ "$rollback_sha256" = "$MANIFEST_PREVIOUS_BINARY_SHA256" ] || return 1
	current_sha256=$(sha256sum "$MANIFEST_BINARY_PATH" | awk '{ print $1 }')
	if [ "$current_sha256" = "$MANIFEST_PREVIOUS_BINARY_SHA256" ]; then
		[ -f "$STAGED_BINARY" ] && [ ! -L "$STAGED_BINARY" ] || return 1
		staged_target_sha256=$(sha256sum "$STAGED_BINARY" | awk '{ print $1 }')
		[ "$staged_target_sha256" = "$MANIFEST_CURRENT_BINARY_SHA256" ] || return 1
		install -m 0755 "$STAGED_BINARY" "$MANIFEST_PREVIOUS_BINARY_PATH_FIXED" || return 1
		sync -f "$MANIFEST_PREVIOUS_BINARY_PATH_FIXED" || return 1
		record_rollback_target || return 1
		systemctl start one-node.service || return 1
		UPGRADE_ROLLED_BACK="true"
		return 0
	fi
	[ "$current_sha256" = "$MANIFEST_CURRENT_BINARY_SHA256" ] || return 1
	failed_target="${MANIFEST_PREVIOUS_DIR}/.one-node.failed"
	[ ! -L "$failed_target" ] || return 1
	install -m 0755 "$MANIFEST_BINARY_PATH" "$failed_target" || return 1
	failed_sha256=$(sha256sum "$failed_target" | awk '{ print $1 }')
	[ "$failed_sha256" = "$MANIFEST_CURRENT_BINARY_SHA256" ] || return 1
	sync -f "$failed_target" || return 1
	record_rollback_target || return 1

	if ! systemctl stop one-node.service; then
		record_rollback_target || true
		return 1
	fi
	if ! mv -f -- "$MANIFEST_PREVIOUS_BINARY_PATH_FIXED" "$MANIFEST_BINARY_PATH"; then
		record_rollback_target || true
		systemctl start one-node.service || true
		return 1
	fi
	if ! mv -f -- "$failed_target" "$MANIFEST_PREVIOUS_BINARY_PATH_FIXED"; then
		mv -f -- "$MANIFEST_BINARY_PATH" "$MANIFEST_PREVIOUS_BINARY_PATH_FIXED" || true
		mv -f -- "$failed_target" "$MANIFEST_BINARY_PATH" || true
		record_rollback_target || true
		systemctl start one-node.service || true
		return 1
	fi
	if ! sync -f "$MANIFEST_BINARY_PATH" || ! sync -f "$MANIFEST_PREVIOUS_DIR"; then
		systemctl start one-node.service || true
		return 1
	fi
	systemctl start one-node.service || return 1
	UPGRADE_ROLLED_BACK="true"
}
