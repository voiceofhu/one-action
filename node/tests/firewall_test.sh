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
grep -F 'iifname "lo" accept comment "one-node-loopback"' "$TEST_LOG" >/dev/null
grep -F 'one-node-unused-udp' "$TEST_LOG" >/dev/null
# A fresh table opens no managed port until the runtime sends its list.
grep -F 'add set inet one_node tcp_ports { type inet_service; flags interval; }' "$TEST_LOG" >/dev/null
grep -F 'elements = { 20000-60000 }' "$TEST_LOG" >/dev/null && exit 1
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
# Requests without restrictions still rebuild an empty restricted chain.
grep -F 'add chain inet one_node restricted { type filter hook input priority -15; policy accept; }' "$TEST_LOG" >/dev/null
grep -F 'flush chain inet one_node restricted' "$TEST_LOG" >/dev/null
grep -F 'one-node-restricted-drop' "$TEST_LOG" >/dev/null && exit 1

# Restricted ports accept only their sources, in the same nft transaction as the sets.
: >"$TEST_LOG"
cat >"$FIREWALL_REQUEST_FILE" <<'EOF'
request_id=22222222-2222-4222-8222-222222222222
tcp_ports=23837,24080,43555
udp_ports=43555
restricted=tcp:24080:;tcp:43555:198.51.100.7/32|203.0.113.0/24|2001:db8::/32;udp:43555:198.51.100.7/32
EOF
chmod 0600 "$FIREWALL_REQUEST_FILE"
ONE_NODE_FIREWALL_DIR="${ONE_NODE_STATE_DIR}/firewall" "$FIREWALL_FILE"
grep -F 'state=succeeded' "${ONE_NODE_STATE_DIR}/firewall/status" >/dev/null
[ "$(grep -c '^-f ' "$TEST_LOG")" = 1 ]
grep -F 'add element inet one_node tcp_ports { 23837,24080,43555 }' "$TEST_LOG" >/dev/null
grep -Fx 'add rule inet one_node restricted tcp dport 24080 drop comment "one-node-restricted-drop"' "$TEST_LOG" >/dev/null
grep -F 'restricted tcp dport 24080 ip' "$TEST_LOG" >/dev/null && exit 1
grep -Fx 'add rule inet one_node restricted tcp dport 43555 ip saddr { 198.51.100.7/32, 203.0.113.0/24 } accept comment "one-node-restricted-allow"' "$TEST_LOG" >/dev/null
grep -Fx 'add rule inet one_node restricted tcp dport 43555 ip6 saddr { 2001:db8::/32 } accept comment "one-node-restricted-allow"' "$TEST_LOG" >/dev/null
grep -Fx 'add rule inet one_node restricted tcp dport 43555 drop comment "one-node-restricted-drop"' "$TEST_LOG" >/dev/null
grep -Fx 'add rule inet one_node restricted udp dport 43555 ip saddr { 198.51.100.7/32 } accept comment "one-node-restricted-allow"' "$TEST_LOG" >/dev/null
grep -F 'restricted udp dport 43555 ip6' "$TEST_LOG" >/dev/null && exit 1
grep -Fx 'add rule inet one_node restricted ct state established,related accept comment "one-node-restricted-established"' "$TEST_LOG" >/dev/null
[ ! -e "$FIREWALL_REQUEST_FILE" ] && [ ! -e "${FIREWALL_REQUEST_FILE}.running" ]

# Anything but a validated IPv4/IPv6 CIDR on a listed port in 20000-60000 is
# rejected before nft runs, and the request is cleared with a failed status.
request_number=3
# shellcheck disable=SC2016
for restricted in \
	'tcp:24080:198.51.100.7' \
	'tcp:24080:198.51.100.7/32 } accept; flush ruleset' \
	'tcp:24080:$(id)/32' \
	'tcp:24080:198.51.100.256/32' \
	'tcp:24080:::ffff:198.51.100.7/128' \
	'tcp:24080:2001:DB8::/32' \
	'tcp:24080:fe80::1%eth0/128' \
	'tcp:24080:198.51.100.7/32||203.0.113.0/24' \
	'tcp:24080:;tcp:24080:' \
	'udp:24080:198.51.100.7/32' \
	'tcp:24081:198.51.100.7/32' \
	'tcp:22:198.51.100.7/32'
do
	: >"$TEST_LOG"
	printf '%s\n' \
		"request_id=33333333-3333-4333-8333-$(printf '%012d' "$request_number")" \
		'tcp_ports=22,24080' \
		'udp_ports=' \
		"restricted=${restricted}" >"$FIREWALL_REQUEST_FILE"
	chmod 0600 "$FIREWALL_REQUEST_FILE"
	if ONE_NODE_FIREWALL_DIR="${ONE_NODE_STATE_DIR}/firewall" "$FIREWALL_FILE" 2>/dev/null; then
		printf '%s\n' "restricted request was accepted: ${restricted}" >&2
		exit 1
	fi
	grep -Fx "request_id=33333333-3333-4333-8333-$(printf '%012d' "$request_number")" "${ONE_NODE_STATE_DIR}/firewall/status" >/dev/null
	grep -Fx 'state=failed' "${ONE_NODE_STATE_DIR}/firewall/status" >/dev/null
	grep -Fx 'message=restricted is invalid' "${ONE_NODE_STATE_DIR}/firewall/status" >/dev/null
	grep -F -- '-f ' "$TEST_LOG" >/dev/null && exit 1
	[ ! -e "$FIREWALL_REQUEST_FILE" ]
	request_number=$((request_number + 1))
done

# A fifth line, or a repeated restricted line, is never accepted.
printf '%s\n' \
	'request_id=44444444-4444-4444-8444-444444444444' \
	'tcp_ports=24080' \
	'udp_ports=' \
	'restricted=tcp:24080:' \
	'restricted=tcp:24080:' >"$FIREWALL_REQUEST_FILE"
chmod 0600 "$FIREWALL_REQUEST_FILE"
if ONE_NODE_FIREWALL_DIR="${ONE_NODE_STATE_DIR}/firewall" "$FIREWALL_FILE" 2>/dev/null; then exit 1; fi
grep -Fx 'request_id=44444444-4444-4444-8444-444444444444' "${ONE_NODE_STATE_DIR}/firewall/status" >/dev/null
grep -Fx 'message=request has an invalid field count' "${ONE_NODE_STATE_DIR}/firewall/status" >/dev/null
[ ! -e "$FIREWALL_REQUEST_FILE" ]

stage_host_firewall_transition
grep -F 'add element inet one_node tcp_ports { 20000-60000 }' "$TEST_LOG" >/dev/null
grep -F 'add element inet one_node udp_ports { 20000-60000 }' "$TEST_LOG" >/dev/null

remove_host_firewall
[ ! -f "$TABLE_STATE" ]

printf '%s\n' 'One Node dynamic firewall checks passed.'
