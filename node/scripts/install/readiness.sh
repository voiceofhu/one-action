#!/bin/sh

runtime_is_active() {
	if [ "$INSTALL_MODE" = "native" ]; then
		systemctl is-active --quiet one-node.service
	else
		docker inspect -f '{{.State.Running}}' "$CONTAINER_NAME" 2>/dev/null |
			grep -qx true
	fi
}

print_runtime_logs() {
	log "recent ${INSTALL_MODE} runtime logs:"
	if [ "$INSTALL_MODE" = "native" ]; then
		journalctl --unit one-node.service --lines 120 --no-pager --output cat >&2 || true
	else
		docker logs --tail 120 "$CONTAINER_NAME" >&2 || true
	fi
}

readiness_failure() {
	if [ "${ONE_NODE_READINESS_RETURN_ONLY:-false}" = "true" ]; then
		printf '%s\n' "[one-node] error: $*" >&2
		return 1
	fi
	die "$*"
}

identity_is_active() {
	[ -f "$IDENTITY_FILE" ] && [ ! -L "$IDENTITY_FILE" ] || return 1
	[ "$(file_mode "$IDENTITY_FILE")" = "600" ] || return 1
	grep -Eq '"node_id"[[:space:]]*:[[:space:]]*"'"$ONE_NODE_ID"'"' "$IDENTITY_FILE" || return 1
	grep -Eq '"state"[[:space:]]*:[[:space:]]*"active"' "$IDENTITY_FILE"
}

runtime_revision() {
	section=$1
	[ -e "$RUNTIME_STATE_FILE" ] || return 1
	[ -f "$RUNTIME_STATE_FILE" ] && [ ! -L "$RUNTIME_STATE_FILE" ] || return 1
	[ "$(file_mode "$RUNTIME_STATE_FILE")" = "600" ] || return 1
	awk -v section="$section" '
		$0 ~ "\\\"" section "\\\"[[:space:]]*:" { inside = 1; next }
		inside && match($0, /"revision"[[:space:]]*:[[:space:]]*"[0-9]+"/) {
			value = substr($0, RSTART, RLENGTH)
			gsub(/[^0-9]/, "", value)
			print value
			exit
		}
		inside && $0 ~ /^[[:space:]]*}/ { exit 1 }
	' "$RUNTIME_STATE_FILE"
}

runtime_revisions_are_ready() {
	if [ "$ONE_NODE_EXPECTED_CONFIG_REVISION" = "0" ] &&
		[ "$ONE_NODE_EXPECTED_BINDINGS_REVISION" = "0" ]; then
		return 0
	fi
	[ "$ONE_NODE_EXPECTED_CONFIG_REVISION" != "0" ] || return 1
	config_revision=$(runtime_revision config) || return 1
	bindings_revision=$(runtime_revision bindings) || return 1
	validate_decimal "$config_revision" || return 1
	validate_decimal "$bindings_revision" || return 1
	[ "$config_revision" != "0" ] || return 1
	if [ "$config_revision" != "$ONE_NODE_EXPECTED_CONFIG_REVISION" ]; then
		return 1
	fi
	[ "$bindings_revision" = "$ONE_NODE_EXPECTED_BINDINGS_REVISION" ]
}

wait_for_ready_heartbeat() {
	remaining=$ONE_NODE_ENROLL_TIMEOUT
	log "waiting up to ${ONE_NODE_ENROLL_TIMEOUT}s for node $ONE_NODE_ID to become ready"
	while [ "$remaining" -gt 0 ]; do
		if ! runtime_is_active; then
			print_runtime_logs
			readiness_failure "${INSTALL_MODE} runtime stopped before enrollment became ready"
			return 1
		fi
		if identity_is_active && runtime_revisions_are_ready &&
			! grep -Eq '^[[:space:]]*(export[[:space:]]+)?CONTROL_BOOTSTRAP_TOKEN[[:space:]]*=' "$ENV_FILE"; then
			return 0
		fi
		sleep 1
		remaining=$((remaining - 1))
	done
	print_runtime_logs
	readiness_failure "Server did not accept a sing_box heartbeat at the expected config and binding revisions"
}
