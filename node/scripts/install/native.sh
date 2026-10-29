#!/bin/sh

# The unit text and the service account live in files.sh because the upgrade
# entrypoint loads files.sh but not this module, and upgrades rewrite both.

install_native_runtime() {
	ensure_native_service_user || die "unable to create the ${NATIVE_SERVICE_USER} service account"
	# The node writes requests into these directories as the service user; the
	# unit's ExecStartPre hands them over, so they must exist before it starts.
	if ! node_role_is_monitor; then
		install -d -m 0700 "${ONE_NODE_STATE_DIR}/firewall"
	fi
	if [ "${HOST_UPDATER_ENABLED:-false}" = "true" ]; then
		install -d -m 0700 "${ONE_NODE_STATE_DIR}/update"
	fi
	install -m 0644 "$UNIT_SOURCE" "$UNIT_FILE"
	systemctl daemon-reload
	systemctl enable --now one-node.service
	systemctl is-active --quiet one-node.service ||
		die "one-node.service did not become active"
}
