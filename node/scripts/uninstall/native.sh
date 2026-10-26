#!/bin/sh

uninstall_native() {
	command -v systemctl >/dev/null 2>&1 ||
		die "systemd is required to uninstall the native runtime"
	systemctl disable --now one-node.service >/dev/null 2>&1 || true
	rm -f -- "$UNIT_FILE"
	systemctl daemon-reload
}

# Removes only the account entries the installer recorded as created by it; a
# pre-existing one-node user or group is preserved.
remove_native_service_account() {
	account_record="${INSTALL_DIR}/.service-account"
	[ -e "$account_record" ] || return 0
	if [ -L "$account_record" ] || [ ! -f "$account_record" ]; then
		log "ignoring unsafe service account record $account_record"
		return 0
	fi
	if grep -Fx 'user=one-node' "$account_record" >/dev/null &&
		getent passwd one-node >/dev/null 2>&1; then
		userdel one-node >/dev/null 2>&1 ||
			log "unable to remove the one-node service user"
	fi
	if grep -Fx 'group=one-node' "$account_record" >/dev/null &&
		getent group one-node >/dev/null 2>&1; then
		groupdel one-node >/dev/null 2>&1 ||
			log "unable to remove the one-node service group"
	fi
	rm -f -- "$account_record"
}
