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
. "$ROOT_DIR/scripts/install/files.sh"
. "$ROOT_DIR/scripts/install/native.sh"
. "$ROOT_DIR/scripts/install/docker.sh"
. "$ROOT_DIR/scripts/uninstall/native.sh"
. "$ROOT_DIR/scripts/upgrade/native.sh"

sync() { :; }

# Fake account database: passwd/group files edited by fake tools in PATH.
FAKE_BIN="$TEST_TEMP_DIR/bin"
FAKE_DB="$TEST_TEMP_DIR/accounts"
ACCOUNT_LOG="$TEST_TEMP_DIR/accounts.log"
install -d -m 0755 "$FAKE_BIN" "$FAKE_DB"
: >"$FAKE_DB/passwd"
: >"$FAKE_DB/group"
cat >"$FAKE_BIN/getent" <<EOF
#!/bin/sh
grep "^\$2:" "$FAKE_DB/\$1"
EOF
cat >"$FAKE_BIN/groupadd" <<EOF
#!/bin/sh
printf '%s\n' "groupadd \$*" >>"$ACCOUNT_LOG"
for last; do :; done
printf '%s\n' "\$last:x:990:" >>"$FAKE_DB/group"
EOF
cat >"$FAKE_BIN/useradd" <<EOF
#!/bin/sh
printf '%s\n' "useradd \$*" >>"$ACCOUNT_LOG"
for last; do :; done
printf '%s\n' "\$last:x:990:990::/nonexistent:/usr/sbin/nologin" >>"$FAKE_DB/passwd"
EOF
cat >"$FAKE_BIN/userdel" <<EOF
#!/bin/sh
printf '%s\n' "userdel \$*" >>"$ACCOUNT_LOG"
grep -v "^\$1:" "$FAKE_DB/passwd" >"$FAKE_DB/passwd.next" || true
mv "$FAKE_DB/passwd.next" "$FAKE_DB/passwd"
EOF
cat >"$FAKE_BIN/groupdel" <<EOF
#!/bin/sh
printf '%s\n' "groupdel \$*" >>"$ACCOUNT_LOG"
grep -v "^\$1:" "$FAKE_DB/group" >"$FAKE_DB/group.next" || true
mv "$FAKE_DB/group.next" "$FAKE_DB/group"
EOF
chmod 0755 "$FAKE_BIN"/*
PATH="$FAKE_BIN:$PATH"

reset_accounts() {
	: >"$FAKE_DB/passwd"
	: >"$FAKE_DB/group"
	: >"$ACCOUNT_LOG"
}

# --- #11 native unit runs unprivileged with only network capabilities.
(
	ONE_NODE_STATE_DIR=/var/lib/one-node
	UNIT_SOURCE="$TEST_TEMP_DIR/one-node.service"
	write_native_source
	for directive in \
		'User=one-node' \
		'Group=one-node' \
		'WorkingDirectory=/var/lib/one-node' \
		'EnvironmentFile=/opt/one-node/.env' \
		'EnvironmentFile=-/var/lib/one-node/bootstrap.env' \
		'ExecStartPre=+/bin/chown -hR one-node:one-node /var/lib/one-node' \
		'ExecStart=/opt/one-node/one-node start' \
		'AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW' \
		'CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW' \
		'NoNewPrivileges=yes' \
		'ProtectSystem=strict' \
		'ProtectHome=yes' \
		'ReadWritePaths=/var/lib/one-node' \
		'PrivateTmp=yes' \
		'PrivateDevices=yes' \
		'ProtectKernelTunables=yes' \
		'ProtectKernelModules=yes' \
		'ProtectControlGroups=yes' \
		'RestrictSUIDSGID=yes' \
		'LockPersonality=yes' \
		'RestrictNamespaces=yes' \
		'LimitNOFILE=1048576' \
		'UMask=0077'
	do
		grep -Fx "$directive" "$UNIT_SOURCE" >/dev/null || fail "native unit lacks $directive"
	done
	if grep -E '^(User|Group)=root$|^ReadWritePaths=.*/opt/one-node' "$UNIT_SOURCE" >/dev/null; then
		fail "native unit still runs as root or can write the install directory"
	fi
	if (ONE_NODE_STATE_DIR='/var/lib/one-node/a b'; write_native_source) >/dev/null 2>&1; then
		fail "native unit accepted a state directory systemd would split"
	fi
)

# --- Service account: created once, recorded, idempotent.
(
	reset_accounts
	INSTALL_DIR="$TEST_TEMP_DIR/opt-create"
	install -d -m 0755 "$INSTALL_DIR"
	ensure_native_service_user || fail "service account was not created"
	[ "$NATIVE_SERVICE_ACCOUNT_CREATED" = true ] || fail "creation was not flagged"
	grep -F 'groupadd --system one-node' "$ACCOUNT_LOG" >/dev/null || fail "group was not a system group"
	grep -F -- 'useradd --system --gid one-node --no-create-home' "$ACCOUNT_LOG" >/dev/null ||
		fail "user was not a home-less system user"
	grep -E 'useradd .*--shell (/usr/sbin/nologin|/sbin/nologin|/bin/false) ' "$ACCOUNT_LOG" >/dev/null ||
		fail "user can log in"
	record="$INSTALL_DIR/.service-account"
	grep -Fx 'user=one-node' "$record" >/dev/null || fail "created user was not recorded"
	grep -Fx 'group=one-node' "$record" >/dev/null || fail "created group was not recorded"
	[ "$(file_mode "$record")" = 600 ] || fail "account record is not 0600"
	: >"$ACCOUNT_LOG"
	NATIVE_SERVICE_ACCOUNT_CREATED=false
	ensure_native_service_user || fail "existing service account was rejected"
	[ ! -s "$ACCOUNT_LOG" ] || fail "existing service account was recreated"
	[ "$NATIVE_SERVICE_ACCOUNT_CREATED" = false ] || fail "reuse was flagged as creation"
	[ "$(grep -c . "$record")" = 2 ] || fail "account record gained duplicate entries"

	remove_native_service_account
	grep -Fx 'userdel one-node' "$ACCOUNT_LOG" >/dev/null || fail "created user was not removed"
	grep -Fx 'groupdel one-node' "$ACCOUNT_LOG" >/dev/null || fail "created group was not removed"
	[ ! -e "$record" ] || fail "account record was not removed"
)
(
	# Pre-existing accounts are reused and never removed.
	reset_accounts
	printf '%s\n' 'one-node:x:500:' >"$FAKE_DB/group"
	printf '%s\n' 'one-node:x:500:500::/nonexistent:/usr/sbin/nologin' >"$FAKE_DB/passwd"
	INSTALL_DIR="$TEST_TEMP_DIR/opt-existing"
	install -d -m 0755 "$INSTALL_DIR"
	ensure_native_service_user || fail "pre-existing account was rejected"
	[ ! -e "$INSTALL_DIR/.service-account" ] || fail "pre-existing account was recorded as created"
	remove_native_service_account
	[ ! -s "$ACCOUNT_LOG" ] || fail "uninstall touched a pre-existing account"
)
(
	# A one-node account that is uid 0 would defeat the privilege drop.
	reset_accounts
	printf '%s\n' 'one-node:x:0:' >"$FAKE_DB/group"
	printf '%s\n' 'one-node:x:0:0::/root:/bin/sh' >"$FAKE_DB/passwd"
	INSTALL_DIR="$TEST_TEMP_DIR/opt-root"
	install -d -m 0755 "$INSTALL_DIR"
	if ensure_native_service_user; then
		fail "uid 0 one-node account was accepted"
	fi
)

# --- Native install prepares request directories before the first start.
(
	reset_accounts
	INSTALL_DIR="$TEST_TEMP_DIR/opt-install"
	ONE_NODE_STATE_DIR="$TEST_TEMP_DIR/state-install"
	UNIT_SOURCE="$TEST_TEMP_DIR/install.service"
	UNIT_FILE="$TEST_TEMP_DIR/installed.service"
	HOST_UPDATER_ENABLED=true
	install -d -m 0755 "$INSTALL_DIR"
	install -d -m 0700 "$ONE_NODE_STATE_DIR"
	SYSTEMCTL_LOG="$TEST_TEMP_DIR/systemctl-install.log"
	systemctl() { printf '%s\n' "$*" >>"$SYSTEMCTL_LOG"; }
	write_native_source
	install_native_runtime
	[ -d "$ONE_NODE_STATE_DIR/firewall" ] && [ -d "$ONE_NODE_STATE_DIR/update" ] ||
		fail "request directories were not created before start"
	grep -Fx 'User=one-node' "$UNIT_FILE" >/dev/null || fail "hardened unit was not installed"
	grep -Fx 'enable --now one-node.service' "$SYSTEMCTL_LOG" >/dev/null || fail "unit was not started"
	grep -Fx 'user=one-node' "$INSTALL_DIR/.service-account" >/dev/null || fail "install did not record its account"
)

# --- Native bootstrap token lives in the state directory.
(
	native_root="$TEST_TEMP_DIR/native-bootstrap"
	install -d -m 0700 "$native_root/opt" "$native_root/state" "$native_root/tmp"
	INSTALL_DIR="$native_root/opt"
	ENV_FILE="$INSTALL_DIR/.env"
	ENV_SOURCE="$native_root/tmp/one-node.env"
	BOOTSTRAP_ENV_SOURCE="$native_root/tmp/bootstrap.env"
	ONE_NODE_STATE_DIR="$native_root/state"
	BOOTSTRAP_ENV_FILE="$ONE_NODE_STATE_DIR/bootstrap.env"
	ONE_NODE_ID=7
	ONE_NODE_SERVER="grpcs://control.example:443"
	ONE_NODE_BOOTSTRAP_TOKEN=token
	write_environment_source
	if grep -F 'CONTROL_BOOTSTRAP_TOKEN' "$ENV_SOURCE" >/dev/null; then
		fail "native environment kept the token in the install directory"
	fi
	grep -Fx "CONTROL_BOOTSTRAP_ENV_FILE=\"$BOOTSTRAP_ENV_FILE\"" "$ENV_SOURCE" >/dev/null
	grep -Fx 'CONTROL_BOOTSTRAP_TOKEN="token"' "$BOOTSTRAP_ENV_SOURCE" >/dev/null
	install_bootstrap_environment
	cmp -s "$BOOTSTRAP_ENV_SOURCE" "$BOOTSTRAP_ENV_FILE" || fail "reconfiguration did not install the token"
	[ "$(file_mode "$BOOTSTRAP_ENV_FILE")" = 600 ]
)

# --- Upgrade migrates a root-era native install.
(
	reset_accounts
	upgrade_root="$TEST_TEMP_DIR/native-upgrade"
	install -d -m 0700 "$upgrade_root/opt" "$upgrade_root/state" "$upgrade_root/tmp"
	INSTALL_DIR="$upgrade_root/opt"
	ENV_FILE="$INSTALL_DIR/.env"
	UNIT_FILE="$upgrade_root/one-node.service"
	UPGRADE_TEMP_DIR="$upgrade_root/tmp"
	ONE_NODE_STATE_DIR="$upgrade_root/state"
	HOST_UPDATER_ENABLED=true
	printf '%s\n' \
		'NODE_NODE_ID="7"' \
		"CONTROL_BOOTSTRAP_ENV_FILE=\"$ENV_FILE\"" \
		'CONTROL_BOOTSTRAP_TOKEN="pending"' \
		'LOG_LEVEL="info"' >"$ENV_FILE"
	chmod 0600 "$ENV_FILE"
	printf '%s\n' '[Service]' 'User=root' >"$UNIT_FILE"
	SYSTEMCTL_LOG="$upgrade_root/systemctl.log"
	systemctl() { printf '%s\n' "$*" >>"$SYSTEMCTL_LOG"; }
	migrate_native_service_hardening || fail "native hardening migration failed"
	grep -Fx 'User=one-node' "$UNIT_FILE" >/dev/null || fail "upgrade kept the root unit"
	grep -Fx 'daemon-reload' "$SYSTEMCTL_LOG" >/dev/null || fail "upgrade did not reload systemd"
	grep -Fx 'CONTROL_BOOTSTRAP_TOKEN="pending"' "$ONE_NODE_STATE_DIR/bootstrap.env" >/dev/null ||
		fail "pending token was not moved to the state directory"
	if grep -F 'CONTROL_BOOTSTRAP_TOKEN' "$ENV_FILE" >/dev/null; then
		fail "upgrade left the token in the install directory"
	fi
	grep -Fx "CONTROL_BOOTSTRAP_ENV_FILE=\"$ONE_NODE_STATE_DIR/bootstrap.env\"" "$ENV_FILE" >/dev/null ||
		fail "upgrade did not repoint the bootstrap file"
	[ "$(grep -c '^CONTROL_BOOTSTRAP_ENV_FILE=' "$ENV_FILE")" = 1 ]
	grep -Fx 'NODE_NODE_ID="7"' "$ENV_FILE" >/dev/null || fail "upgrade dropped unrelated settings"
	[ "$(file_mode "$ENV_FILE")" = 600 ]
	[ -d "$ONE_NODE_STATE_DIR/firewall" ] && [ -d "$ONE_NODE_STATE_DIR/update" ]
	cp "$ENV_FILE" "$upgrade_root/env.migrated"
	migrate_native_service_hardening || fail "second migration failed"
	cmp -s "$ENV_FILE" "$upgrade_root/env.migrated" || fail "migration is not idempotent"
	[ -f "$ONE_NODE_STATE_DIR/bootstrap.env" ] || fail "second migration dropped the bootstrap file"
)

# --- #10 Docker keeps only network capabilities.
(
	TEMP_DIR="$TEST_TEMP_DIR/docker"
	install -d -m 0700 "$TEMP_DIR"
	COMPOSE_SOURCE="$TEMP_DIR/docker-compose.yml"
	ENV_FILE=/opt/one-node/.env
	INSTALL_DIR=/opt/one-node
	ONE_NODE_STATE_DIR=/var/lib/one-node
	ONE_NODE_DOCKER_IMAGE="ghcr.io/voiceofhu/one-node@sha256:$(printf '%064d' 3)"
	CONTAINER_NAME=one-node
	write_docker_source
	awk '
		/^    cap_drop:$/ { section = "drop"; next }
		/^    cap_add:$/ { section = "add"; next }
		/^    [a-z_]+:/ { section = "" }
		section != "" && /^      - / { print section ":" $2 }
	' "$COMPOSE_SOURCE" >"$TEMP_DIR/caps"
	printf '%s\n' drop:ALL add:NET_ADMIN add:NET_BIND_SERVICE add:NET_RAW >"$TEMP_DIR/caps.expected"
	cmp -s "$TEMP_DIR/caps" "$TEMP_DIR/caps.expected" || fail "compose capabilities are not exactly the network set"
	grep -F 'no-new-privileges:true' "$COMPOSE_SOURCE" >/dev/null
	grep -Fx '    read_only: true' "$COMPOSE_SOURCE" >/dev/null
	if grep -E '^    (privileged|user):' "$COMPOSE_SOURCE" >/dev/null; then
		fail "compose grants privileged mode or an unexpected user"
	fi
)

# The One Node image ships no shell beyond Alpine's busybox.
image_file="$ROOT_DIR/../../one-node/node/one/docker/Dockerfile"
if [ -f "$image_file" ] && grep -E 'apk add.*\bbash\b' "$image_file" >/dev/null; then
	fail "One Node image still installs bash"
fi

printf '%s\n' "hardening tests passed"
