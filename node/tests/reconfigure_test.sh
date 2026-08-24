#!/bin/sh
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
. "$ROOT_DIR/scripts/install/native.sh"
. "$ROOT_DIR/scripts/install/native_reconfigure.sh"

sha256sum() {
	if command -v shasum >/dev/null 2>&1; then
		command shasum -a 256 "$@"
	else
		command sha256sum "$@"
	fi
}

initialize_install_config
INSTALL_DIR="$TEST_TEMP_DIR/install"
ENV_FILE="${INSTALL_DIR}/.env"
UNIT_FILE="$TEST_TEMP_DIR/one-node.service"
COMPOSE_FILE="${INSTALL_DIR}/docker-compose.yml"
INSTALL_RECORD="${INSTALL_DIR}/.installation"
ONE_NODE_STATE_DIR="$TEST_TEMP_DIR/state"
MANIFEST_INSTALL_DIR=$INSTALL_DIR
MANIFEST_BINARY_PATH="${INSTALL_DIR}/one-node"
MANIFEST_ENV_PATH=$ENV_FILE
MANIFEST_RECORD_PATH=$INSTALL_RECORD
MANIFEST_UNIT_PATH=$UNIT_FILE
MANIFEST_COMPOSE_PATH=$COMPOSE_FILE
MANIFEST_PREVIOUS_DIR="${INSTALL_DIR}/previous"
MANIFEST_PREVIOUS_BINARY_PATH_FIXED="${MANIFEST_PREVIOUS_DIR}/one-node"

manifest_validate_state_dir() {
	[ "$1" = "$ONE_NODE_STATE_DIR" ]
}

install -d -m 0755 "$INSTALL_DIR"
install -d -m 0700 "$ONE_NODE_STATE_DIR"
printf '%s\n' \
	'#!/bin/sh' \
	'case "$1:$2" in' \
	'  version:--product-name) printf "%s\\n" "26.808.2100" ;;' \
	'  version:--name) printf "%s\\n" "1.13.18" ;;' \
	'  *) exit 1 ;;' \
	'esac' >"$MANIFEST_BINARY_PATH"
chmod 0755 "$MANIFEST_BINARY_PATH"
printf '%s\n' \
	'[Service]' \
	'WorkingDirectory=/opt/one-node' \
	'EnvironmentFile=/opt/one-node/.env' \
	'ExecStart=/opt/one-node/one-node start' >"$UNIT_FILE"
chmod 0644 "$UNIT_FILE"
printf '%s\n' \
	'NODE_NODE_ID="40"' \
	'NODE_STATE_DIR="old-state"' \
	'CONTROL_ADDR="grpc://old.example:27521"' >"$ENV_FILE"
chmod 0600 "$ENV_FILE"
printf '%s\n' '{"node_id":"40","state":"active"}' >"$ONE_NODE_STATE_DIR/node-secret"
printf '%s\n' '{"config":"old"}' >"$ONE_NODE_STATE_DIR/runtime-active.json"
chmod 0600 "$ONE_NODE_STATE_DIR/node-secret" "$ONE_NODE_STATE_DIR/runtime-active.json"
install -d -m 0700 \
	"$ONE_NODE_STATE_DIR/traffic-spool" \
	"$ONE_NODE_STATE_DIR/access-event-spool"
printf '%s\n' old-traffic >"$ONE_NODE_STATE_DIR/traffic-spool/pending.jsonl"
printf '%s\n' old-access >"$ONE_NODE_STATE_DIR/access-event-spool/pending.jsonl"
chmod 0600 \
	"$ONE_NODE_STATE_DIR/traffic-spool/pending.jsonl" \
	"$ONE_NODE_STATE_DIR/access-event-spool/pending.jsonl"

binary_sha256=$(sha256sum "$MANIFEST_BINARY_PATH" | awk '{ print $1 }')
manifest_reset
MANIFEST_FORMAT=$MANIFEST_FORMAT_NAME
MANIFEST_MODE=native
MANIFEST_STATE_DIR=$ONE_NODE_STATE_DIR
MANIFEST_DESIRED_CONFIG_REVISION=3
MANIFEST_CURRENT_VERSION=26.808.2100
MANIFEST_CURRENT_BINARY_PATH=$MANIFEST_BINARY_PATH
MANIFEST_CURRENT_BINARY_SHA256=$binary_sha256
for owned_path in \
	"$MANIFEST_INSTALL_DIR" "$MANIFEST_ENV_PATH" "$MANIFEST_RECORD_PATH" \
	"$MANIFEST_STATE_DIR" "$MANIFEST_BINARY_PATH" "$MANIFEST_UNIT_PATH"
do
	manifest_append_owned_path "$owned_path"
done
MANIFEST_OWNED_COUNT=6
manifest_write "$INSTALL_RECORD"

validate_install_target
[ "$INSTALL_OPERATION" = replace ] || fail "existing managed installation did not select replacement"
[ "$MANIFEST_FORMAT" = "$MANIFEST_FORMAT_NAME" ] || fail "installation manifest format changed"

if ! (INSTALL_MODE=docker; validate_install_target); then
	fail "replacement rejected a new installation mode"
fi

mv "$ENV_FILE" "$ENV_FILE.real"
ln -s "$ENV_FILE.real" "$ENV_FILE"
if (validate_install_target) >"$TEST_TEMP_DIR/symlink.log" 2>&1; then
	fail "reconfiguration accepted a symlink environment file"
fi
rm -f -- "$ENV_FILE"
mv "$ENV_FILE.real" "$ENV_FILE"

mv "$ONE_NODE_STATE_DIR/node-secret" "$ONE_NODE_STATE_DIR/node-secret.real"
ln -s "$ONE_NODE_STATE_DIR/node-secret.real" "$ONE_NODE_STATE_DIR/node-secret"
if (validate_install_target) >"$TEST_TEMP_DIR/identity-symlink.log" 2>&1; then
	fail "reconfiguration accepted a symlink identity file"
fi
rm -f -- "$ONE_NODE_STATE_DIR/node-secret"
mv "$ONE_NODE_STATE_DIR/node-secret.real" "$ONE_NODE_STATE_DIR/node-secret"

RESTART_LOG="$TEST_TEMP_DIR/restarts"
SYSTEMCTL_LOG="$TEST_TEMP_DIR/systemctl"
systemctl() {
	printf '%s\n' "$*" >>"$SYSTEMCTL_LOG"
	case "$1" in
	is-active|is-enabled) return 0 ;;
	esac
}
restart_reconfigured_runtime() {
	printf '%s\n' restart >>"$RESTART_LOG"
}
wait_for_ready_heartbeat() {
	grep -Fx 'NODE_NODE_ID="41"' "$ENV_FILE" >/dev/null || return 1
	grep -Fx 'CONTROL_ADDR="grpc://new.example:27521"' "$ENV_FILE" >/dev/null || return 1
	grep -Fx 'CONTROL_BOOTSTRAP_TOKEN="new-token"' "$ENV_FILE" >/dev/null || return 1
	[ ! -e "$IDENTITY_FILE" ] || return 1
	[ ! -e "$RUNTIME_STATE_FILE" ] || return 1
	printf '%s\n' '{"node_id":"41","state":"active"}' >"$IDENTITY_FILE"
	printf '%s\n' '{"config":"fresh"}' >"$RUNTIME_STATE_FILE"
	chmod 0600 "$IDENTITY_FILE" "$RUNTIME_STATE_FILE"
	awk '!/^CONTROL_BOOTSTRAP_TOKEN=/' "$ENV_FILE" >"$ENV_FILE.ready"
	chmod 0600 "$ENV_FILE.ready"
	mv "$ENV_FILE.ready" "$ENV_FILE"
}

ONE_NODE_SERVER='grpc://new.example:27521'
ONE_NODE_ID=41
ONE_NODE_BOOTSTRAP_TOKEN=new-token
ONE_NODE_EXPECTED_CONFIG_REVISION=7
ONE_NODE_VERSION=26.808.2100
ONE_NODE_BINARY_SHA256=$binary_sha256
prepare_desired_artifacts() {
	TEMP_DIR=$(mktemp -d "$TEST_TEMP_DIR/desired.XXXXXX")
	BINARY_SOURCE="${TEMP_DIR}/one-node"
	UNIT_SOURCE="${TEMP_DIR}/one-node.service"
	install -m 0755 "$MANIFEST_BINARY_PATH" "$BINARY_SOURCE"
	write_native_source
}
prepare_desired_artifacts
if ! (reconfigure_native_installation); then
	fail "valid existing installation was not reconfigured"
fi
grep -Fx 'NODE_NODE_ID="41"' "$ENV_FILE" >/dev/null
grep -Fx 'CONTROL_ADDR="grpc://new.example:27521"' "$ENV_FILE" >/dev/null
if grep -q '^CONTROL_BOOTSTRAP_TOKEN=' "$ENV_FILE"; then
	fail "successful enrollment retained its bootstrap token"
fi
grep -F '"node_id":"41"' "$IDENTITY_FILE" >/dev/null ||
	fail "successful enrollment retained the previous node identity"
grep -F '"config":"fresh"' "$RUNTIME_STATE_FILE" >/dev/null ||
	fail "successful enrollment retained the previous runtime state"
[ ! -e "$ONE_NODE_STATE_DIR/traffic-spool" ] ||
	fail "successful enrollment retained the previous node traffic spool"
[ ! -e "$ONE_NODE_STATE_DIR/access-event-spool" ] ||
	fail "successful enrollment retained the previous node access-event spool"
[ "$(sha256sum "$MANIFEST_BINARY_PATH" | awk '{ print $1 }')" = "$binary_sha256" ] ||
	fail "reconfiguration replaced the installed binary"
manifest_load "$INSTALL_RECORD"
[ "$MANIFEST_CURRENT_VERSION" = 26.808.2100 ] || fail "reconfiguration changed the One Node product release version"
[ "$("$MANIFEST_BINARY_PATH" version --name)" = 1.13.18 ] || fail "reconfiguration changed the sing-box core version"
[ "$MANIFEST_CURRENT_BINARY_SHA256" = "$binary_sha256" ] || fail "reconfiguration changed the binary checksum"
[ "$MANIFEST_DESIRED_CONFIG_REVISION" = 7 ] || fail "config revision was not updated"

cp "$ENV_FILE" "$TEST_TEMP_DIR/env.before-failure"
cp "$INSTALL_RECORD" "$TEST_TEMP_DIR/manifest.before-failure"
cp "$ONE_NODE_STATE_DIR/node-secret" "$TEST_TEMP_DIR/identity.before-failure"
cp "$ONE_NODE_STATE_DIR/runtime-active.json" "$TEST_TEMP_DIR/runtime.before-failure"
ONE_NODE_SERVER='grpc://failed.example:27521'
ONE_NODE_ID=42
ONE_NODE_BOOTSTRAP_TOKEN=failed-token
ONE_NODE_EXPECTED_CONFIG_REVISION=9
wait_for_ready_heartbeat() {
	printf '%s\n' changed >"$IDENTITY_FILE"
	printf '%s\n' changed >"$RUNTIME_STATE_FILE"
	chmod 0600 "$IDENTITY_FILE" "$RUNTIME_STATE_FILE"
	die "forced readiness failure"
}
prepare_desired_artifacts
set +e
(reconfigure_native_installation) >"$TEST_TEMP_DIR/rollback.log" 2>&1
rollback_status=$?
set -e
[ "$rollback_status" -ne 0 ] || fail "failed registration update returned success"
grep -F 'the previous installation was restored' "$TEST_TEMP_DIR/rollback.log" >/dev/null
cmp -s "$ENV_FILE" "$TEST_TEMP_DIR/env.before-failure" || fail "environment rollback failed"
cmp -s "$INSTALL_RECORD" "$TEST_TEMP_DIR/manifest.before-failure" || fail "manifest rollback failed"
cmp -s "$ONE_NODE_STATE_DIR/node-secret" "$TEST_TEMP_DIR/identity.before-failure" || fail "identity rollback failed"
cmp -s "$ONE_NODE_STATE_DIR/runtime-active.json" "$TEST_TEMP_DIR/runtime.before-failure" || fail "runtime state rollback failed"
[ "$(wc -l <"$RESTART_LOG" | tr -d ' ')" = 2 ] || fail "runtime was not restarted after each update"
grep -F 'start one-node.service' "$SYSTEMCTL_LOG" >/dev/null ||
	fail "previous runtime was not restarted after rollback"
[ "$(sha256sum "$MANIFEST_BINARY_PATH" | awk '{ print $1 }')" = "$binary_sha256" ] ||
	fail "failed reconfiguration replaced the installed binary"
