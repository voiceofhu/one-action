#!/bin/sh

runtime_is_active() {
	if [ "$INSTALL_MODE" = "native" ]; then
		systemctl is-active --quiet one-node.service
	else
		docker inspect -f '{{.State.Running}}' "$CONTAINER_NAME" 2>/dev/null |
			grep -qx true
	fi
}

probe_control_endpoint() {
	case "$ONE_NODE_SERVER" in
	grpcs://*)
		probe_url="https://${ONE_NODE_SERVER#grpcs://}"
		;;
	https://*)
		probe_url=$ONE_NODE_SERVER
		;;
	*) return 0 ;;
	esac

	status_code=$(curl -q --proto '=https' --proto-redir '=https' --tlsv1.2 \
		--silent --show-error --no-location \
		--connect-timeout 10 --max-time 15 \
		--output /dev/null --write-out '%{http_code}' "$probe_url") ||
		die "unable to reach the public One Node control endpoint: $ONE_NODE_SERVER"
	case "$status_code" in
	[1-4][0-9][0-9]) ;;
	5[0-9][0-9])
		die "public One Node control endpoint returned HTTP $status_code; verify its TLS/HTTP2 proxy and port 27519 upstream"
		;;
	*) die "public One Node control endpoint returned an invalid HTTP status" ;;
	esac
}

print_runtime_logs() {
	log "recent ${INSTALL_MODE} runtime logs:"
	if [ "$INSTALL_MODE" = "native" ]; then
		log_window_seconds=$((ONE_NODE_ENROLL_TIMEOUT + 15))
		journalctl --unit one-node.service --since "-${log_window_seconds} seconds" \
			--lines 120 --no-pager --output cat >&2 || true
	else
		docker logs --since "${ONE_NODE_ENROLL_TIMEOUT}s" --tail 120 "$CONTAINER_NAME" >&2 || true
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
	if ! identity_is_active; then
		readiness_failure "Node registration did not complete through $ONE_NODE_SERVER; verify that the public gRPC route reaches the One Node control listener"
	else
		readiness_failure "One Node did not reach the expected config and binding revisions"
	fi
}
