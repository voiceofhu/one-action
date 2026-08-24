#!/bin/sh

initialize_upgrade() {
	INSTALL_DIR=$MANIFEST_INSTALL_DIR
	INSTALL_RECORD=$MANIFEST_RECORD_PATH
	ENV_FILE=$MANIFEST_ENV_PATH
	COMPOSE_FILE=$MANIFEST_COMPOSE_PATH
	UNIT_FILE=$MANIFEST_UNIT_PATH
	CONTAINER_NAME="one-node"
	UPGRADE_OPERATION="upgrade"
	UPGRADE_SWITCHED="false"
	UPGRADE_ROLLED_BACK="false"
	UPGRADE_MANIFEST_ADVANCED="false"
	UPGRADE_OLD_VERSION=""
	UPGRADE_OLD_BINARY_SHA256=""
	UPGRADE_TEMP_DIR=$(mktemp -d "/tmp/one-node-upgrade.XXXXXX")
	chmod 0700 "$UPGRADE_TEMP_DIR"
	BINARY_SOURCE="${UPGRADE_TEMP_DIR}/one-node.download"
	STAGED_BINARY="${INSTALL_DIR}/.one-node.next"
	COMPOSE_SOURCE="${UPGRADE_TEMP_DIR}/docker-compose.yml"
	IDENTITY_FILE=""
	RUNTIME_STATE_FILE=""
	trap cleanup_upgrade EXIT
	trap interrupt_upgrade HUP INT TERM
}

cleanup_upgrade() {
	upgrade_status=$?
	trap - EXIT HUP INT TERM
	rm -f -- "${STAGED_BINARY:-}"
	rm -rf -- "${UPGRADE_TEMP_DIR:-}"
	exit "$upgrade_status"
}

interrupt_upgrade() {
	trap - HUP INT TERM
	if [ "$UPGRADE_SWITCHED" = true ] && [ "$UPGRADE_ROLLED_BACK" != true ]; then
		rollback_runtime >/dev/null 2>&1 || true
		wait_for_ready_heartbeat >/dev/null 2>&1 || true
	fi
	exit 1
}

parse_upgrade_arguments() {
	while [ "$#" -gt 0 ]; do
		case "$1" in
		--rollback)
			UPGRADE_OPERATION="rollback"
			shift
			;;
		--help|-h)
			printf '%s\n' \
				"Upgrade or roll back the One Node sing-box runtime." \
				"" \
				"Usage: upgrade.sh [--rollback]"
			exit 0
			;;
		*) die "unknown argument: $1" ;;
		esac
	done
}

load_upgrade_manifest() {
	command -v stat >/dev/null 2>&1 || die "stat is required (install coreutils)"
	manifest_load "$INSTALL_RECORD" || die "refusing unknown or unsafe installation manifest"
	INSTALL_MODE=$MANIFEST_MODE
	ONE_NODE_STATE_DIR=$MANIFEST_STATE_DIR
	IDENTITY_FILE="${ONE_NODE_STATE_DIR}/node-secret"
	RUNTIME_STATE_FILE="${ONE_NODE_STATE_DIR}/runtime-active.json"
	[ -f "$ENV_FILE" ] && [ ! -L "$ENV_FILE" ] || die "One Node environment file is missing or unsafe"
	[ "$(file_mode "$ENV_FILE")" = "600" ] || die "One Node environment file permissions must be 0600"
	ONE_NODE_ID=$(sed -n 's/^NODE_NODE_ID="\([0-9][0-9]*\)"$/\1/p' "$ENV_FILE")
	case "$ONE_NODE_ID" in
	''|*[!0-9]*|0) die "One Node environment has an invalid node id" ;;
	esac
}

validate_upgrade_host() {
	[ "$(id -u)" -eq 0 ] || die "run this upgrade as root"
	command -v stat >/dev/null 2>&1 || die "stat is required (install coreutils)"
	command -v sync >/dev/null 2>&1 || die "sync is required (install coreutils)"
	case "$INSTALL_MODE" in
	native)
		command -v systemctl >/dev/null 2>&1 || die "systemd is required for native upgrade"
		command -v sha256sum >/dev/null 2>&1 || die "sha256sum is required"
		[ -f "$MANIFEST_BINARY_PATH" ] && [ ! -L "$MANIFEST_BINARY_PATH" ] || die "current native binary is missing or unsafe"
		current_sha256=$(sha256sum "$MANIFEST_BINARY_PATH" | awk '{ print $1 }')
		[ "$current_sha256" = "$MANIFEST_CURRENT_BINARY_SHA256" ] || die "current native binary does not match its manifest"
		if [ -n "$MANIFEST_PREVIOUS_VERSION" ]; then
			[ -f "$MANIFEST_PREVIOUS_BINARY_PATH_FIXED" ] && [ ! -L "$MANIFEST_PREVIOUS_BINARY_PATH_FIXED" ] ||
				die "previous native binary is missing or unsafe"
			previous_sha256=$(sha256sum "$MANIFEST_PREVIOUS_BINARY_PATH_FIXED" | awk '{ print $1 }')
			[ "$previous_sha256" = "$MANIFEST_PREVIOUS_BINARY_SHA256" ] || die "previous native binary does not match its manifest"
		fi
		systemctl is-active --quiet one-node.service || die "current native runtime is not active"
		;;
	docker)
		command -v docker >/dev/null 2>&1 || die "Docker is required for Docker upgrade"
		docker compose version >/dev/null 2>&1 || die "Docker Compose plugin is required"
		[ -f "$COMPOSE_FILE" ] && [ ! -L "$COMPOSE_FILE" ] || die "current Docker compose file is missing or unsafe"
		current_image=$(docker inspect -f '{{.Config.Image}}' "$CONTAINER_NAME") || die "current One Node container is missing"
		[ "$current_image" = "$MANIFEST_CURRENT_IMAGE" ] || die "current container image does not match its manifest"
		;;
	esac
}

configure_readiness() {
	ONE_NODE_EXPECTED_CONFIG_REVISION=${ONE_NODE_EXPECTED_CONFIG_REVISION:-$MANIFEST_DESIRED_CONFIG_REVISION}
	ONE_NODE_ENROLL_TIMEOUT=${ONE_NODE_ENROLL_TIMEOUT:-120}
	validate_decimal "$ONE_NODE_EXPECTED_CONFIG_REVISION" || die "ONE_NODE_EXPECTED_CONFIG_REVISION must be canonical decimal"
	case "$ONE_NODE_ENROLL_TIMEOUT" in
	''|*[!0-9]*|0) die "ONE_NODE_ENROLL_TIMEOUT must be a positive integer" ;;
	esac
}

validate_upgrade_target() {
	ONE_NODE_VERSION=${ONE_NODE_VERSION:-}
	ONE_NODE_RELEASE_BASE_URL=${ONE_NODE_RELEASE_BASE_URL:-}
	ONE_NODE_BINARY_SHA256_AMD64=${ONE_NODE_BINARY_SHA256_AMD64:-}
	ONE_NODE_BINARY_SHA256_ARM64=${ONE_NODE_BINARY_SHA256_ARM64:-}
	ONE_NODE_DOCKER_IMAGE=${ONE_NODE_DOCKER_IMAGE:-}
	ONE_NODE_ALLOW_INSECURE=${ONE_NODE_ALLOW_INSECURE:-false}
	manifest_validate_version "$ONE_NODE_VERSION" || die "ONE_NODE_VERSION must be a dotted numeric version"
	case "$ONE_NODE_ALLOW_INSECURE" in
	true|false) ;;
	*) die "ONE_NODE_ALLOW_INSECURE must be true or false" ;;
	esac
	case "$INSTALL_MODE" in
	native)
		resolve_host_architecture
		ONE_NODE_BINARY_SHA256=$(normalize_sha256 "$ONE_NODE_BINARY_SHA256")
		validate_sha256 "$ONE_NODE_BINARY_SHA256" || die "selected binary checksum must be a pinned SHA-256"
		immutable_release_base="https://github.com/voiceofhu/one-action/releases/download/one-node-v${ONE_NODE_VERSION}"
		case "$ONE_NODE_RELEASE_BASE_URL" in
		"$immutable_release_base") ;;
		http://*) [ "$ONE_NODE_ALLOW_INSECURE" = true ] || die "HTTP release assets require ONE_NODE_ALLOW_INSECURE=true" ;;
		*) die "ONE_NODE_RELEASE_BASE_URL must pin the central immutable One Node release" ;;
		esac
		release_tag=${ONE_NODE_RELEASE_BASE_URL%/}
		release_tag=${release_tag##*/}
		case "$release_tag" in
		one-node-v"$ONE_NODE_VERSION") ;;
		*) die "ONE_NODE_RELEASE_BASE_URL must pin the requested immutable One Node release" ;;
		esac
		ONE_NODE_BINARY_URL="${ONE_NODE_RELEASE_BASE_URL%/}/${ONE_NODE_BINARY_NAME}"
		if [ "$ONE_NODE_VERSION" = "$MANIFEST_CURRENT_VERSION" ] &&
			[ "$ONE_NODE_BINARY_SHA256" = "$MANIFEST_CURRENT_BINARY_SHA256" ]; then
			die "native upgrade target is already current"
		fi
		;;
	docker)
		manifest_validate_image "$ONE_NODE_DOCKER_IMAGE" ||
			die "ONE_NODE_DOCKER_IMAGE must pin ghcr.io/voiceofhu/one-node by digest"
		if [ "$ONE_NODE_VERSION" = "$MANIFEST_CURRENT_VERSION" ] &&
			[ "$ONE_NODE_DOCKER_IMAGE" = "$MANIFEST_CURRENT_IMAGE" ]; then
			die "Docker upgrade target is already current"
		fi
		;;
	esac
}
