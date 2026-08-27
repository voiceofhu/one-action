#!/bin/sh
set -eu

ROOT_DIR=$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)
TEST_TEMP_DIR=$(mktemp -d)
trap 'rm -rf -- "$TEST_TEMP_DIR"' EXIT HUP INT TERM

make_fake() {
	name=$1
	shift
	path="${TEST_TEMP_DIR}/bin/${name}"
	install -d -m 0755 "${TEST_TEMP_DIR}/bin"
	{
		printf '%s\n' '#!/bin/sh' 'set -eu'
		printf '%s\n' "$@"
	} >"$path"
	chmod 0755 "$path"
}

make_fake id '[ "${1:-}" = -u ] && printf "%s\n" 0'
make_fake ufw 'exit 1'
make_fake firewall-cmd 'exit 1'
make_fake nft 'exit 1'
make_fake systemctl 'exit 1'
make_fake service 'exit 1'
make_fake iptables '
printf "%s\n" "$*" >>"$FIREWALL_TEST_LOG"
case "${1:-}" in
-C) [ "${IPTABLES_RULES_EXIST:-false}" = true ] ;;
-L) printf "%s\n" "Chain INPUT" "num target" "5 REJECT" ;;
*) exit 0 ;;
esac
'
make_fake netfilter-persistent 'printf "%s\n" "netfilter-persistent $*" >>"$FIREWALL_TEST_LOG"'

FIREWALL_TEST_LOG="${TEST_TEMP_DIR}/iptables.log"
export FIREWALL_TEST_LOG
PATH="${TEST_TEMP_DIR}/bin:/usr/bin:/bin" sh "$ROOT_DIR/open-ports.sh"
grep -F -- '-I INPUT 5 -p tcp --dport 20000:60000 -m comment --comment One Node TCP -j ACCEPT' "$FIREWALL_TEST_LOG" >/dev/null
grep -F -- '-I INPUT 5 -p udp --dport 20000:60000 -m comment --comment One Node UDP -j ACCEPT' "$FIREWALL_TEST_LOG" >/dev/null
grep -F 'netfilter-persistent save' "$FIREWALL_TEST_LOG" >/dev/null

: >"$FIREWALL_TEST_LOG"
IPTABLES_RULES_EXIST=true
export IPTABLES_RULES_EXIST
PATH="${TEST_TEMP_DIR}/bin:/usr/bin:/bin" sh "$ROOT_DIR/open-ports.sh"
if grep -F -- '-I INPUT' "$FIREWALL_TEST_LOG" >/dev/null; then
	printf '%s\n' 'firewall script duplicated existing iptables rules' >&2
	exit 1
fi

unset IPTABLES_RULES_EXIST
make_fake ufw '
printf "%s\n" "ufw $*" >>"$FIREWALL_TEST_LOG"
case "${1:-}" in
status) printf "%s\n" "Status: active" ;;
*) exit 0 ;;
esac
'
: >"$FIREWALL_TEST_LOG"
PATH="${TEST_TEMP_DIR}/bin:/usr/bin:/bin" sh "$ROOT_DIR/open-ports.sh"
grep -F 'ufw allow 20000:60000/tcp comment One Node TCP' "$FIREWALL_TEST_LOG" >/dev/null
grep -F 'ufw allow 20000:60000/udp comment One Node UDP' "$FIREWALL_TEST_LOG" >/dev/null
grep -F 'ufw reload' "$FIREWALL_TEST_LOG" >/dev/null

make_fake ufw 'exit 1'
make_fake firewall-cmd '
printf "%s\n" "firewall-cmd $*" >>"$FIREWALL_TEST_LOG"
case "$*" in
--state) printf "%s\n" running ;;
--get-active-zones) printf "%s\n" public "  interfaces: eth0" ;;
*--query-port=*) exit 1 ;;
*) exit 0 ;;
esac
'
: >"$FIREWALL_TEST_LOG"
PATH="${TEST_TEMP_DIR}/bin:/usr/bin:/bin" sh "$ROOT_DIR/open-ports.sh"
grep -F 'firewall-cmd --permanent --zone=public --add-port=20000-60000/tcp' "$FIREWALL_TEST_LOG" >/dev/null
grep -F 'firewall-cmd --permanent --zone=public --add-port=20000-60000/udp' "$FIREWALL_TEST_LOG" >/dev/null
grep -F 'firewall-cmd --reload' "$FIREWALL_TEST_LOG" >/dev/null

make_fake firewall-cmd 'exit 1'
make_fake systemctl '[ "${1:-}" = is-active ] && exit 0; exit 1'
make_fake nft '
printf "%s\n" "nft $*" >>"$FIREWALL_TEST_LOG"
case "$*" in
"-nn list ruleset")
	printf "%s\n" "table inet filter {" " chain input {" "  type filter hook input priority filter; policy drop;" " }" "}"
	;;
"list chain"*) exit 0 ;;
*) exit 0 ;;
esac
'
: >"$FIREWALL_TEST_LOG"
PATH="${TEST_TEMP_DIR}/bin:/usr/bin:/bin" sh "$ROOT_DIR/open-ports.sh"
grep -F 'nft insert rule inet filter input tcp dport 20000-60000 counter accept comment one-node-managed-tcp' "$FIREWALL_TEST_LOG" >/dev/null
grep -F 'nft insert rule inet filter input udp dport 20000-60000 counter accept comment one-node-managed-udp' "$FIREWALL_TEST_LOG" >/dev/null

printf '%s\n' 'One Node firewall script checks passed.'
