#!/bin/sh

configure_host_firewall() {
	FIREWALL_FILE=${FIREWALL_FILE:-${INSTALL_DIR}/firewall.sh}
	FIREWALL_SERVICE_FILE=${FIREWALL_SERVICE_FILE:-/etc/systemd/system/one-node-firewall.service}
	FIREWALL_PATH_FILE=${FIREWALL_PATH_FILE:-/etc/systemd/system/one-node-firewall.path}
	FIREWALL_REQUEST_FILE=${FIREWALL_REQUEST_FILE:-${ONE_NODE_STATE_DIR}/firewall/request}
}

record_host_firewall_manifest_paths() {
	for host_firewall_path in \
		"$MANIFEST_FIREWALL_PATH" \
		"$MANIFEST_FIREWALL_SERVICE_PATH" \
		"$MANIFEST_FIREWALL_PATH_UNIT_PATH"
	do
		if ! manifest_has_owned_path "$host_firewall_path"; then
			manifest_append_owned_path "$host_firewall_path" ||
				die "unable to record host firewall path"
			MANIFEST_OWNED_COUNT=$((MANIFEST_OWNED_COUNT + 1))
		fi
	done
}

write_host_firewall_environment() {
	firewall_env_source=$(mktemp "${ENV_FILE}.firewall.XXXXXX")
	chmod 0600 "$firewall_env_source"
	sed '/^NODE_FIREWALL_REQUEST_FILE=/d' "$ENV_FILE" >"$firewall_env_source"
	printf '%s\n' "NODE_FIREWALL_REQUEST_FILE=\"${FIREWALL_REQUEST_FILE}\"" >>"$firewall_env_source"
	replace_managed_file "$firewall_env_source" "$ENV_FILE" 0600 || {
		rm -f -- "$firewall_env_source"
		die "unable to enable the host firewall in the One Node environment"
	}
	rm -f -- "$firewall_env_source"
}

enable_host_firewall_for_upgrade() {
	configure_host_firewall
	write_host_firewall_environment
	record_host_firewall_manifest_paths
	manifest_write "$INSTALL_RECORD" || die "unable to record the host firewall"
	install_host_firewall
}

stage_host_firewall_transition() {
	configure_host_firewall
	command -v nft >/dev/null 2>&1 || return 1
	[ -x "$FIREWALL_FILE" ] && [ ! -L "$FIREWALL_FILE" ] || return 1
	ONE_NODE_FIREWALL_DIR="${ONE_NODE_STATE_DIR}/firewall" "$FIREWALL_FILE" --initialize || return 1
	transition_source=$(mktemp "${ONE_NODE_STATE_DIR}/firewall/.transition.XXXXXX") || return 1
	printf '%s\n' \
		"flush set inet one_node tcp_ports" \
		"flush set inet one_node udp_ports" \
		"add element inet one_node tcp_ports { 20000-60000 }" \
		"add element inet one_node udp_ports { 20000-60000 }" >"$transition_source"
	if ! nft -f "$transition_source"; then
		rm -f -- "$transition_source"
		return 1
	fi
	rm -f -- "$transition_source"
}

install_host_firewall() {
	configure_host_firewall
	log "firewall: installing dynamic nftables port manager"
	command -v nft >/dev/null 2>&1 || die "nftables is required for One Node firewall management"
	command -v systemctl >/dev/null 2>&1 || die "systemd is required for One Node firewall management"
	firewall_temp_dir=$(mktemp -d "/tmp/one-node-host-firewall.XXXXXX")
	chmod 0700 "$firewall_temp_dir"
	firewall_script_source="${firewall_temp_dir}/firewall.sh"
	firewall_service_source="${firewall_temp_dir}/one-node-firewall.service"
	firewall_path_source="${firewall_temp_dir}/one-node-firewall.path"

	cat >"$firewall_script_source" <<'EOF'
#!/bin/sh
set -eu
umask 077

firewall_dir=${ONE_NODE_FIREWALL_DIR:-/var/lib/one-node/firewall}
request_file="${firewall_dir}/request"
running_file="${firewall_dir}/request.running"
status_file="${firewall_dir}/status"
table_family=inet
table_name=one_node
request_id=unknown
processing_request=false

die() {
	message=$*
	printf '%s\n' "[one-node-firewall] ${message}" >&2
	if [ "$processing_request" = true ]; then
		rm -f -- "$request_file" "$running_file"
		sync -f "$firewall_dir" 2>/dev/null || true
		case "$request_id" in
		????????-????-????-????-????????????)
			case "$request_id" in
			*[!0-9a-f-]*) ;;
			*) write_status failed "$message" || true ;;
			esac
			;;
		esac
	fi
	exit 1
}

write_table_source() {
	target=$1
	cat >"$target" <<'NFT'
add table inet one_node
add set inet one_node tcp_ports { type inet_service; flags interval; elements = { 20000-60000 }; }
add set inet one_node udp_ports { type inet_service; flags interval; elements = { 20000-60000 }; }
add chain inet one_node input { type filter hook input priority -10; policy accept; }
add rule inet one_node input ct state established,related accept comment "one-node-established"
add rule inet one_node input tcp dport @tcp_ports accept comment "one-node-active-tcp"
add rule inet one_node input udp dport @udp_ports accept comment "one-node-active-udp"
add rule inet one_node input tcp dport 20000-60000 drop comment "one-node-unused-tcp"
add rule inet one_node input udp dport 20000-60000 drop comment "one-node-unused-udp"
NFT
}

validate_table() {
	table=$1
	for marker in \
		'set tcp_ports' \
		'set udp_ports' \
		'chain input' \
		'comment "one-node-established"' \
		'comment "one-node-active-tcp"' \
		'comment "one-node-active-udp"' \
		'comment "one-node-unused-tcp"' \
		'comment "one-node-unused-udp"'
	do
		printf '%s\n' "$table" | grep -F "$marker" >/dev/null || return 1
	done
}

initialize_table() {
	if table=$(nft -nn list table "$table_family" "$table_name" 2>/dev/null); then
		validate_table "$table" || die "existing nftables table inet one_node is not managed by One Node"
		return
	fi
	temporary=$(mktemp "${firewall_dir}/.table.XXXXXX")
	trap 'rm -f -- "$temporary"' EXIT HUP INT TERM
	write_table_source "$temporary"
	nft -f "$temporary" || die "unable to initialize nftables table inet one_node"
	rm -f -- "$temporary"
	trap - EXIT HUP INT TERM
}

validate_ports() {
	ports=$1
	[ -n "$ports" ] || return 0
	case "$ports" in
	,*|*,|*,,*|*[!0-9,]*) return 1 ;;
	esac
	old_ifs=$IFS
	IFS=,
	set -- $ports
	IFS=$old_ifs
	seen=,
	for port in "$@"; do
		case "$port" in 0|*[!0-9]*|0*) return 1 ;; esac
		[ "$port" -le 65535 ] || return 1
		case "$seen" in *",${port},"*) return 1 ;; esac
		seen="${seen}${port},"
	done
}

write_status() {
	state=$1
	message=$2
	temporary=$(mktemp "${firewall_dir}/.status.XXXXXX")
	chmod 0600 "$temporary"
	printf '%s\n' \
		"request_id=${request_id}" \
		"state=${state}" \
		"message=${message}" >"$temporary"
	sync -f "$temporary"
	mv -f -- "$temporary" "$status_file"
	sync -f "$firewall_dir"
}

apply_ports() {
	temporary=$(mktemp "${firewall_dir}/.rules.XXXXXX")
	trap 'rm -f -- "$temporary"' EXIT HUP INT TERM
	printf '%s\n' \
		"flush set inet one_node tcp_ports" \
		"flush set inet one_node udp_ports" >"$temporary"
	[ -z "$tcp_ports" ] || printf '%s\n' "add element inet one_node tcp_ports { ${tcp_ports} }" >>"$temporary"
	[ -z "$udp_ports" ] || printf '%s\n' "add element inet one_node udp_ports { ${udp_ports} }" >>"$temporary"
	if ! nft -f "$temporary"; then
		rm -f -- "$temporary"
		trap - EXIT HUP INT TERM
		return 1
	fi
	rm -f -- "$temporary"
	trap - EXIT HUP INT TERM
}

install -d -m 0700 "$firewall_dir"
initialize_table
[ "${1:-}" != "--initialize" ] || exit 0

processing_request=true
[ -f "$request_file" ] && [ ! -L "$request_file" ] || die "request is missing or unsafe"
[ "$(stat -c %a "$request_file")" = 600 ] || die "request permissions must be 0600"
[ "$(wc -l <"$request_file" | tr -d ' ')" = 3 ] || die "request has an invalid field count"
request_id=$(sed -n 's/^request_id=//p' "$request_file")
tcp_ports=$(sed -n 's/^tcp_ports=//p' "$request_file")
udp_ports=$(sed -n 's/^udp_ports=//p' "$request_file")
[ "$(grep -c '^request_id=' "$request_file")" = 1 ] || die "request_id is invalid"
[ "$(grep -c '^tcp_ports=' "$request_file")" = 1 ] || die "tcp_ports is invalid"
[ "$(grep -c '^udp_ports=' "$request_file")" = 1 ] || die "udp_ports is invalid"
case "$request_id" in ????????-????-????-????-????????????) ;; *) die "request_id is invalid" ;; esac
case "$request_id" in *[!0-9a-f-]*) die "request_id is invalid" ;; esac
validate_ports "$tcp_ports" || die "tcp_ports is invalid"
validate_ports "$udp_ports" || die "udp_ports is invalid"

mv -f -- "$request_file" "$running_file"
if apply_ports; then
	rm -f -- "$running_file"
	sync -f "$firewall_dir"
	write_status succeeded "firewall ports applied"
	exit 0
fi
rm -f -- "$running_file"
sync -f "$firewall_dir"
write_status failed "unable to apply nftables port sets"
exit 1
EOF

	cat >"$firewall_service_source" <<EOF
[Unit]
Description=Apply One Node dynamic firewall ports
After=network-pre.target nftables.service

[Service]
Type=oneshot
Environment="ONE_NODE_FIREWALL_DIR=${ONE_NODE_STATE_DIR}/firewall"
ExecStart=/opt/one-node/firewall.sh
UMask=0077
EOF

	cat >"$firewall_path_source" <<EOF
[Unit]
Description=Watch for One Node firewall requests
After=nftables.service

[Path]
PathExists=${FIREWALL_REQUEST_FILE}
Unit=one-node-firewall.service

[Install]
WantedBy=multi-user.target
EOF

	install -d -m 0700 "${ONE_NODE_STATE_DIR}/firewall"
	install -m 0700 "$firewall_script_source" "$FIREWALL_FILE"
	install -m 0644 "$firewall_service_source" "$FIREWALL_SERVICE_FILE"
	install -m 0644 "$firewall_path_source" "$FIREWALL_PATH_FILE"
	rm -rf -- "$firewall_temp_dir"
	ONE_NODE_FIREWALL_DIR="${ONE_NODE_STATE_DIR}/firewall" "$FIREWALL_FILE" --initialize
	systemctl daemon-reload
	systemctl enable --now one-node-firewall.path
	log "firewall: waiting for active runtime ports"
}

remove_host_firewall() {
	configure_host_firewall
	if command -v systemctl >/dev/null 2>&1; then
		systemctl disable --now one-node-firewall.path >/dev/null 2>&1 || true
		systemctl stop one-node-firewall.service >/dev/null 2>&1 || true
	fi
	if command -v nft >/dev/null 2>&1; then
		nft delete table inet one_node >/dev/null 2>&1 || true
	fi
}
