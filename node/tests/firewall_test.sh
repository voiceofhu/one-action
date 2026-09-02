#!/bin/sh
# shellcheck disable=SC2034
set -eu

ROOT_DIR=$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)
TEST_TEMP_DIR=$(mktemp -d)
trap 'rm -rf -- "$TEST_TEMP_DIR"' EXIT HUP INT TERM
TEST_BIN="${TEST_TEMP_DIR}/bin"
TEST_LOG="${TEST_TEMP_DIR}/nft.log"
TABLE_STATE="${TEST_TEMP_DIR}/table"
install -d -m 0755 "$TEST_BIN"

cat >"${TEST_BIN}/systemctl" <<'EOF'
#!/bin/sh
exit 0
EOF
chmod 0755 "${TEST_BIN}/systemctl"

cat >"${TEST_BIN}/stat" <<'EOF'
#!/bin/sh
[ "${1:-}" = -c ] && [ "${2:-}" = %a ] || exit 1
/usr/bin/stat -f %Lp "$3"
EOF
chmod 0755 "${TEST_BIN}/stat"

cat >"${TEST_BIN}/nft" <<'EOF'
#!/bin/sh
set -eu
printf '%s\n' "$*" >>"$FIREWALL_TEST_LOG"
case "$*" in
"-nn list table inet one_node")
	[ -f "$FIREWALL_TABLE_STATE" ] || exit 1
	cat <<'TABLE'
table inet one_node {
 set tcp_ports { type inet_service; }
 set udp_ports { type inet_service; }
 chain input {
  comment "one-node-established"
  comment "one-node-active-tcp"
  comment "one-node-active-udp"
  comment "one-node-unused-tcp"
  comment "one-node-unused-udp"
 }
}
TABLE
	;;
"-f "*)
	rules=$2
	cat "$rules" >>"$FIREWALL_TEST_LOG"
	touch "$FIREWALL_TABLE_STATE"
	;;
"delete table inet one_node")
	rm -f -- "$FIREWALL_TABLE_STATE"
	;;
esac
EOF
chmod 0755 "${TEST_BIN}/nft"

export FIREWALL_TEST_LOG="$TEST_LOG"
export FIREWALL_TABLE_STATE="$TABLE_STATE"
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
install -d -m 0755 "$INSTALL_DIR"
install -d -m 0700 "$ONE_NODE_STATE_DIR"
: >"$ENV_FILE"
chmod 0600 "$ENV_FILE"

install_host_firewall
[ -x "$FIREWALL_FILE" ]
[ -f "$TABLE_STATE" ]
grep -F 'one-node-unused-tcp' "$TEST_LOG" >/dev/null
grep -F 'one-node-unused-udp' "$TEST_LOG" >/dev/null
grep -F 'elements = { 20000-60000 }' "$TEST_LOG" >/dev/null
grep -F "PathExists=${FIREWALL_REQUEST_FILE}" "$FIREWALL_PATH_FILE" >/dev/null

cat >"$FIREWALL_REQUEST_FILE" <<'EOF'
request_id=11111111-1111-4111-8111-111111111111
tcp_ports=23837,26172,43555
udp_ports=41825,43555
EOF
chmod 0600 "$FIREWALL_REQUEST_FILE"
ONE_NODE_FIREWALL_DIR="${ONE_NODE_STATE_DIR}/firewall" "$FIREWALL_FILE"
grep -F 'flush set inet one_node tcp_ports' "$TEST_LOG" >/dev/null
grep -F 'add element inet one_node tcp_ports { 23837,26172,43555 }' "$TEST_LOG" >/dev/null
grep -F 'add element inet one_node udp_ports { 41825,43555 }' "$TEST_LOG" >/dev/null
grep -F 'state=succeeded' "${ONE_NODE_STATE_DIR}/firewall/status" >/dev/null

stage_host_firewall_transition
grep -F 'add element inet one_node tcp_ports { 20000-60000 }' "$TEST_LOG" >/dev/null
grep -F 'add element inet one_node udp_ports { 20000-60000 }' "$TEST_LOG" >/dev/null

remove_host_firewall
[ ! -f "$TABLE_STATE" ]

printf '%s\n' 'One Node dynamic firewall checks passed.'
