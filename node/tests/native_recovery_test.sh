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
. "$ROOT_DIR/scripts/install/native.sh"
. "$ROOT_DIR/scripts/install/native_reconfigure.sh"

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
		'WorkingDirectory=/opt/one-node' \
		'EnvironmentFile=/opt/one-node/.env' \
		'ExecStart=/opt/one-node/one-node start' >"$UNIT_FILE"
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

restart_reconfigured_runtime() {
	grep -Fx 'NODE_NODE_ID="41"' "$ENV_FILE" >/dev/null || return 1
	grep -Fx 'CONTROL_ADDR="grpcs://new.example:443"' "$ENV_FILE" >/dev/null || return 1
	grep -Fx 'CONTROL_BOOTSTRAP_TOKEN="new-token"' "$ENV_FILE" >/dev/null || return 1
	systemctl daemon-reload &&
		systemctl enable one-node.service &&
		systemctl restart one-node.service
}

wait_for_ready_heartbeat() {
	[ ! -e "$IDENTITY_FILE" ] || return 1
	[ ! -e "$RUNTIME_STATE_FILE" ] || return 1
	printf '%s\n' '{"node_id":"41","state":"active"}' >"$IDENTITY_FILE"
	printf '%s\n' '{"config":"fresh"}' >"$RUNTIME_STATE_FILE"
	chmod 0600 "$IDENTITY_FILE" "$RUNTIME_STATE_FILE"
	awk '!/^CONTROL_BOOTSTRAP_TOKEN=/' "$ENV_FILE" >"$ENV_FILE.ready"
	chmod 0600 "$ENV_FILE.ready"
	mv "$ENV_FILE.ready" "$ENV_FILE"
}

prepare_desired_native() {
	TEMP_DIR=$(mktemp -d "${CASE_DIR}/desired.XXXXXX")
	BINARY_SOURCE="${TEMP_DIR}/one-node"
	UNIT_SOURCE="${TEMP_DIR}/one-node.service"
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

run_upgrade_rollback() (
	configure_case rollback
	install -d -m 0755 "$INSTALL_DIR"
	install -d -m 0700 "$ONE_NODE_STATE_DIR"
	printf '%s\n' \
		'#!/bin/sh' \
		'case "$1:$2" in' \
		'  version:--product-name) printf "%s\\n" "26.808.2100" ;;' \
		'  version:--name) printf "%s\\n" "1.13.17" ;;' \
		'  *) exit 1 ;;' \
		'esac' >"$MANIFEST_BINARY_PATH"
	chmod 0755 "$MANIFEST_BINARY_PATH"
	printf '%s\n' 'NODE_NODE_ID="40"' 'CONTROL_ADDR="grpc://old.example:27521"' >"$ENV_FILE"
	chmod 0600 "$ENV_FILE"
	printf '%s\n' '{"node_id":"40","state":"active"}' >"$ONE_NODE_STATE_DIR/node-secret"
	chmod 0600 "$ONE_NODE_STATE_DIR/node-secret"
	write_managed_unit
	old_sha256=$(sha256sum "$MANIFEST_BINARY_PATH" | awk '{ print $1 }')
	manifest_reset
	MANIFEST_FORMAT=$MANIFEST_FORMAT_NAME
	MANIFEST_MODE=native
	MANIFEST_STATE_DIR=$ONE_NODE_STATE_DIR
	MANIFEST_DESIRED_CONFIG_REVISION=3
	MANIFEST_CURRENT_VERSION=26.808.2100
	MANIFEST_CURRENT_BINARY_PATH=$MANIFEST_BINARY_PATH
	MANIFEST_CURRENT_BINARY_SHA256=$old_sha256
	for owned_path in \
		"$MANIFEST_INSTALL_DIR" "$MANIFEST_ENV_PATH" "$MANIFEST_RECORD_PATH" \
		"$MANIFEST_STATE_DIR" "$MANIFEST_BINARY_PATH" "$MANIFEST_UNIT_PATH"
	do
		manifest_append_owned_path "$owned_path"
	done
	MANIFEST_OWNED_COUNT=6
	manifest_write "$INSTALL_RECORD"
	cp "$MANIFEST_BINARY_PATH" "${CASE_DIR}/binary.before"
	cp "$ENV_FILE" "${CASE_DIR}/env.before"
	cp "$INSTALL_RECORD" "${CASE_DIR}/manifest.before"
	cp "$UNIT_FILE" "${CASE_DIR}/unit.before"
	cp "$ONE_NODE_STATE_DIR/node-secret" "${CASE_DIR}/identity.before"

	validate_install_target
	prepare_desired_native
	wait_for_ready_heartbeat() {
		printf '%s\n' changed >"$ONE_NODE_STATE_DIR/node-secret"
		chmod 0600 "$ONE_NODE_STATE_DIR/node-secret"
		return 1
	}
	set +e
	(reconfigure_native_installation) >"${CASE_DIR}/rollback.log" 2>&1
	reconfigure_status=$?
	set -e
	[ "$reconfigure_status" -ne 0 ] || fail "failed upgrade returned success"
	grep -F 'the previous installation was restored' "${CASE_DIR}/rollback.log" >/dev/null
	cmp -s "$MANIFEST_BINARY_PATH" "${CASE_DIR}/binary.before" || fail "binary rollback failed"
	cmp -s "$ENV_FILE" "${CASE_DIR}/env.before" || fail "environment rollback failed"
	cmp -s "$INSTALL_RECORD" "${CASE_DIR}/manifest.before" || fail "manifest rollback failed"
	cmp -s "$UNIT_FILE" "${CASE_DIR}/unit.before" || fail "unit rollback failed"
	cmp -s "$ONE_NODE_STATE_DIR/node-secret" "${CASE_DIR}/identity.before" ||
		fail "identity rollback failed"
)

run_stale_unit_recovery
run_upgrade_rollback
