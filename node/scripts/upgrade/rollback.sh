#!/bin/sh

rollback_runtime() {
	case "$MANIFEST_MODE" in
	native) rollback_native_runtime ;;
	docker) rollback_docker_runtime ;;
	*) return 1 ;;
	esac
}

wait_for_rollback_ready() {
	if wait_for_ready_heartbeat; then
		log "rollback to ${MANIFEST_CURRENT_VERSION} is ready"
		return 0
	fi
	return 1
}
