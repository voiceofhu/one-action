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

switch_native_runtime() {
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
