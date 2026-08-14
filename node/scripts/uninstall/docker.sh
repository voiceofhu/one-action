#!/bin/sh

uninstall_docker() {
	command -v docker >/dev/null 2>&1 ||
		die "Docker is required to uninstall the Docker runtime"
	if [ -f "$COMPOSE_FILE" ] && [ ! -L "$COMPOSE_FILE" ]; then
		docker compose -f "$COMPOSE_FILE" down --remove-orphans
	else
		docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
	fi
	log "Docker Engine was preserved"
}
