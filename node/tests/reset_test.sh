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
. "$ROOT_DIR/scripts/install/config.sh"
. "$ROOT_DIR/scripts/install/host.sh"
. "$ROOT_DIR/scripts/install/firewall.sh"
. "$ROOT_DIR/scripts/install/readiness.sh"

initialize_install_config
INSTALL_DIR="$TEST_TEMP_DIR/install"
INSTALL_RECORD="$INSTALL_DIR/.installation"
UNIT_FILE="$TEST_TEMP_DIR/one-node.service"
ONE_NODE_STATE_DIR="$TEST_TEMP_DIR/state"
CONTAINER_NAME="one-node"
RESET_EXISTING="true"
ONE_NODE_ALLOW_INSECURE="true"

SYSTEMCTL_LOG="$TEST_TEMP_DIR/systemctl.log"
DOCKER_LOG="$TEST_TEMP_DIR/docker.log"
systemctl() {
	printf '%s\n' "$*" >>"$SYSTEMCTL_LOG"
}
docker() {
	printf '%s\n' "$*" >>"$DOCKER_LOG"
	[ "$1" != inspect ]
}

install -d -m 0755 "$INSTALL_DIR"
install -d -m 0700 "$ONE_NODE_STATE_DIR"
printf '%s\n' 'format=v2' 'unknown_field=removed' >"$INSTALL_RECORD"
printf '%s\n' '[Service]' >"$UNIT_FILE"
printf '%s\n' stale >"$ONE_NODE_STATE_DIR/node-secret"

validate_install_target
[ ! -e "$INSTALL_DIR" ] || fail "reset preserved the old installation directory"
[ ! -e "$ONE_NODE_STATE_DIR" ] || fail "reset preserved the old state directory"
[ ! -e "$UNIT_FILE" ] || fail "reset preserved the old systemd unit"
grep -F 'disable --now one-node.service' "$SYSTEMCTL_LOG" >/dev/null
grep -F 'daemon-reload' "$SYSTEMCTL_LOG" >/dev/null
grep -F 'rm -f one-node' "$DOCKER_LOG" >/dev/null

symlink_target="$TEST_TEMP_DIR/symlink-target"
install -d -m 0755 "$symlink_target"
ln -s "$symlink_target" "$INSTALL_DIR"
if (validate_install_target) >"$TEST_TEMP_DIR/symlink.log" 2>&1; then
	fail "reset accepted a symlink installation directory"
fi
[ -d "$symlink_target" ] || fail "reset removed a symlink target"

RUNTIME_STATE_FILE="$TEST_TEMP_DIR/runtime-active.json"
ONE_NODE_EXPECTED_CONFIG_REVISION=0
runtime_revisions_are_ready || fail "unconfigured development enrollment was not ready"
