#!/bin/sh
# shellcheck disable=SC1091,SC2016,SC2034
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

# The service account is host-global; tests never create one.
ensure_native_service_user() { return 0; }

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

# Per-unit fake systemd: state lives in files so subshells share it.
systemctl() {
	printf '%s\n' "$*" >>"$SYSTEMCTL_LOG"
	fake_action=$1
	shift
	fake_now=false
	for fake_unit in "$@"; do :; done
	for fake_arg in "$@"; do [ "$fake_arg" != --now ] || fake_now=true; done
	case "$fake_action" in
	is-active) [ -e "${UNIT_STATE_DIR}/${fake_unit}.active" ] ;;
	is-enabled) [ -e "${UNIT_STATE_DIR}/${fake_unit}.enabled" ] ;;
	start|restart) : >"${UNIT_STATE_DIR}/${fake_unit}.active" ;;
	stop) rm -f -- "${UNIT_STATE_DIR}/${fake_unit}.active" ;;
	enable)
		: >"${UNIT_STATE_DIR}/${fake_unit}.enabled"
		[ "$fake_now" = false ] || : >"${UNIT_STATE_DIR}/${fake_unit}.active"
		;;
	disable)
		rm -f -- "${UNIT_STATE_DIR}/${fake_unit}.enabled"
		[ "$fake_now" = false ] || rm -f -- "${UNIT_STATE_DIR}/${fake_unit}.active"
		;;
	esac
}

nft() {
	printf '%s\n' "$*" >>"$NFT_LOG"
}

docker() {
	return 1
}

configure_case() {
	case_name=$1
	CASE_DIR="${TEST_TEMP_DIR}/${case_name}"
	INSTALL_DIR="${CASE_DIR}/opt/one-node"
	ENV_FILE="${INSTALL_DIR}/.env"
	UNIT_FILE="${CASE_DIR}/systemd/one-node.service"
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
	MANIFEST_FIREWALL_SERVICE_PATH="${CASE_DIR}/systemd/one-node-firewall.service"
	MANIFEST_FIREWALL_PATH_UNIT_PATH="${CASE_DIR}/systemd/one-node-firewall.path"
	FIREWALL_FILE=$MANIFEST_FIREWALL_PATH
	FIREWALL_SERVICE_FILE=$MANIFEST_FIREWALL_SERVICE_PATH
	FIREWALL_PATH_FILE=$MANIFEST_FIREWALL_PATH_UNIT_PATH
	FIREWALL_REQUEST_FILE="${ONE_NODE_STATE_DIR}/firewall/request"
	UPDATER_FILE="${INSTALL_DIR}/updater.sh"
	UPDATER_SERVICE_FILE="${CASE_DIR}/systemd/one-node-updater.service"
	UPDATER_PATH_FILE="${CASE_DIR}/systemd/one-node-updater.path"
	HOST_UPDATER_ENABLED="false"
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
	SYSTEMCTL_LOG="${CASE_DIR}/systemctl.log"
	NFT_LOG="${CASE_DIR}/nft.log"
	UNIT_STATE_DIR="${CASE_DIR}/units"
	install -d -m 0755 "$CASE_DIR" "$UNIT_STATE_DIR" "${CASE_DIR}/systemd"
}

write_old_native_installation() {
	install -d -m 0755 "$INSTALL_DIR"
	install -d -m 0700 "$ONE_NODE_STATE_DIR" "${ONE_NODE_STATE_DIR}/traffic-spool"
	printf '%s\n' \
		'#!/bin/sh' \
		'case "$1:$2" in' \
		'  version:--product-name) printf "%s\\n" "26.808.2100" ;;' \
		'  *) exit 1 ;;' \
		'esac' >"$MANIFEST_BINARY_PATH"
	chmod 0755 "$MANIFEST_BINARY_PATH"
	printf '%s\n' '#!/bin/sh' 'mkdir -p "$ONE_NODE_FIREWALL_DIR"' \
		': >"$ONE_NODE_FIREWALL_DIR/old-initialized"' >"$FIREWALL_FILE"
	chmod 0700 "$FIREWALL_FILE"
	printf '%s\n' 'NODE_NODE_ID="40"' 'CONTROL_ADDR="grpc://old.example:27521"' >"$ENV_FILE"
	chmod 0600 "$ENV_FILE"
	printf '%s\n' '{"node_id":"40","state":"active"}' >"$ONE_NODE_STATE_DIR/node-secret"
	printf '%s\n' '{"config":"old"}' >"$ONE_NODE_STATE_DIR/runtime-active.json"
	printf '%s\n' old-traffic >"$ONE_NODE_STATE_DIR/traffic-spool/pending.jsonl"
	chmod 0600 "$ONE_NODE_STATE_DIR/node-secret" "$ONE_NODE_STATE_DIR/runtime-active.json"
	printf '%s\n' \
		'[Service]' \
		'WorkingDirectory=/opt/one-node' \
		'EnvironmentFile=/opt/one-node/.env' \
		'ExecStart=/opt/one-node/one-node start' >"$UNIT_FILE"
	chmod 0644 "$UNIT_FILE"
	printf '%s\n' '[Service]' 'ExecStart=/opt/one-node/firewall.sh' >"$FIREWALL_SERVICE_FILE"
	printf '%s\n' '[Path]' >"$FIREWALL_PATH_FILE"
	chmod 0644 "$FIREWALL_SERVICE_FILE" "$FIREWALL_PATH_FILE"
	manifest_reset
	MANIFEST_FORMAT=$MANIFEST_FORMAT_NAME
	MANIFEST_MODE=native
	MANIFEST_STATE_DIR=$ONE_NODE_STATE_DIR
	MANIFEST_DESIRED_CONFIG_REVISION=3
	MANIFEST_CURRENT_VERSION=26.808.2100
	MANIFEST_CURRENT_BINARY_PATH=$MANIFEST_BINARY_PATH
	MANIFEST_CURRENT_BINARY_SHA256=$(sha256sum "$MANIFEST_BINARY_PATH" | awk '{ print $1 }')
	for owned_path in \
		"$MANIFEST_INSTALL_DIR" "$MANIFEST_ENV_PATH" "$MANIFEST_RECORD_PATH" \
		"$MANIFEST_STATE_DIR" "$MANIFEST_BINARY_PATH" "$MANIFEST_UNIT_PATH" \
		"$MANIFEST_FIREWALL_PATH" "$MANIFEST_FIREWALL_SERVICE_PATH" \
		"$MANIFEST_FIREWALL_PATH_UNIT_PATH"
	do
		manifest_append_owned_path "$owned_path"
	done
	MANIFEST_OWNED_COUNT=9
	manifest_write "$INSTALL_RECORD"
	: >"${UNIT_STATE_DIR}/one-node.service.enabled"
	: >"${UNIT_STATE_DIR}/one-node.service.active"
	: >"${UNIT_STATE_DIR}/one-node-firewall.path.enabled"

	SNAPSHOT_DIR="${CASE_DIR}/before"
	install -d -m 0700 "$SNAPSHOT_DIR"
	cp -pR "$INSTALL_DIR" "$SNAPSHOT_DIR/install"
	cp -pR "$ONE_NODE_STATE_DIR" "$SNAPSHOT_DIR/state"
	cp -p "$UNIT_FILE" "$SNAPSHOT_DIR/unit"
	cp -p "$FIREWALL_SERVICE_FILE" "$SNAPSHOT_DIR/firewall.service"
}

prepare_desired_native() {
	BINARY_SOURCE="${TEMP_DIR}/one-node"
	UNIT_SOURCE="${TEMP_DIR}/one-node.service"
	printf '%s\n' '#!/bin/sh' 'printf "%s\\n" "26.809.2200"' >"$BINARY_SOURCE"
	chmod 0755 "$BINARY_SOURCE"
	ONE_NODE_VERSION="26.809.2200"
	ONE_NODE_BINARY_SHA256=$(sha256sum "$BINARY_SOURCE" | awk '{ print $1 }')
	write_native_source
}

# Mirrors the replacement part of main(): the new runtime starts and then
# either becomes ready or fails readiness.
run_replacement() {
	new_ready=$1
	validate_install_target
	[ "$INSTALL_OPERATION:$INSTALL_MANIFEST_KIND" = "replace:current" ] ||
		fail "healthy installation did not select replacement"
	initialize_install_workspace
	prepare_desired_native
	replace_existing_installation
	[ ! -e "$ONE_NODE_STATE_DIR" ] || fail "replacement kept the old state at its path"
	[ ! -e "$UNIT_FILE" ] || fail "replacement kept the old unit at its path"
	prepare_install_directories
	write_common_sources
	install_common_files
	install_native_runtime
	printf '%s\n' '{"node_id":"41","state":"pending"}' >"$ONE_NODE_STATE_DIR/node-secret"
	chmod 0600 "$ONE_NODE_STATE_DIR/node-secret"
	[ "$new_ready" = true ] || die "Node registration did not complete"
	INSTALL_COMMITTED="true"
	discard_replaced_installation
}

assert_backup_removed() {
	for leftover in "$(dirname "$INSTALL_DIR")"/.one-node-replace.*; do
		[ ! -e "$leftover" ] || fail "replacement backup was left behind: $leftover"
	done
}

run_failed_replacement_restores() (
	configure_case failed
	write_old_native_installation
	set +e
	(run_replacement false) >"${CASE_DIR}/install.log" 2>&1
	install_status=$?
	set -e
	[ "$install_status" -ne 0 ] || fail "failed replacement returned success"
	grep -F 'were restored and restarted' "${CASE_DIR}/install.log" >/dev/null ||
		fail "failed replacement did not report the restore"
	diff -r "$SNAPSHOT_DIR/install" "$INSTALL_DIR" >/dev/null ||
		fail "program, environment, firewall script, or manifest were not restored"
	diff -r "$SNAPSHOT_DIR/state" "$ONE_NODE_STATE_DIR" -x firewall >/dev/null ||
		fail "identity, runtime state, or telemetry spool were not restored"
	cmp -s "$SNAPSHOT_DIR/unit" "$UNIT_FILE" || fail "native unit was not restored"
	cmp -s "$SNAPSHOT_DIR/firewall.service" "$FIREWALL_SERVICE_FILE" ||
		fail "firewall unit was not restored"
	[ "$(file_mode "$ONE_NODE_STATE_DIR")" = 700 ] || fail "restored state directory mode changed"
	[ "$(file_mode "$ONE_NODE_STATE_DIR/node-secret")" = 600 ] || fail "restored identity mode changed"
	[ -e "$ONE_NODE_STATE_DIR/firewall/old-initialized" ] ||
		fail "the restored firewall script was not re-initialized"
	[ -e "${UNIT_STATE_DIR}/one-node.service.enabled" ] &&
		[ -e "${UNIT_STATE_DIR}/one-node.service.active" ] ||
		fail "the previous runtime was not restarted"
	[ -e "${UNIT_STATE_DIR}/one-node-firewall.path.enabled" ] ||
		fail "the previous firewall watcher was not re-enabled"
	[ ! -e "${UNIT_STATE_DIR}/one-node-updater.path.enabled" ] ||
		fail "restore enabled a unit that was not enabled before"
	assert_backup_removed
)

run_successful_replacement_discards_backup() (
	configure_case succeeded
	write_old_native_installation
	(run_replacement true) >"${CASE_DIR}/install.log" 2>&1 ||
		fail "successful replacement failed: $(cat "${CASE_DIR}/install.log")"
	grep -F '"node_id":"41"' "$ONE_NODE_STATE_DIR/node-secret" >/dev/null ||
		fail "successful replacement restored the previous identity"
	[ ! -e "$ONE_NODE_STATE_DIR/traffic-spool" ] || fail "previous telemetry spool survived replacement"
	manifest_load "$INSTALL_RECORD"
	[ "$MANIFEST_CURRENT_VERSION" = "26.809.2200" ] || fail "new manifest was not kept"
	assert_backup_removed
)

# A failure while the old installation is still being moved aside puts back
# what was already moved and restarts the previous runtime.
run_interrupted_backup_restores() (
	configure_case interrupted
	write_old_native_installation
	set +e
	(
		validate_install_target
		initialize_install_workspace
		prepare_desired_native
		cp() {
			case "$*" in
			*"$ONE_NODE_STATE_DIR"*) return 1 ;;
			esac
			command cp "$@"
		}
		replace_existing_installation
	) >"${CASE_DIR}/install.log" 2>&1
	install_status=$?
	set -e
	[ "$install_status" -ne 0 ] || fail "interrupted replacement returned success"
	diff -r "$SNAPSHOT_DIR/install" "$INSTALL_DIR" >/dev/null ||
		fail "interrupted replacement did not restore the program files"
	diff -r "$SNAPSHOT_DIR/state" "$ONE_NODE_STATE_DIR" -x firewall >/dev/null ||
		fail "interrupted replacement touched the state directory"
	cmp -s "$SNAPSHOT_DIR/unit" "$UNIT_FILE" || fail "interrupted replacement lost the unit"
	[ -e "${UNIT_STATE_DIR}/one-node.service.active" ] ||
		fail "interrupted replacement did not restart the previous runtime"
	assert_backup_removed
)

# Recovery without a manifest recognizes both the legacy root unit and the
# service-account unit, and still rejects foreign lifecycle commands.
run_unit_recognition() (
	configure_case units
	UNIT_SOURCE="${CASE_DIR}/generated.service"
	write_native_source
	install -m 0644 "$UNIT_SOURCE" "$UNIT_FILE"
	(validate_managed_native_unit) || fail "service-account unit was not recognized"
	printf '%s\n' 'ExecStartPost=/bin/sh -c true' >>"$UNIT_FILE"
	if (validate_managed_native_unit) >/dev/null 2>&1; then
		fail "unit with an unmanaged lifecycle command was accepted"
	fi
	printf '%s\n' '[Service]' 'WorkingDirectory=/opt/one-node' \
		'EnvironmentFile=/opt/one-node/.env' 'ExecStart=/opt/one-node/one-node start' >"$UNIT_FILE"
	(validate_managed_native_unit) || fail "legacy root unit was not recognized"
	printf '%s\n' "ExecStartPre=+/bin/chown -hR one-node:one-node ${ONE_NODE_STATE_DIR}" >>"$UNIT_FILE"
	if (validate_managed_native_unit) >/dev/null 2>&1; then
		fail "legacy unit with a start hook was accepted"
	fi
)

run_unit_recognition
run_failed_replacement_restores
run_successful_replacement_discards_backup
run_interrupted_backup_restores

printf '%s\n' 'One Node reinstall rollback checks passed.'
