#!/bin/sh
# shellcheck disable=SC2034,SC2154
set -eu

ROOT_DIR=$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)
TEST_TEMP_DIR=$(mktemp -d)
trap 'rm -rf -- "$TEST_TEMP_DIR"' EXIT HUP INT TERM
TEST_BIN="${TEST_TEMP_DIR}/bin"
SYSCTL_STATE="${TEST_TEMP_DIR}/sysctl.state"
SYSCTL_COUNT="${TEST_TEMP_DIR}/sysctl.count"
install -d -m 0755 "$TEST_BIN"

cat >"${TEST_BIN}/modprobe" <<'EOF'
#!/bin/sh
[ "${1:-}" = tcp_bbr ]
EOF
chmod 0755 "${TEST_BIN}/modprobe"

cat >"${TEST_BIN}/sysctl" <<'EOF'
#!/bin/sh
set -eu
case "${1:-}" in
-n)
	key=$2
	if [ "$key" = net.ipv4.tcp_available_congestion_control ]; then
		printf '%s\n' 'reno cubic bbr'
		exit 0
	fi
	case " ${TUNING_SYSCTL_MISSING:-} " in *" ${key} "*) exit 255 ;; esac
	if [ -f "$TUNING_SYSCTL_STATE" ]; then
		sed -n "s|^${key}[[:space:]]*=[[:space:]]*||p" "$TUNING_SYSCTL_STATE" |
			awk '{$1=$1; print}'
	else
		printf '%s\n' 0
	fi
	;;
-p)
	cp "$2" "$TUNING_SYSCTL_STATE"
	count=0
	[ ! -f "$TUNING_SYSCTL_COUNT" ] || count=$(cat "$TUNING_SYSCTL_COUNT")
	printf '%s\n' $((count + 1)) >"$TUNING_SYSCTL_COUNT"
	;;
*) exit 1 ;;
esac
EOF
chmod 0755 "${TEST_BIN}/sysctl"

export TUNING_SYSCTL_STATE="$SYSCTL_STATE"
export TUNING_SYSCTL_COUNT="$SYSCTL_COUNT"
PATH="${TEST_BIN}:/usr/bin:/bin"
export PATH

# shellcheck disable=SC1090
. "$ROOT_DIR/scripts/install/common.sh"
. "$ROOT_DIR/scripts/install/tuning.sh"

assert_profile() {
	memory_kib=$1
	want_max=$2
	want_conntrack=$3
	calculate_network_tuning_profile "$memory_kib"
	[ "$tcp_max_mib" = "$want_max" ]
	[ "$tcp_rmem_value" = "4096 131072 $((want_max * 1048576))" ]
	[ "$tcp_wmem_value" = "4096 16384 $((want_max * 1048576))" ]
	[ "$conntrack_max" = "$want_conntrack" ]
}

assert_profile 262144 64 65536
assert_profile 524288 64 65536
assert_profile 1000000 64 124928
assert_profile 2097152 128 262144
assert_profile 4194304 128 524288
assert_profile 8388608 128 1048576
assert_profile 16777216 128 1048576

NETWORK_TUNING_FILE="${TEST_TEMP_DIR}/sysctl.d/90-one-node.conf"
BBR_MODULE_FILE="${TEST_TEMP_DIR}/modules-load.d/90-one-node-bbr.conf"
NETWORK_MEMINFO_FILE="${TEST_TEMP_DIR}/meminfo"
printf '%s\n' 'MemTotal:        1000000 kB' >"$NETWORK_MEMINFO_FILE"
bbr_is_persisted() { [ -f "$BBR_MODULE_FILE" ]; }

apply_network_tuning
grep -F 'net.core.rmem_max = 67108864' "$NETWORK_TUNING_FILE" >/dev/null
grep -F 'net.ipv4.tcp_rmem = 4096 131072 67108864' "$NETWORK_TUNING_FILE" >/dev/null
grep -F 'net.ipv4.tcp_wmem = 4096 16384 67108864' "$NETWORK_TUNING_FILE" >/dev/null
grep -F 'net.core.somaxconn = 4096' "$NETWORK_TUNING_FILE" >/dev/null
grep -F 'net.netfilter.nf_conntrack_max = 124928' "$NETWORK_TUNING_FILE" >/dev/null
grep -F 'net.ipv4.tcp_congestion_control = bbr' "$NETWORK_TUNING_FILE" >/dev/null
grep -F 'net.ipv4.tcp_notsent_lowat = 131072' "$NETWORK_TUNING_FILE" >/dev/null
grep -F 'net.ipv4.tcp_mtu_probing = 1' "$NETWORK_TUNING_FILE" >/dev/null
[ "$(cat "$SYSCTL_COUNT")" = 1 ]

apply_network_tuning
[ "$(cat "$SYSCTL_COUNT")" = 1 ]

# Higher administrator values are kept, and hosts without nf_conntrack get no
# conntrack key that would make sysctl -p fail.
printf '%s\n' 'net.core.somaxconn = 65535' >"$SYSCTL_STATE"
TUNING_SYSCTL_MISSING=net.netfilter.nf_conntrack_max apply_network_tuning
grep -F 'net.core.somaxconn = 65535' "$NETWORK_TUNING_FILE" >/dev/null
if grep -F 'nf_conntrack_max' "$NETWORK_TUNING_FILE" >/dev/null; then
	printf '%s\n' "conntrack tuning was written without the kernel key" >&2
	exit 1
fi
[ "$(cat "$SYSCTL_COUNT")" = 2 ]

printf '%s\n' 'One Node dynamic network tuning checks passed.'
