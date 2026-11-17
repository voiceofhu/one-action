#!/bin/sh
# shellcheck disable=SC1091,SC2034
set -eu

ROOT_DIR=$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)
TEST_TEMP_DIR=$(mktemp -d)
trap 'rm -rf -- "$TEST_TEMP_DIR"' EXIT HUP INT TERM

fail() {
	printf '%s\n' "$*" >&2
	exit 1
}

# shellcheck disable=SC1090
. "$ROOT_DIR/scripts/install/common.sh"
. "$ROOT_DIR/scripts/shared/manifest.sh"
. "$ROOT_DIR/scripts/uninstall/paths.sh"
. "$ROOT_DIR/scripts/uninstall/native.sh"
. "$ROOT_DIR/scripts/uninstall/docker.sh"
. "$ROOT_DIR/scripts/install/config.sh"
. "$ROOT_DIR/scripts/install/host.sh"
. "$ROOT_DIR/scripts/install/files.sh"
. "$ROOT_DIR/scripts/install/updater.sh"
. "$ROOT_DIR/scripts/install/firewall.sh"
. "$ROOT_DIR/scripts/install/native.sh"

ensure_native_service_user() { :; }

sha256sum() {
	if command -v shasum >/dev/null 2>&1; then
		command shasum -a 256 "$@"
	else
		command sha256sum "$@"
	fi
}

manifest_validate_state_dir() {
	case "$1" in
	"$TEST_TEMP_DIR"/*/state) return 0 ;;
	esac
	return 1
}

configure_case() {
	case_name=$1
	CASE_DIR="${TEST_TEMP_DIR}/${case_name}"
	INSTALL_DIR="${CASE_DIR}/install"
	ENV_FILE="${INSTALL_DIR}/.env"
	UNIT_FILE="${CASE_DIR}/one-node.service"
	COMPOSE_FILE="${INSTALL_DIR}/docker-compose.yml"
	INSTALL_RECORD="${INSTALL_DIR}/.installation"
	ONE_NODE_STATE_DIR="${CASE_DIR}/state"
	MANIFEST_INSTALL_DIR=$INSTALL_DIR
	MANIFEST_INSTALLER_PATH="${INSTALL_DIR}/install.sh"
	MANIFEST_BINARY_PATH="${INSTALL_DIR}/one-node"
	MANIFEST_PREVIOUS_DIR="${INSTALL_DIR}/previous"
	MANIFEST_PREVIOUS_BINARY_PATH_FIXED="${MANIFEST_PREVIOUS_DIR}/one-node"
	MANIFEST_ENV_PATH=$ENV_FILE
	MANIFEST_RECORD_PATH=$INSTALL_RECORD
	MANIFEST_UNIT_PATH=$UNIT_FILE
	MANIFEST_COMPOSE_PATH=$COMPOSE_FILE
	MANIFEST_FIREWALL_PATH="${INSTALL_DIR}/firewall.sh"
	MANIFEST_FIREWALL_SERVICE_PATH="${CASE_DIR}/one-node-firewall.service"
	MANIFEST_FIREWALL_PATH_UNIT_PATH="${CASE_DIR}/one-node-firewall.path"
	PROGRAM="one-node"
	INSTALL_MODE="native"
	INSTALL_OPERATION="fresh"
	INSTALL_MANIFEST_KIND="none"
	RESET_EXISTING="false"
	CONTAINER_NAME="one-node"
	ONE_NODE_ARCH="amd64"
	ONE_NODE_INSTALLER_SOURCE="$ROOT_DIR/install.sh"
	ONE_NODE_SERVER="grpcs://new.example:443"
	ONE_NODE_ID="41"
	ONE_NODE_BOOTSTRAP_TOKEN="new-token"
	ONE_NODE_EXPECTED_CONFIG_REVISION="7"
	FAKE_SERVICE_ACTIVE="true"
	FAKE_SERVICE_ENABLED="true"
	SYSTEMCTL_LOG="${CASE_DIR}/systemctl.log"
	install -d -m 0755 "$CASE_DIR"
}

write_managed_unit() {
	printf '%s\n' \
		'[Service]' \
		"WorkingDirectory=${ONE_NODE_STATE_DIR}" \
		"EnvironmentFile=${INSTALL_DIR}/.env" \
		"ExecStartPre=+/bin/chown -hR one-node:one-node ${ONE_NODE_STATE_DIR}" \
		"ExecStart=${INSTALL_DIR}/one-node start" >"$UNIT_FILE"
	chmod 0644 "$UNIT_FILE"
}

systemctl() {
	printf '%s\n' "$*" >>"$SYSTEMCTL_LOG"
	case "$1" in
	is-active) [ "$FAKE_SERVICE_ACTIVE" = "true" ] ;;
	is-enabled) [ "$FAKE_SERVICE_ENABLED" = "true" ] ;;
	stop) FAKE_SERVICE_ACTIVE="false" ;;
	start|restart) FAKE_SERVICE_ACTIVE="true" ;;
	enable) FAKE_SERVICE_ENABLED="true" ;;
	disable) FAKE_SERVICE_ENABLED="false" ;;
	esac
}

wait_for_ready_heartbeat() {
	[ ! -e "$IDENTITY_FILE" ] || return 1
	[ ! -e "$RUNTIME_STATE_FILE" ] || return 1
	printf '%s\n' '{"node_id":"41","state":"active"}' >"$IDENTITY_FILE"
	printf '%s\n' '{"config":"fresh"}' >"$RUNTIME_STATE_FILE"
	chmod 0600 "$IDENTITY_FILE" "$RUNTIME_STATE_FILE"
	: >"$BOOTSTRAP_ENV_FILE"
}

prepare_desired_native() {
	TEMP_DIR=$(mktemp -d "${CASE_DIR}/desired.XXXXXX")
	BINARY_SOURCE="${TEMP_DIR}/one-node"
	UNIT_SOURCE="${TEMP_DIR}/one-node.service"
	BOOTSTRAP_ENV_SOURCE="${TEMP_DIR}/bootstrap.env"
	BOOTSTRAP_ENV_FILE="${ONE_NODE_STATE_DIR}/bootstrap.env"
	printf '%s\n' \
		'#!/bin/sh' \
		'case "$1:$2" in' \
		'  version:--product-name) printf "%s\\n" "26.809.2200" ;;' \
		'  version:--name) printf "%s\\n" "1.13.18" ;;' \
		'  *) exit 1 ;;' \
		'esac' >"$BINARY_SOURCE"
	chmod 0755 "$BINARY_SOURCE"
	ONE_NODE_VERSION="26.809.2200"
	ONE_NODE_BINARY_SHA256=$(sha256sum "$BINARY_SOURCE" | awk '{ print $1 }')
	write_native_source
}

run_stale_unit_recovery() (
	configure_case stale
	install -d -m 0700 "$ONE_NODE_STATE_DIR"
	printf '%s\n' '{"node_id":"40","state":"active"}' >"$ONE_NODE_STATE_DIR/node-secret"
	chmod 0600 "$ONE_NODE_STATE_DIR/node-secret"
	write_managed_unit

	validate_install_target
	[ "$INSTALL_OPERATION:$INSTALL_MANIFEST_KIND" = "replace:missing" ] ||
		fail "stale managed unit did not select replacement"
	initialize_install_workspace
	prepare_desired_native
	replace_existing_installation
	[ ! -e "$UNIT_FILE" ] || fail "replacement retained the stale managed unit"
	[ ! -e "$ONE_NODE_STATE_DIR" ] || fail "replacement retained the stale runtime state"
	prepare_install_directories
	write_common_sources
	install_common_files
	install_native_runtime
	wait_for_ready_heartbeat
	INSTALL_COMMITTED="true"

	[ -x "$MANIFEST_BINARY_PATH" ] || fail "replacement binary was not installed"
	[ -x "$MANIFEST_INSTALLER_PATH" ] || fail "persistent installer was not installed"
	grep -F '"node_id":"41"' "$ONE_NODE_STATE_DIR/node-secret" >/dev/null ||
		fail "replacement retained the previous node identity"
	grep -F '"config":"fresh"' "$ONE_NODE_STATE_DIR/runtime-active.json" >/dev/null ||
		fail "replacement retained the previous runtime state"
	manifest_load "$INSTALL_RECORD"
	manifest_has_owned_path "$MANIFEST_INSTALLER_PATH" || fail "manifest does not own the persistent installer"
	[ "$MANIFEST_CURRENT_VERSION" = "26.809.2200" ] || fail "stale installation product version is wrong"
	[ "$("$MANIFEST_BINARY_PATH" version --name)" = "1.13.18" ] ||
		fail "replacement sing-box core version is wrong"
	grep -F 'enable --now one-node.service' "$SYSTEMCTL_LOG" >/dev/null ||
		fail "replacement service was not enabled"
)

run_stale_unit_recovery
