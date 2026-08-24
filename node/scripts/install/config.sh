#!/bin/sh

# Installer globals are shared across sourced modules.
# shellcheck disable=SC2034

initialize_install_config() {
	PROGRAM="one-node"
	INSTALL_DIR="/opt/one-node"
	ENV_FILE="${INSTALL_DIR}/.env"
	UNIT_FILE="/etc/systemd/system/one-node.service"
	COMPOSE_FILE="${INSTALL_DIR}/docker-compose.yml"
	INSTALL_RECORD="${INSTALL_DIR}/.installation"
	CONTAINER_NAME="one-node"

	INSTALL_MODE="native"
	INSTALL_OPERATION="fresh"
	INSTALL_MANIFEST_KIND="none"
	RESET_EXISTING="false"
	SHOW_UNINSTALL_ON_ERROR="false"
	UNINSTALL_MODE=""
	ONE_NODE_SERVER=${ONE_NODE_SERVER:-}
	ONE_NODE_ID=${ONE_NODE_ID:-}
	ONE_NODE_BOOTSTRAP_TOKEN=${ONE_NODE_BOOTSTRAP_TOKEN:-}
	ONE_NODE_VERSION=${ONE_NODE_VERSION:-}
	ONE_NODE_RELEASE_BASE_URL=${ONE_NODE_RELEASE_BASE_URL:-}
	ONE_NODE_BINARY_SHA256_AMD64=${ONE_NODE_BINARY_SHA256_AMD64:-}
	ONE_NODE_BINARY_SHA256_ARM64=${ONE_NODE_BINARY_SHA256_ARM64:-}
	ONE_NODE_DOCKER_IMAGE=${ONE_NODE_DOCKER_IMAGE:-}
	ONE_NODE_STATE_DIR=${ONE_NODE_STATE_DIR:-/var/lib/one-node}
	ONE_NODE_EXPECTED_CONFIG_REVISION=${ONE_NODE_EXPECTED_CONFIG_REVISION:-0}
	if [ "${ONE_NODE_ALLOW_INSECURE+x}" != x ]; then
		case "$ONE_NODE_SERVER" in
		https://*|grpcs://*) ONE_NODE_ALLOW_INSECURE=false ;;
		*) ONE_NODE_ALLOW_INSECURE=true ;;
		esac
	fi
	ONE_NODE_ENROLL_TIMEOUT=${ONE_NODE_ENROLL_TIMEOUT:-120}
	ONE_NODE_ARCH=""
	ONE_NODE_BINARY_NAME=""
	ONE_NODE_BINARY_URL=""
	ONE_NODE_BINARY_SHA256=""
}

parse_install_arguments() {
	while [ "$#" -gt 0 ]; do
		case "$1" in
		--mode)
			[ "$#" -ge 2 ] || die "--mode requires native or docker"
			INSTALL_MODE=$2
			shift 2
			;;
		--reset)
			RESET_EXISTING="true"
			shift
			;;
		--help|-h)
			show_help
			exit 0
			;;
		*) die "unknown argument: $1" ;;
		esac
	done
	case "$INSTALL_MODE" in
	native|docker) ;;
	*) die "--mode must be native or docker" ;;
	esac
}

resolve_latest_node_version() {
	[ -z "$ONE_NODE_VERSION" ] || return 0
	command -v curl >/dev/null 2>&1 ||
		die "curl is required to resolve the latest One Node release"
	releases=$(curl -q --proto '=https' --proto-redir '=https' --tlsv1.2 \
		--fail --silent --show-error --no-location \
		--connect-timeout 10 --max-time 30 --max-filesize 8388608 \
		--header 'Accept: application/vnd.github+json' \
		--header 'X-GitHub-Api-Version: 2022-11-28' \
		--user-agent 'one-node-installer' \
		'https://api.github.com/repos/voiceofhu/one-action/releases?per_page=100') ||
		die "unable to resolve the latest One Node release"
	release_tag=$(printf '%s' "$releases" |
		grep -Eo '"tag_name"[[:space:]]*:[[:space:]]*"one-node-v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)"' |
		sed -n '1s/^.*"one-node-v\([^"]*\)"$/\1/p')
	manifest_validate_version "$release_tag" ||
		die "latest One Node release response did not contain a valid version"
	ONE_NODE_VERSION=$release_tag
	log "using latest published One Node version $ONE_NODE_VERSION"
}

validate_install_config() {
	for pair in \
		"ONE_NODE_SERVER|$ONE_NODE_SERVER" \
		"ONE_NODE_ID|$ONE_NODE_ID" \
		"ONE_NODE_BOOTSTRAP_TOKEN|$ONE_NODE_BOOTSTRAP_TOKEN" \
		"ONE_NODE_EXPECTED_CONFIG_REVISION|$ONE_NODE_EXPECTED_CONFIG_REVISION"
	do
		name=${pair%%|*}
		value=${pair#*|}
		require_value "$name" "$value"
		require_single_line "$name" "$value"
	done

	case "$ONE_NODE_ID" in
	''|*[!0-9]*|0) die "ONE_NODE_ID must be a positive integer" ;;
	esac
	resolve_latest_node_version
	manifest_validate_version "$ONE_NODE_VERSION" ||
		die "ONE_NODE_VERSION must be an exact three-component numeric version"
	validate_decimal "$ONE_NODE_EXPECTED_CONFIG_REVISION" ||
		die "ONE_NODE_EXPECTED_CONFIG_REVISION must be canonical decimal"
	case "$ONE_NODE_ENROLL_TIMEOUT" in
	''|*[!0-9]*|0) die "ONE_NODE_ENROLL_TIMEOUT must be a positive integer" ;;
	esac
	case "$ONE_NODE_ALLOW_INSECURE" in
	true|false) ;;
	*) die "ONE_NODE_ALLOW_INSECURE must be true or false" ;;
	esac
	if [ "$RESET_EXISTING" = "true" ]; then
		[ "$ONE_NODE_ALLOW_INSECURE" = "true" ] ||
			die "--reset is only available for an insecure development installation"
		[ "$ONE_NODE_STATE_DIR" = "/var/lib/one-node" ] ||
			die "--reset requires the default One Node state directory"
	fi

	case "$ONE_NODE_SERVER" in
	https://*|grpcs://*) ;;
	http://*|grpc://*|*:* )
		[ "$ONE_NODE_ALLOW_INSECURE" = "true" ] ||
			die "plaintext control connections require ONE_NODE_ALLOW_INSECURE=true"
		;;
	*) die "ONE_NODE_SERVER is invalid" ;;
	esac
	ONE_NODE_STATE_DIR=$(canonical_path "$ONE_NODE_STATE_DIR") ||
		die "ONE_NODE_STATE_DIR must be a canonical absolute path"
	case "$ONE_NODE_STATE_DIR" in
	/var/lib/one-node|/var/lib/one-node/*) ;;
	*) die "ONE_NODE_STATE_DIR must remain under /var/lib/one-node" ;;
	esac

	if [ "$INSTALL_MODE" = "native" ]; then
		immutable_release_base="https://github.com/voiceofhu/one-action/releases/download/one-node-v${ONE_NODE_VERSION}"
		ONE_NODE_RELEASE_BASE_URL=${ONE_NODE_RELEASE_BASE_URL:-$immutable_release_base}
		require_value "ONE_NODE_RELEASE_BASE_URL" "$ONE_NODE_RELEASE_BASE_URL"
		case "$ONE_NODE_RELEASE_BASE_URL" in
		"$immutable_release_base") ;;
		http://*)
			[ "$ONE_NODE_ALLOW_INSECURE" = "true" ] ||
				die "HTTP release assets require ONE_NODE_ALLOW_INSECURE=true"
			;;
		*) die "ONE_NODE_RELEASE_BASE_URL must pin the central immutable One Node release" ;;
		esac
		ONE_NODE_BINARY_URL="${ONE_NODE_RELEASE_BASE_URL%/}/${ONE_NODE_BINARY_NAME}"
	else
		version_image="ghcr.io/voiceofhu/one-node:${ONE_NODE_VERSION}"
		ONE_NODE_DOCKER_IMAGE=${ONE_NODE_DOCKER_IMAGE:-$version_image}
		if [ "$ONE_NODE_DOCKER_IMAGE" != "$version_image" ]; then
			manifest_validate_image "$ONE_NODE_DOCKER_IMAGE" ||
				die "ONE_NODE_DOCKER_IMAGE must match the selected version tag or pin ghcr.io/voiceofhu/one-node by digest"
		fi
	fi
}
