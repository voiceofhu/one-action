#!/bin/sh

MANIFEST_FORMAT_NAME="one-node-manifest"
MANIFEST_INSTALL_DIR="/opt/one-node"
MANIFEST_INSTALLER_PATH="${MANIFEST_INSTALL_DIR}/install.sh"
MANIFEST_BINARY_PATH="${MANIFEST_INSTALL_DIR}/one-node"
MANIFEST_PREVIOUS_DIR="${MANIFEST_INSTALL_DIR}/previous"
MANIFEST_PREVIOUS_BINARY_PATH_FIXED="${MANIFEST_PREVIOUS_DIR}/one-node"
MANIFEST_ENV_PATH="${MANIFEST_INSTALL_DIR}/.env"
MANIFEST_COMPOSE_PATH="${MANIFEST_INSTALL_DIR}/docker-compose.yml"
MANIFEST_RECORD_PATH="${MANIFEST_INSTALL_DIR}/.installation"
MANIFEST_UNIT_PATH="/etc/systemd/system/one-node.service"

manifest_fail() {
	printf '%s\n' "[one-node] error: $*" >&2
	return 1
}

manifest_validate_sha256() {
	case "$1" in
	''|*[!0-9a-f]*) return 1 ;;
	esac
	[ "${#1}" -eq 64 ]
}

manifest_validate_decimal() {
	case "$1" in
	''|*[!0-9]*) return 1 ;;
	esac
	[ "$1" = "0" ] || [ "${1#0}" = "$1" ]
}

manifest_validate_version() {
	case "$1" in
	''|*[!0-9.]*) return 1 ;;
	esac
	manifest_version=$1
	manifest_old_ifs=$IFS
	IFS=.
	set -- $manifest_version
	IFS=$manifest_old_ifs
	[ "$#" -eq 3 ] || return 1
	for manifest_part in "$@"; do
		case "$manifest_part" in
		''|*[!0-9]*) return 1 ;;
		esac
	done
}

manifest_validate_image() {
	case "$1" in
	ghcr.io/voiceofhu/one-node@sha256:*) ;;
	*) return 1 ;;
	esac
	manifest_repository=${1%@sha256:*}
	manifest_digest=${1##*@sha256:}
	[ -n "$manifest_repository" ] && manifest_validate_sha256 "$manifest_digest"
}

manifest_validate_state_dir() {
	manifest_state_dir=$1
	case "$manifest_state_dir" in
	/var/lib/one-node|/var/lib/one-node/*) ;;
	*) return 1 ;;
	esac
	[ "$(canonical_path "$manifest_state_dir")" = "$manifest_state_dir" ]
}

manifest_append_owned_path() {
	manifest_path=$1
	case "
${MANIFEST_OWNED_PATHS}
" in
	*"
${manifest_path}
"*) return 1 ;;
	esac
	if [ -n "$MANIFEST_OWNED_PATHS" ]; then
		MANIFEST_OWNED_PATHS="${MANIFEST_OWNED_PATHS}
${manifest_path}"
	else
		MANIFEST_OWNED_PATHS=$manifest_path
	fi
}

manifest_has_owned_path() {
	case "
${MANIFEST_OWNED_PATHS}
" in
	*"
$1
"*) return 0 ;;
	esac
	return 1
}

manifest_require_owned_path() {
	manifest_has_owned_path "$1" || manifest_fail "installation manifest does not own required path: $1"
}

manifest_validate_owned_paths() {
	manifest_require_owned_path "$MANIFEST_INSTALL_DIR" || return 1
	manifest_require_owned_path "$MANIFEST_ENV_PATH" || return 1
	manifest_require_owned_path "$MANIFEST_RECORD_PATH" || return 1
	manifest_allowed_count=3
	if manifest_has_owned_path "$MANIFEST_INSTALLER_PATH"; then
		manifest_allowed_count=$((manifest_allowed_count + 1))
	fi
	if manifest_has_owned_path "$MANIFEST_STATE_DIR"; then
		manifest_allowed_count=$((manifest_allowed_count + 1))
	fi
	case "$MANIFEST_MODE" in
	native)
		manifest_require_owned_path "$MANIFEST_BINARY_PATH" || return 1
		manifest_require_owned_path "$MANIFEST_UNIT_PATH" || return 1
		manifest_allowed_count=$((manifest_allowed_count + 2))
		if [ -n "$MANIFEST_PREVIOUS_VERSION" ]; then
			manifest_require_owned_path "$MANIFEST_PREVIOUS_DIR" || return 1
			manifest_require_owned_path "$MANIFEST_PREVIOUS_BINARY_PATH_FIXED" || return 1
			manifest_allowed_count=$((manifest_allowed_count + 2))
		fi
		;;
	docker)
		manifest_require_owned_path "$MANIFEST_COMPOSE_PATH" || return 1
		manifest_allowed_count=$((manifest_allowed_count + 1))
		;;
	*) return 1 ;;
	esac
	[ "$MANIFEST_OWNED_COUNT" -eq "$manifest_allowed_count" ] ||
		manifest_fail "installation manifest contains unknown or missing owned paths"
}

manifest_validate_metadata() {
	[ "$MANIFEST_FORMAT" = "$MANIFEST_FORMAT_NAME" ] || return 1
	manifest_validate_state_dir "$MANIFEST_STATE_DIR" || return 1
	manifest_validate_decimal "$MANIFEST_DESIRED_CONFIG_REVISION" || return 1
	if [ -n "$MANIFEST_HISTORICAL_BINDINGS_REVISION" ]; then
		manifest_validate_decimal "$MANIFEST_HISTORICAL_BINDINGS_REVISION" || return 1
	fi
	manifest_validate_version "$MANIFEST_CURRENT_VERSION" || return 1
	case "$MANIFEST_MODE" in
	native)
		[ "$MANIFEST_CURRENT_BINARY_PATH" = "$MANIFEST_BINARY_PATH" ] || return 1
		manifest_validate_sha256 "$MANIFEST_CURRENT_BINARY_SHA256" || return 1
		[ -z "$MANIFEST_CURRENT_IMAGE" ] || return 1
		if [ -n "$MANIFEST_PREVIOUS_VERSION" ]; then
			manifest_validate_version "$MANIFEST_PREVIOUS_VERSION" || return 1
			[ "$MANIFEST_PREVIOUS_BINARY_PATH" = "$MANIFEST_PREVIOUS_BINARY_PATH_FIXED" ] || return 1
			manifest_validate_sha256 "$MANIFEST_PREVIOUS_BINARY_SHA256" || return 1
			[ -z "$MANIFEST_PREVIOUS_IMAGE" ] || return 1
		else
			[ -z "$MANIFEST_PREVIOUS_BINARY_PATH$MANIFEST_PREVIOUS_BINARY_SHA256$MANIFEST_PREVIOUS_IMAGE" ] || return 1
		fi
		;;
	docker)
		[ -z "$MANIFEST_CURRENT_BINARY_PATH$MANIFEST_CURRENT_BINARY_SHA256" ] || return 1
		manifest_validate_image "$MANIFEST_CURRENT_IMAGE" || return 1
		if [ -n "$MANIFEST_PREVIOUS_VERSION" ]; then
			manifest_validate_version "$MANIFEST_PREVIOUS_VERSION" || return 1
			[ -z "$MANIFEST_PREVIOUS_BINARY_PATH$MANIFEST_PREVIOUS_BINARY_SHA256" ] || return 1
			manifest_validate_image "$MANIFEST_PREVIOUS_IMAGE" || return 1
		else
			[ -z "$MANIFEST_PREVIOUS_BINARY_PATH$MANIFEST_PREVIOUS_BINARY_SHA256$MANIFEST_PREVIOUS_IMAGE" ] || return 1
		fi
		;;
	esac
	manifest_validate_owned_paths
}

manifest_reset() {
	MANIFEST_FORMAT=""
	MANIFEST_MODE=""
	MANIFEST_STATE_DIR=""
	MANIFEST_DESIRED_CONFIG_REVISION=""
	MANIFEST_HISTORICAL_BINDINGS_REVISION=""
	MANIFEST_CURRENT_VERSION=""
	MANIFEST_CURRENT_BINARY_PATH=""
	MANIFEST_CURRENT_BINARY_SHA256=""
	MANIFEST_CURRENT_IMAGE=""
	MANIFEST_PREVIOUS_VERSION=""
	MANIFEST_PREVIOUS_BINARY_PATH=""
	MANIFEST_PREVIOUS_BINARY_SHA256=""
	MANIFEST_PREVIOUS_IMAGE=""
	MANIFEST_OWNED_PATHS=""
	MANIFEST_OWNED_COUNT=0
	MANIFEST_SEEN_KEYS=""
}

manifest_mark_seen() {
	case " $MANIFEST_SEEN_KEYS " in
	*" $1 "*) return 1 ;;
	esac
	MANIFEST_SEEN_KEYS="$MANIFEST_SEEN_KEYS $1"
}

manifest_assign() {
	manifest_key=$1
	manifest_value=$2
	if [ "$manifest_key" = "owned_path" ]; then
		manifest_append_owned_path "$manifest_value" || return 1
		MANIFEST_OWNED_COUNT=$((MANIFEST_OWNED_COUNT + 1))
		return 0
	fi
	manifest_mark_seen "$manifest_key" || return 1
	case "$manifest_key" in
	format) MANIFEST_FORMAT=$manifest_value ;;
	mode) MANIFEST_MODE=$manifest_value ;;
	state_dir) MANIFEST_STATE_DIR=$manifest_value ;;
	desired_config_revision) MANIFEST_DESIRED_CONFIG_REVISION=$manifest_value ;;
	desired_bindings_revision) MANIFEST_HISTORICAL_BINDINGS_REVISION=$manifest_value ;;
	current_version) MANIFEST_CURRENT_VERSION=$manifest_value ;;
	current_binary_path) MANIFEST_CURRENT_BINARY_PATH=$manifest_value ;;
	current_binary_sha256) MANIFEST_CURRENT_BINARY_SHA256=$manifest_value ;;
	current_image) MANIFEST_CURRENT_IMAGE=$manifest_value ;;
	previous_version) MANIFEST_PREVIOUS_VERSION=$manifest_value ;;
	previous_binary_path) MANIFEST_PREVIOUS_BINARY_PATH=$manifest_value ;;
	previous_binary_sha256) MANIFEST_PREVIOUS_BINARY_SHA256=$manifest_value ;;
	previous_image) MANIFEST_PREVIOUS_IMAGE=$manifest_value ;;
	*) return 1 ;;
	esac
}

manifest_load() {
	manifest_load_file=$1
	[ -f "$manifest_load_file" ] && [ ! -L "$manifest_load_file" ] ||
		manifest_fail "installation manifest must be a regular file" || return 1
	[ "$(file_mode "$manifest_load_file")" = "600" ] ||
		manifest_fail "installation manifest permissions must be 0600" || return 1
	manifest_reset
	while IFS= read -r manifest_line || [ -n "$manifest_line" ]; do
		case "$manifest_line" in
		*=*) ;;
		*) manifest_fail "installation manifest contains a malformed record"; return 1 ;;
		esac
		manifest_key=${manifest_line%%=*}
		manifest_value=${manifest_line#*=}
		manifest_assign "$manifest_key" "$manifest_value" || {
			manifest_fail "installation manifest contains an unknown or duplicate field"
			return 1
		}
	done <"$manifest_load_file"
	manifest_validate_metadata || {
		manifest_fail "installation manifest metadata is invalid"
		return 1
	}
}

manifest_write() {
	manifest_target=$1
	manifest_temp=$(mktemp "${manifest_target}.XXXXXX") || return 1
	chmod 0600 "$manifest_temp" || {
		rm -f -- "$manifest_temp"
		return 1
	}
	{
		printf '%s\n' \
			"format=${MANIFEST_FORMAT}" \
			"mode=${MANIFEST_MODE}" \
			"state_dir=${MANIFEST_STATE_DIR}" \
			"desired_config_revision=${MANIFEST_DESIRED_CONFIG_REVISION}" \
			"current_version=${MANIFEST_CURRENT_VERSION}" \
			"current_binary_path=${MANIFEST_CURRENT_BINARY_PATH}" \
			"current_binary_sha256=${MANIFEST_CURRENT_BINARY_SHA256}" \
			"current_image=${MANIFEST_CURRENT_IMAGE}" \
			"previous_version=${MANIFEST_PREVIOUS_VERSION}" \
			"previous_binary_path=${MANIFEST_PREVIOUS_BINARY_PATH}" \
			"previous_binary_sha256=${MANIFEST_PREVIOUS_BINARY_SHA256}" \
			"previous_image=${MANIFEST_PREVIOUS_IMAGE}"
		manifest_old_ifs=$IFS
		IFS='
'
		for manifest_path in $MANIFEST_OWNED_PATHS; do
			printf '%s\n' "owned_path=${manifest_path}"
		done
		IFS=$manifest_old_ifs
	} >"$manifest_temp" || {
		rm -f -- "$manifest_temp"
		return 1
	}
	manifest_load "$manifest_temp" || {
		rm -f -- "$manifest_temp"
		return 1
	}
	if ! sync -f "$manifest_temp"; then
		rm -f -- "$manifest_temp"
		return 1
	fi
	if ! mv -f -- "$manifest_temp" "$manifest_target"; then
		rm -f -- "$manifest_temp"
		return 1
	fi
	sync -f "$(dirname "$manifest_target")"
}
