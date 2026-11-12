#!/bin/sh
# ONE_NODE_INSTALL_DIR moves an installation off /opt/one-node (a host whose
# /opt/one-node holds the One Node Server). The default must not change, later
# runs must find the directory without the variable, and an installation must
# never claim a directory that holds someone else's files.
# shellcheck disable=SC1090,SC1091,SC2034
set -eu

ROOT_DIR=$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)
TEST_TEMP_DIR=$(mktemp -d)
# macOS TMPDIR ends in a slash; ONE_NODE_INSTALL_DIR must be canonical.
TEST_TEMP_DIR=$(CDPATH='' cd -- "$TEST_TEMP_DIR" && pwd -P)
trap 'rm -rf -- "$TEST_TEMP_DIR"' EXIT HUP INT TERM

fail() {
	printf '%s\n' "$*" >&2
	exit 1
}

BOOTSTRAP="$ROOT_DIR/scripts/shared/bootstrap.sh"
UNITS="$TEST_TEMP_DIR/systemd"
install -d -m 0755 "$UNITS"

# Resolves the install directory the way an entrypoint does, with the unit
# directory replaced by the fixture. Prints the directory or the error.
resolve() {
	(
		unset ONE_NODE_INSTALL_DIR
		[ -z "${1:-}" ] || ONE_NODE_INSTALL_DIR=$1
		# The top-level call reads the real unit directory; it is repeated
		# against the fixture below.
		ONE_NODE_INSTALL_DIR_REQUESTED=${ONE_NODE_INSTALL_DIR:-}
		unset ONE_NODE_INSTALL_DIR
		. "$BOOTSTRAP" >/dev/null 2>&1
		unset ONE_NODE_INSTALL_DIR
		[ -z "$ONE_NODE_INSTALL_DIR_REQUESTED" ] || ONE_NODE_INSTALL_DIR=$ONE_NODE_INSTALL_DIR_REQUESTED
		bootstrap_resolve_install_dir "$UNITS"
		printf '%s\n' "$ONE_NODE_INSTALL_DIR"
	) 2>&1
}

# --- Path validation.
(
	. "$BOOTSTRAP" >/dev/null 2>&1
	for safe_dir in /opt/one-node /opt/one-node/node /srv/one_node/agent-1 "$TEST_TEMP_DIR/custom"; do
		bootstrap_install_dir_is_safe "$safe_dir" || fail "safe install directory was refused: $safe_dir"
	done
	for unsafe_dir in '' / /opt opt/one-node /opt/one-node/ /opt//one-node /opt/one-node/../x /opt/./x \
		'/opt/one node' '/opt/one-node;x' '/opt/one-node/$x' /var/lib/one-node /var/lib/one-node/install; do
		if bootstrap_install_dir_is_safe "$unsafe_dir"; then
			fail "unsafe install directory was accepted: $unsafe_dir"
		fi
	done
) || exit 1
printf '%s\n' 'ok - install directory must be a canonical path outside the state directory'

# --- Nothing installed: the default stays /opt/one-node; the variable wins.
[ "$(resolve)" = /opt/one-node ] || fail "default install directory changed: $(resolve)"
[ "$(resolve /opt/one-node/node)" = /opt/one-node/node ] || fail "ONE_NODE_INSTALL_DIR was ignored"
case "$(resolve /opt)" in
*'ONE_NODE_INSTALL_DIR must be a canonical absolute path'*) ;;
*) fail "an unsafe ONE_NODE_INSTALL_DIR was accepted" ;;
esac
printf '%s\n' 'ok - default is /opt/one-node and ONE_NODE_INSTALL_DIR overrides it'

# --- Installed natively: remote entrypoints read the directory from the unit.
printf '%s\n' '[Service]' 'EnvironmentFile=/opt/one-node/node/.env' \
	'ExecStart=/opt/one-node/node/one-node start' >"$UNITS/one-node.service"
[ "$(resolve)" = /opt/one-node/node ] || fail "installed directory was not read from one-node.service: $(resolve)"
[ "$(resolve /opt/one-node/node)" = /opt/one-node/node ] || fail "matching ONE_NODE_INSTALL_DIR was refused"
case "$(resolve /opt/one-node)" in
*'already installed in /opt/one-node/node'*) ;;
*) fail "a second installation in another directory was not refused: $(resolve /opt/one-node)" ;;
esac
# A unit that does not run One Node from a safe path is not trusted.
printf '%s\n' '[Service]' 'ExecStart=/opt/one node/one-node start' >"$UNITS/one-node.service"
[ "$(resolve)" = /opt/one-node ] || fail "an unsafe unit path was used as the install directory"
rm -f -- "$UNITS/one-node.service"
printf '%s\n' 'ok - an installed native unit decides the directory and refuses a second one'

# --- Installed with Docker: only the host updater unit knows the directory.
printf '%s\n' '[Service]' 'ExecStart=/srv/agent/one-node/updater.sh' >"$UNITS/one-node-updater.service"
[ "$(resolve)" = /srv/agent/one-node ] || fail "installed directory was not read from the updater unit: $(resolve)"
rm -f -- "$UNITS/one-node-updater.service"
printf '%s\n' 'ok - a Docker installation is found through its updater unit'

# --- The retained installer manages the directory it lives in.
RETAINED="$TEST_TEMP_DIR/retained/node"
install -d -m 0755 "$RETAINED"
: >"$RETAINED/.installation"
{
	printf '%s\n' '#!/bin/sh' 'set -eu' 'unset ONE_NODE_INSTALL_DIR'
	printf '. %s >/dev/null 2>&1\n' "'$BOOTSTRAP'"
	printf '%s\n' 'printf "%s\n" "$ONE_NODE_INSTALL_DIR"'
} >"$RETAINED/install.sh"
chmod 0700 "$RETAINED/install.sh"
[ "$("$RETAINED/install.sh")" = "$RETAINED" ] ||
	fail "retained installer did not use its own directory: $("$RETAINED/install.sh")"
rm -f -- "$RETAINED/.installation"
[ "$("$RETAINED/install.sh")" = /opt/one-node ] ||
	fail "an installer outside an installation must fall back to the default"
printf '%s\n' 'ok - the retained installer uses the directory it is installed in'

# --- Modules place every owned path and unit under the chosen directory.
(
	ONE_NODE_INSTALL_DIR=/opt/one-node/node
	. "$ROOT_DIR/scripts/install/common.sh"
	. "$ROOT_DIR/scripts/shared/manifest.sh"
	. "$ROOT_DIR/scripts/install/config.sh"
	. "$ROOT_DIR/scripts/install/files.sh"
	. "$ROOT_DIR/scripts/uninstall/common.sh"
	initialize_install_config
	[ "$INSTALL_DIR" = /opt/one-node/node ] || fail "installer ignored ONE_NODE_INSTALL_DIR"
	[ "$ENV_FILE" = /opt/one-node/node/.env ] || fail "environment file left the install directory"
	[ "$INSTALL_RECORD" = /opt/one-node/node/.installation ] || fail "manifest left the install directory"
	for manifest_path in "$MANIFEST_INSTALL_DIR" "$MANIFEST_INSTALLER_PATH" "$MANIFEST_BINARY_PATH" \
		"$MANIFEST_PREVIOUS_DIR" "$MANIFEST_ENV_PATH" "$MANIFEST_COMPOSE_PATH" "$MANIFEST_RECORD_PATH" \
		"$MANIFEST_UPDATER_PATH" "$MANIFEST_FIREWALL_PATH"; do
		case "$manifest_path" in
		/opt/one-node/node|/opt/one-node/node/*) ;;
		*) fail "manifest path is outside the install directory: $manifest_path" ;;
		esac
	done
	ONE_NODE_STATE_DIR=/var/lib/one-node
	UNIT_SOURCE="$TEST_TEMP_DIR/custom.service"
	write_native_source
	grep -Fx 'EnvironmentFile=/opt/one-node/node/.env' "$UNIT_SOURCE" >/dev/null ||
		fail "unit does not read the environment from the install directory"
	grep -Fx 'ExecStart=/opt/one-node/node/one-node start' "$UNIT_SOURCE" >/dev/null ||
		fail "unit does not start the binary from the install directory"
	if grep -E '/opt/one-node/(\.env|one-node start)' "$UNIT_SOURCE" >/dev/null; then
		fail "unit still points at /opt/one-node"
	fi
	initialize_uninstall_config
	[ "$INSTALL_RECORD" = /opt/one-node/node/.installation ] || fail "uninstaller ignored ONE_NODE_INSTALL_DIR"
) || exit 1
(
	unset ONE_NODE_INSTALL_DIR
	. "$ROOT_DIR/scripts/install/common.sh"
	. "$ROOT_DIR/scripts/shared/manifest.sh"
	. "$ROOT_DIR/scripts/install/config.sh"
	initialize_install_config
	[ "$INSTALL_DIR" = /opt/one-node ] && [ "$MANIFEST_RECORD_PATH" = /opt/one-node/.installation ] ||
		fail "default install paths changed"
) || exit 1
printf '%s\n' 'ok - manifest paths and the systemd unit follow the install directory'

# --- A directory holding someone else's files is never claimed.
(
	. "$ROOT_DIR/scripts/install/common.sh"
	. "$ROOT_DIR/scripts/install/host.sh"
	INSTALL_DIR="$TEST_TEMP_DIR/server"
	INSTALL_RECORD="$INSTALL_DIR/.installation"
	(refuse_foreign_install_directory) || fail "a missing install directory was refused"
	install -d -m 0755 "$INSTALL_DIR/web"
	: >"$INSTALL_DIR/.env"
	: >"$INSTALL_DIR/docker-compose.yml"
	refusal=$( (refuse_foreign_install_directory) 2>&1) && fail "a One Node Server directory was accepted"
	case "$refusal" in
	*"ONE_NODE_INSTALL_DIR=${INSTALL_DIR}/node"*) ;;
	*) fail "refusal does not say how to pick another directory: $refusal" ;;
	esac
	[ -f "$INSTALL_DIR/.env" ] && [ -d "$INSTALL_DIR/web" ] || fail "refusal touched the foreign directory"
	rmdir "$INSTALL_DIR/web"
	: >"$INSTALL_DIR/.hidden-foreign"
	if (refuse_foreign_install_directory) >/dev/null 2>&1; then
		fail "a foreign dotfile was accepted"
	fi
	rm -f -- "$INSTALL_DIR/.hidden-foreign"
	: >"$INSTALL_DIR/one-node"
	: >"$INSTALL_DIR/install.sh"
	(refuse_foreign_install_directory) || fail "leftovers of a One Node installation were refused"
	install -d -m 0755 "$INSTALL_DIR/web"
	: >"$INSTALL_RECORD"
	(refuse_foreign_install_directory) || fail "a manifest-owned installation was refused"
) || exit 1
printf '%s\n' 'ok - a directory with foreign files is refused before anything is written'
