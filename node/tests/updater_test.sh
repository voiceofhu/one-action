#!/bin/sh
set -eu

ROOT_DIR=$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)
TEST_TEMP_DIR=$(mktemp -d "/tmp/one-node-updater-test.XXXXXX")
trap 'rm -rf -- "$TEST_TEMP_DIR"' EXIT HUP INT TERM

. "$ROOT_DIR/scripts/install/common.sh"
. "$ROOT_DIR/scripts/shared/manifest.sh"
. "$ROOT_DIR/scripts/install/files.sh"
. "$ROOT_DIR/scripts/install/updater.sh"

INSTALL_DIR="${TEST_TEMP_DIR}/opt/one-node"
ONE_NODE_STATE_DIR="${TEST_TEMP_DIR}/var/lib/one-node"
UPDATER_FILE="${INSTALL_DIR}/updater.sh"
UPDATER_SERVICE_FILE="${TEST_TEMP_DIR}/one-node-updater.service"
UPDATER_PATH_FILE="${TEST_TEMP_DIR}/one-node-updater.path"
HOST_UPDATER_ENABLED=true
install -d -m 0755 "$INSTALL_DIR"
	
fake_bin="${TEST_TEMP_DIR}/bin"
install -d -m 0755 "$fake_bin"
cat >"${fake_bin}/stat" <<'EOF'
#!/bin/sh
[ "$1" = -c ] && [ "$2" = %a ] || exit 1
exec /usr/bin/stat -f %Lp "$3"
EOF
chmod 0755 "${fake_bin}/stat"

systemctl() { :; }
install_host_updater

fake_installer="${TEST_TEMP_DIR}/install.sh"
cat >"$fake_installer" <<'EOF'
#!/bin/sh
[ "$1" = --upgrade ] && [ "$2" = 26.828.1600 ]
EOF
chmod 0700 "$fake_installer"

update_dir="${ONE_NODE_STATE_DIR}/update"
cat >"${update_dir}/request" <<'EOF'
command_id=command-1
version=26.828.1600
state=pending
requested_at=2026-08-28T08:00:00Z
updated_at=2026-08-28T08:00:00Z
message=
EOF
chmod 0600 "${update_dir}/request"
PATH="${fake_bin}:$PATH" ONE_NODE_UPDATE_DIR="$update_dir" ONE_NODE_INSTALLER="$fake_installer" "$UPDATER_FILE"

[ ! -e "${update_dir}/request" ] || {
	printf '%s\n' 'updater preserved the activated request' >&2
	exit 1
}
[ ! -e "${update_dir}/request.running" ] || {
	printf '%s\n' 'updater preserved the running request' >&2
	exit 1
}
grep -Fx 'command_id=command-1' "${update_dir}/status" >/dev/null
grep -Fx 'version=26.828.1600' "${update_dir}/status" >/dev/null
grep -Fx 'state=succeeded' "${update_dir}/status" >/dev/null

cat >"${update_dir}/request" <<'EOF'
command_id=command-failed
version=26.828.1601
state=pending
requested_at=2026-08-28T08:00:00Z
updated_at=2026-08-28T08:00:00Z
message=
EOF
chmod 0600 "${update_dir}/request"
if PATH="${fake_bin}:$PATH" ONE_NODE_UPDATE_DIR="$update_dir" ONE_NODE_INSTALLER="$fake_installer" "$UPDATER_FILE" >/dev/null 2>&1; then
	printf '%s\n' 'updater reported a failed installer as successful' >&2
	exit 1
fi
[ ! -e "${update_dir}/request" ] && [ ! -e "${update_dir}/request.running" ] || {
	printf '%s\n' 'updater preserved a failed request' >&2
	exit 1
}
grep -Fx 'state=failed' "${update_dir}/status" >/dev/null

cat >"${update_dir}/request" <<'EOF'
command_id=command-2
version=01.2.3
state=pending
requested_at=2026-08-28T08:00:00Z
updated_at=2026-08-28T08:00:00Z
message=
EOF
chmod 0600 "${update_dir}/request"
if PATH="${fake_bin}:$PATH" ONE_NODE_UPDATE_DIR="$update_dir" ONE_NODE_INSTALLER="$fake_installer" "$UPDATER_FILE" >/dev/null 2>&1; then
	printf '%s\n' 'updater accepted a non-canonical version' >&2
	exit 1
fi

printf '%s\n' 'One Node host updater boundary tests passed.'

legacy_dir="${TEST_TEMP_DIR}/legacy"
INSTALL_DIR="${legacy_dir}/opt/one-node"
ENV_FILE="${INSTALL_DIR}/.env"
INSTALL_RECORD="${INSTALL_DIR}/.installation"
ONE_NODE_STATE_DIR="${legacy_dir}/var/lib/one-node"
UPDATER_FILE="${INSTALL_DIR}/updater.sh"
UPDATER_SERVICE_FILE="${legacy_dir}/one-node-updater.service"
UPDATER_PATH_FILE="${legacy_dir}/one-node-updater.path"
MANIFEST_UPDATER_PATH=$UPDATER_FILE
MANIFEST_UPDATER_SERVICE_PATH=$UPDATER_SERVICE_FILE
MANIFEST_UPDATER_PATH_UNIT_PATH=$UPDATER_PATH_FILE
MANIFEST_OWNED_PATHS="${INSTALL_DIR}
${ENV_FILE}
${INSTALL_RECORD}"
MANIFEST_OWNED_COUNT=3
install -d -m 0755 "$INSTALL_DIR"
install -d -m 0700 "$ONE_NODE_STATE_DIR"
cat >"$ENV_FILE" <<'EOF'
NODE_NODE_ID="42"
CONTROL_ADDR="grpcs://control.example:443"
CONTROL_BOOTSTRAP_TOKEN="secret-preserved"
NODE_UPGRADE_REQUEST_FILE="/legacy/request"
LOG_LEVEL="info"
EOF
chmod 0600 "$ENV_FILE"
manifest_write() { :; }
enable_host_updater_for_upgrade

grep -Fx 'CONTROL_BOOTSTRAP_TOKEN="secret-preserved"' "$ENV_FILE" >/dev/null
grep -Fx "NODE_UPGRADE_REQUEST_FILE=\"${ONE_NODE_STATE_DIR}/update/request\"" "$ENV_FILE" >/dev/null
[ "$(grep -c '^NODE_UPGRADE_REQUEST_FILE=' "$ENV_FILE")" -eq 1 ] || {
	printf '%s\n' 'legacy upgrade duplicated the updater environment key' >&2
	exit 1
}
for owned_path in "$UPDATER_FILE" "$UPDATER_SERVICE_FILE" "$UPDATER_PATH_FILE"; do
	manifest_has_owned_path "$owned_path" || {
		printf '%s\n' "legacy upgrade did not claim ${owned_path}" >&2
		exit 1
	}
	[ -f "$owned_path" ] || {
		printf '%s\n' "legacy upgrade did not install ${owned_path}" >&2
		exit 1
	}
done

printf '%s\n' 'One Node legacy upgrade updater bootstrap tests passed.'
