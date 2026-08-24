#!/bin/sh
set -eu

ROOT_DIR=$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)
TEST_TEMP_DIR=$(mktemp -d)
trap 'rm -rf -- "$TEST_TEMP_DIR"' EXIT HUP INT TERM
INSTALL_DIR="$TEST_TEMP_DIR/opt/one-node"
FAKE_BIN="$TEST_TEMP_DIR/bin"
install -d -m 0755 "$INSTALL_DIR" "$FAKE_BIN"

cat >"$FAKE_BIN/id" <<'SCRIPT'
#!/bin/sh
[ "${1:-}" = -u ] && printf '%s\n' 0
SCRIPT
cat >"$FAKE_BIN/ps" <<'SCRIPT'
#!/bin/sh
printf '%s\n' '01:02:03'
SCRIPT
cat >"$FAKE_BIN/systemctl" <<'SCRIPT'
#!/bin/sh
case "$1" in
is-active) printf '%s\n' active ;;
show) printf '%s\n' 4321 ;;
restart) : ;;
*) exit 1 ;;
esac
SCRIPT
cat >"$FAKE_BIN/docker" <<'SCRIPT'
#!/bin/sh
case "$1" in
inspect)
	case "$3" in
	'{{.State.Status}}') printf '%s\n' running ;;
	'{{.State.Pid}}') printf '%s\n' 9876 ;;
	'{{.State.Running}}') printf '%s\n' true ;;
	*) exit 1 ;;
	esac
	;;
stats) printf '%s\n' '48.0MiB / 1GiB' ;;
compose)
	[ "$2" = version ] || exit 1
	;;
*) exit 1 ;;
esac
SCRIPT
chmod 0755 "$FAKE_BIN"/*

write_fixture() {
	mode=$1
	cat >"$INSTALL_DIR/.installation" <<EOF
mode=$mode
current_version=26.824.1520
previous_version=26.824.1510
EOF
	chmod 0600 "$INSTALL_DIR/.installation"
	printf '%s\n' 'NODE_NODE_ID="42"' >"$INSTALL_DIR/.env"
	chmod 0600 "$INSTALL_DIR/.env"
}

write_fixture native
native_status=$(ONE_NODE_INSTALL_DIR="$INSTALL_DIR" PATH="$FAKE_BIN:$PATH" "$ROOT_DIR/install.sh" --status)
for expected in \
	'mode:             native' \
	'version:          26.824.1520' \
	'previous version: 26.824.1510' \
	'node id:          42' \
	'state:            active' \
	'pid:              4321' \
	'memory:' \
	'uptime:           01:02:03'; do
	printf '%s\n' "$native_status" | grep -F "$expected" >/dev/null
done

write_fixture docker
docker_status=$(ONE_NODE_INSTALL_DIR="$INSTALL_DIR" PATH="$FAKE_BIN:$PATH" "$ROOT_DIR/install.sh" --status)
for expected in \
	'mode:             docker' \
	'state:            running' \
	'pid:              9876' \
	'memory:           48.0MiB / 1GiB'; do
	printf '%s\n' "$docker_status" | grep -F "$expected" >/dev/null
done

help_output=$(ONE_NODE_INSTALL_DIR="$INSTALL_DIR" PATH="$FAKE_BIN:$PATH" "$ROOT_DIR/install.sh")
printf '%s\n' "$help_output" | grep -F 'Manage the installed One Node runtime.' >/dev/null

printf '%s\n' 'One Node retained installer management status tests passed.'
