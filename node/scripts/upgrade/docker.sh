#!/bin/sh

stage_docker_upgrade() {
	prepare_docker_image || return 1
	write_docker_source || return 1
	sync -f "$COMPOSE_SOURCE"
}

restore_failed_docker_rollback() {
	docker compose -f "$COMPOSE_FILE" down --remove-orphans >/dev/null 2>&1 || true
	ONE_NODE_DOCKER_IMAGE=$failed_image
	write_docker_source || return 1
	install -m 0600 "$COMPOSE_SOURCE" "$COMPOSE_FILE" || return 1
	record_rollback_target || return 1
	docker compose -f "$COMPOSE_FILE" up -d >/dev/null 2>&1 || true
}

switch_docker_runtime() {
	old_image=$MANIFEST_CURRENT_IMAGE
	install -m 0600 "$COMPOSE_SOURCE" "$COMPOSE_FILE" || return 1
	sync -f "$COMPOSE_FILE" || return 1
	if ! record_upgrade_target; then
		ONE_NODE_DOCKER_IMAGE=$old_image
		write_docker_source || return 1
		install -m 0600 "$COMPOSE_SOURCE" "$COMPOSE_FILE" || return 1
		return 1
	fi
	UPGRADE_SWITCHED="true"
	UPGRADE_MANIFEST_ADVANCED="true"
	docker compose -f "$COMPOSE_FILE" down --remove-orphans || return 1
	docker compose -f "$COMPOSE_FILE" up -d || return 1
	docker inspect -f '{{.State.Running}}' "$CONTAINER_NAME" | grep -qx true
}

rollback_docker_runtime() {
	rollback_image=$MANIFEST_PREVIOUS_IMAGE
	failed_image=$MANIFEST_CURRENT_IMAGE
	manifest_validate_image "$rollback_image" || return 1
	ONE_NODE_DOCKER_IMAGE=$rollback_image
	write_docker_source || return 1
	sync -f "$COMPOSE_SOURCE" || return 1
	record_rollback_target || return 1
	if ! docker compose -f "$COMPOSE_FILE" down --remove-orphans; then
		restore_failed_docker_rollback || true
		return 1
	fi
	if ! install -m 0600 "$COMPOSE_SOURCE" "$COMPOSE_FILE" || ! sync -f "$COMPOSE_FILE"; then
		restore_failed_docker_rollback || true
		return 1
	fi
	if ! docker compose -f "$COMPOSE_FILE" up -d ||
		! docker inspect -f '{{.State.Running}}' "$CONTAINER_NAME" | grep -qx true; then
		restore_failed_docker_rollback || true
		return 1
	fi
	UPGRADE_ROLLED_BACK="true"
}
