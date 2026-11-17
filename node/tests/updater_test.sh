#!/bin/sh
set -eu

ROOT_DIR=$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)
TEST_TEMP_DIR=$(mktemp -d "/tmp/one-node-updater-test.XXXXXX")
trap 'rm -rf -- "$TEST_TEMP_DIR"' EXIT HUP INT TERM

. "$ROOT_DIR/scripts/install/common.sh"
. "$ROOT_DIR/scripts/shared/manifest.sh"
. "$ROOT_DIR/scripts/install/files.sh"
. "$ROOT_DIR/scripts/install/updater.sh"
. "$ROOT_DIR/scripts/install/firewall.sh"

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
# GNU `chown -h[R] --reference=DIR PATH` on BSD hosts.
cat >"${fake_bin}/chown" <<'EOF'
#!/bin/sh
reference=${2#--reference=}
[ "$reference" != "$2" ] || exec /usr/sbin/chown "$@"
exec /usr/sbin/chown "$1" "$(/usr/bin/stat -f %u:%g "$reference")" "$3"
EOF
chmod 0755 "${fake_bin}/chown"
chown() { "${fake_bin}/chown" "$@"; }

systemctl() { :; }
install_host_updater

fake_installer="${TEST_TEMP_DIR}/install.sh"
cat >"$fake_installer" <<'EOF'
#!/bin/sh
if [ "$1" = --upgrade ] && [ "$2" = 26.828.1600 ]; then
	printf '%s\n' '[one-node] upgrade fixture completed'
	exit 0
fi
if [ "$1" = --upgrade ] && [ "$2" = 26.828.1700 ]; then
	# systemd stops the whole unit on timeout or shutdown.
	kill -TERM "$PPID"
	exit 143
fi
printf '%s\n' '[one-node] error: nftables is required for One Node firewall management' >&2
exit 1
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
grep -Fx 'message=nftables is required for One Node firewall management' "${update_dir}/status" >/dev/null
grep -Fx '[one-node] error: nftables is required for One Node firewall management' \
	"${update_dir}/last-upgrade.log" >/dev/null

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

cat >"${update_dir}/request" <<'EOF'
command_id=command-3
version=26.828.1700
state=pending
requested_at=2026-08-28T08:00:00Z
updated_at=2026-08-28T08:00:00Z
message=
EOF
chmod 0600 "${update_dir}/request"
if PATH="${fake_bin}:$PATH" ONE_NODE_UPDATE_DIR="$update_dir" ONE_NODE_INSTALLER="$fake_installer" "$UPDATER_FILE" >/dev/null 2>&1; then
	printf '%s\n' 'updater reported an interrupted upgrade as successful' >&2
	exit 1
fi
grep -Fx 'command_id=command-3' "${update_dir}/status" >/dev/null
grep -Fx 'state=failed' "${update_dir}/status" >/dev/null
grep -Fx 'message=upgrade was interrupted' "${update_dir}/status" >/dev/null
[ ! -e "${update_dir}/request.running" ] || {
	printf '%s\n' 'updater left an interrupted request running' >&2
	exit 1
}
grep -Fx 'TimeoutStartSec=20min' "$UPDATER_SERVICE_FILE" >/dev/null

printf '%s\n' 'One Node host updater boundary tests passed.'
