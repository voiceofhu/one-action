#!/bin/sh
# shellcheck disable=SC2034
set -eu

ROOT_DIR=$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)
TEST_TEMP_DIR=$(mktemp -d)
trap 'rm -rf -- "$TEST_TEMP_DIR"' EXIT HUP INT TERM
TEST_BIN="${TEST_TEMP_DIR}/bin"
install -d -m 0755 "$TEST_BIN"

fail() {
	printf '%s\n' "$*" >&2
	exit 1
}

cat >"${TEST_BIN}/systemctl" <<'EOF'
#!/bin/sh
exit 0
EOF
cat >"${TEST_BIN}/stat" <<'EOF'
#!/bin/sh
if [ "${1:-}" = -c ] && [ "${2:-}" = %a ]; then
	/usr/bin/stat -c %a "$3" 2>/dev/null || /usr/bin/stat -f %Lp "$3"
	exit
fi
exit 1
EOF
cat >"${TEST_BIN}/nft" <<'EOF'
#!/bin/sh
case "$*" in
"-nn list table inet one_node")
	[ -f "$FAKE_STATE/table" ] || exit 1
	printf '%s\n' 'set tcp_ports' 'set udp_ports' 'chain input' \
		'comment "one-node-loopback"' 'comment "one-node-established"' \
		'comment "one-node-active-tcp"' 'comment "one-node-active-udp"' \
		'comment "one-node-unused-tcp"' 'comment "one-node-unused-udp"'
	;;
"-f "*) touch "$FAKE_STATE/table" ;;
"delete table inet one_node") rm -f -- "$FAKE_STATE/table" ;;
esac
EOF
# ufw keeps one rule per line ("<rule> <comment>"); like ufw, an existing
# rule is skipped instead of duplicated.
cat >"${TEST_BIN}/ufw" <<'EOF'
#!/bin/sh
rules="$FAKE_STATE/ufw.rules"
touch "$rules"
[ "${1:-}" != --force ] || shift
case "${1:-}" in
status)
	if [ -f "$FAKE_STATE/ufw.active" ]; then echo 'Status: active'; else echo 'Status: inactive'; fi
	;;
allow)
	if grep -q "^$2 " "$rules"; then echo 'Skipping adding existing rule'; exit 0; fi
	[ "${3:-}" = comment ] && [ "${4:-}" = one-node ] || exit 1
	echo "$2 one-node" >>"$rules"
	echo 'Rule added'
	;;
delete)
	[ "${2:-}" = allow ] || exit 1
	grep -q "^$3 " "$rules" || exit 1
	grep -v "^$3 " "$rules" >"$rules.next" || true
	mv "$rules.next" "$rules"
	;;
*) exit 1 ;;
esac
EOF
cat >"${TEST_BIN}/firewall-cmd" <<'EOF'
#!/bin/sh
store="$FAKE_STATE/firewalld.runtime"
zone=""
for arg in "$@"; do
	case "$arg" in
	--state) [ -f "$FAKE_STATE/firewalld.running" ]; exit ;;
	--get-default-zone) echo public; exit 0 ;;
	--permanent) store="$FAKE_STATE/firewalld.permanent" ;;
	--zone=*) zone=${arg#--zone=} ;;
	esac
done
touch "$store"
for arg in "$@"; do
	case "$arg" in
	--query-port=*) grep -qx "$zone ${arg#*=}" "$store"; exit ;;
	--add-port=*) echo "$zone ${arg#*=}" >>"$store" ;;
	--remove-port=*)
		grep -vx "$zone ${arg#*=}" "$store" >"$store.next" || true
		mv "$store.next" "$store"
		;;
	esac
done
EOF
chmod 0755 "$TEST_BIN"/*

FAKE_STATE="${TEST_TEMP_DIR}/fake"
install -d -m 0755 "$FAKE_STATE"
export FAKE_STATE
PATH="${TEST_BIN}:/usr/bin:/bin"
export PATH

# shellcheck disable=SC1090
. "$ROOT_DIR/scripts/install/common.sh"
. "$ROOT_DIR/scripts/shared/manifest.sh"
. "$ROOT_DIR/scripts/install/files.sh"
. "$ROOT_DIR/scripts/install/firewall.sh"

INSTALL_DIR="${TEST_TEMP_DIR}/opt/one-node"
ONE_NODE_STATE_DIR="${TEST_TEMP_DIR}/var/lib/one-node"
ENV_FILE="${INSTALL_DIR}/.env"
FIREWALL_FILE="${INSTALL_DIR}/firewall.sh"
FIREWALL_SERVICE_FILE="${TEST_TEMP_DIR}/one-node-firewall.service"
FIREWALL_PATH_FILE="${TEST_TEMP_DIR}/one-node-firewall.path"
FIREWALL_REQUEST_FILE="${ONE_NODE_STATE_DIR}/firewall/request"
HOST_RULES="${INSTALL_DIR}/.firewall-host-rules"
install -d -m 0755 "$INSTALL_DIR"
install -d -m 0700 "$ONE_NODE_STATE_DIR"

install_host_firewall >/dev/null
grep -Fx "Environment=\"ONE_NODE_FIREWALL_HOST_RULES=${HOST_RULES}\"" "$FIREWALL_SERVICE_FILE" >/dev/null ||
	fail "firewall service does not pin the host rule record"

request_ports() {
	printf '%s\n' \
		"request_id=11111111-1111-4111-8111-11111111111$1" \
		"tcp_ports=$2" \
		"udp_ports=$3" >"$FIREWALL_REQUEST_FILE"
	[ -z "${4:-}" ] || printf '%s\n' "restricted=$4" >>"$FIREWALL_REQUEST_FILE"
	chmod 0600 "$FIREWALL_REQUEST_FILE"
	ONE_NODE_FIREWALL_DIR="${ONE_NODE_STATE_DIR}/firewall" \
		ONE_NODE_FIREWALL_HOST_RULES="$HOST_RULES" "$FIREWALL_FILE" 2>>"${TEST_TEMP_DIR}/firewall.log"
	grep -F 'state=succeeded' "${ONE_NODE_STATE_DIR}/firewall/status" >/dev/null ||
		fail "firewall request $1 did not succeed"
}

# Inactive ufw and stopped firewalld are left alone.
request_ports 1 443 ""
[ ! -s "$FAKE_STATE/ufw.rules" ] || fail "inactive ufw received rules"
[ ! -e "$HOST_RULES" ] || fail "host rules were recorded without an active host firewall"

# Active ufw: open runtime ports, but never claim an administrator's rule.
: >"$FAKE_STATE/ufw.active"
printf '%s\n' '22/tcp admin' '443/tcp admin' >"$FAKE_STATE/ufw.rules"
request_ports 2 443,23837 41825
grep -Fx '23837/tcp one-node' "$FAKE_STATE/ufw.rules" >/dev/null || fail "ufw tcp port was not allowed"
grep -Fx '41825/udp one-node' "$FAKE_STATE/ufw.rules" >/dev/null || fail "ufw udp port was not allowed"
grep -Fx 'ufw 443/tcp' "$HOST_RULES" >/dev/null && fail "pre-existing ufw rule was claimed"
[ "$(file_mode "$HOST_RULES")" = 600 ] || fail "host rule record is not private"

# Closed ports lose only One Node's own rules.
request_ports 3 443,26172 ""
grep -F '23837/tcp' "$FAKE_STATE/ufw.rules" >/dev/null && fail "stale ufw tcp rule remained"
grep -F '41825/udp' "$FAKE_STATE/ufw.rules" >/dev/null && fail "stale ufw udp rule remained"
grep -Fx '26172/tcp one-node' "$FAKE_STATE/ufw.rules" >/dev/null || fail "new ufw port was not allowed"
grep -Fx '443/tcp admin' "$FAKE_STATE/ufw.rules" >/dev/null || fail "administrator ufw rule was removed"
grep -Fx '22/tcp admin' "$FAKE_STATE/ufw.rules" >/dev/null || fail "administrator ssh rule was removed"

# firewalld: runtime + permanent in the default zone, pre-opened ports skipped.
: >"$FAKE_STATE/firewalld.running"
printf '%s\n' 'public 8443/tcp' >"$FAKE_STATE/firewalld.runtime"
printf '%s\n' 'public 8443/tcp' >"$FAKE_STATE/firewalld.permanent"
request_ports 4 8443,26172 ""
grep -Fx 'public 26172/tcp' "$FAKE_STATE/firewalld.runtime" >/dev/null || fail "firewalld runtime port missing"
grep -Fx 'public 26172/tcp' "$FAKE_STATE/firewalld.permanent" >/dev/null || fail "firewalld permanent port missing"
grep -Fx 'firewalld public 26172/tcp' "$HOST_RULES" >/dev/null || fail "firewalld port was not recorded"
grep -F 'firewalld public 8443' "$HOST_RULES" >/dev/null && fail "pre-opened firewalld port was claimed"

# Malformed records are dropped, never executed or deleted.
printf '%s\n' 'ufw 22/tcp; rm -rf /' 'firewalld -x 1/tcp' 'ufw 0/tcp' >>"$HOST_RULES"
request_ports 5 8443,26172 ""
grep -Fx '22/tcp admin' "$FAKE_STATE/ufw.rules" >/dev/null || fail "malformed record removed an admin rule"
grep -F 'rm -rf' "$HOST_RULES" >/dev/null && fail "malformed record was kept"

# Restricted ports are still opened in ufw/firewalld: their base chains run
# after inet one_node, whose restricted chain already dropped other sources.
request_ports 6 8443,26172 26172 'tcp:26172:198.51.100.7/32;udp:26172:2001:db8::/32'
grep -Fx '26172/tcp one-node' "$FAKE_STATE/ufw.rules" >/dev/null || fail "restricted ufw tcp port was not allowed"
grep -Fx '26172/udp one-node' "$FAKE_STATE/ufw.rules" >/dev/null || fail "restricted ufw udp port was not allowed"

# A rejected restricted request leaves the host firewalls untouched.
cp "$FAKE_STATE/ufw.rules" "${TEST_TEMP_DIR}/ufw.before"
printf '%s\n' \
	'request_id=11111111-1111-4111-8111-111111111117' \
	'tcp_ports=8443' \
	'udp_ports=' \
	'restricted=tcp:8443:198.51.100.7/32' >"$FIREWALL_REQUEST_FILE"
chmod 0600 "$FIREWALL_REQUEST_FILE"
if ONE_NODE_FIREWALL_DIR="${ONE_NODE_STATE_DIR}/firewall" \
	ONE_NODE_FIREWALL_HOST_RULES="$HOST_RULES" "$FIREWALL_FILE" 2>>"${TEST_TEMP_DIR}/firewall.log"; then
	fail "restricted port outside 20000-60000 was accepted"
fi
cmp -s "$FAKE_STATE/ufw.rules" "${TEST_TEMP_DIR}/ufw.before" || fail "rejected request changed ufw rules"

# Removing the firewall removes only the recorded rules.
remove_host_firewall
grep -F 'one-node' "$FAKE_STATE/ufw.rules" >/dev/null && fail "One Node ufw rules remained after removal"
grep -Fx '443/tcp admin' "$FAKE_STATE/ufw.rules" >/dev/null || fail "removal deleted an administrator ufw rule"
grep -F '26172' "$FAKE_STATE/firewalld.runtime" "$FAKE_STATE/firewalld.permanent" >/dev/null &&
	fail "One Node firewalld ports remained after removal"
grep -Fx 'public 8443/tcp' "$FAKE_STATE/firewalld.permanent" >/dev/null || fail "removal deleted an administrator firewalld port"
[ ! -e "$HOST_RULES" ] || fail "host rule record remained after removal"

printf '%s\n' 'One Node ufw/firewalld host rule checks passed.'
