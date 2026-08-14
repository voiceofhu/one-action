#!/bin/sh

if ! command -v manifest_load >/dev/null 2>&1; then
	printf '%s\n' "[one-node] error: upgrade main module must be loaded through upgrade.sh" >&2
	exit 1
fi

stage_upgrade() {
	case "$INSTALL_MODE" in
	native) stage_native_upgrade ;;
	docker) stage_docker_upgrade ;;
	*) return 1 ;;
	esac
}

switch_upgrade() {
	case "$INSTALL_MODE" in
	native) switch_native_runtime ;;
	docker) switch_docker_runtime ;;
	*) return 1 ;;
	esac
}

restore_after_failed_upgrade() {
	log "upgrade failed after switching; restoring the single previous immutable version"
	rollback_runtime || die "upgrade failed and automatic rollback could not restore the previous runtime"
	wait_for_rollback_ready || die "previous runtime was restored but did not become ready"
}

main() {
	umask 077
	initialize_upgrade
	parse_upgrade_arguments "$@"
	load_upgrade_manifest
	validate_upgrade_host
	configure_readiness
	ONE_NODE_READINESS_RETURN_ONLY="true"

	if [ "$UPGRADE_OPERATION" = rollback ]; then
		[ -n "$MANIFEST_PREVIOUS_VERSION" ] || die "installation manifest has no previous version"
		UPGRADE_MANIFEST_ADVANCED="true"
		rollback_runtime || die "explicit rollback could not restore the previous runtime"
		wait_for_rollback_ready || die "rolled-back runtime did not become ready"
		log "explicit rollback completed"
		return 0
	fi

	validate_upgrade_target
	stage_upgrade || die "upgrade artifact staging or immutable metadata verification failed"
	if ! switch_upgrade; then
		if [ "$UPGRADE_SWITCHED" = true ]; then
			restore_after_failed_upgrade
		fi
		die "upgrade switch failed"
	fi
	if ! wait_for_ready_heartbeat; then
		restore_after_failed_upgrade
		die "upgrade target did not become ready and was rolled back"
	fi
	log "${INSTALL_MODE} upgrade to ${MANIFEST_CURRENT_VERSION} is ready"
}
