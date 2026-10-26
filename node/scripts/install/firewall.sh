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
	# A new table starts with every managed port closed. When an upgrade adds
	# the firewall to an install that never had it, the running runtime still
	# serves its ports, so keep the range open until the new runtime replaces
	# it with its own port list.
	host_firewall_table_existed=false
	if command -v nft >/dev/null 2>&1 && nft -nn list table inet one_node >/dev/null 2>&1; then
		host_firewall_table_existed=true
	fi
	write_host_firewall_environment
	record_host_firewall_manifest_paths
	manifest_write "$INSTALL_RECORD" || die "unable to record the host firewall"
	install_host_firewall
	if [ "$host_firewall_table_existed" = false ]; then
		stage_host_firewall_transition || die "unable to keep current runtime ports open while enabling the host firewall"
	fi
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
# Rules added to ufw/firewalld are tracked in the root-only install directory:
# the state directory belongs to the runtime account, which must not be able
# to choose which host rules root deletes.
host_rules_file=${ONE_NODE_FIREWALL_HOST_RULES:-/opt/one-node/.firewall-host-rules}
host_sync_warning=false
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

note() {
	printf '%s\n' "[one-node-firewall] $*" >&2
}

warn_host() {
	note "warning: $*"
	host_sync_warning=true
}

ufw_is_active() {
	command -v ufw >/dev/null 2>&1 || return 1
	ufw status 2>/dev/null | sed -n '1p' | grep -Eq '^Status:[[:space:]]+active$'
}

firewalld_is_running() {
	command -v firewall-cmd >/dev/null 2>&1 || return 1
	firewall-cmd --state >/dev/null 2>&1
}

valid_host_rule() {
	case "$1" in
	*[!0-9]*/tcp|*[!0-9]*/udp|/*) return 1 ;;
	[1-9]*/tcp|[1-9]*/udp) [ "${1%/*}" -le 65535 ] ;;
	*) return 1 ;;
	esac
}

valid_firewalld_zone() {
	case "$1" in
	''|-*|*[!A-Za-z0-9_-]*) return 1 ;;
	esac
}

# Opens the active ports in ufw and firewalld when they are enforcing, since
# their base chains can drop traffic the one_node table accepts. Only rules
# this script added are ever removed; ports that an existing rule already
# opens are left unmanaged. Failures are logged and never fail the request.
sync_host_firewalls() {
	desired_rules=""
	old_ifs=$IFS
	IFS=,
	for port in $tcp_ports; do desired_rules="${desired_rules} ${port}/tcp"; done
	for port in $udp_ports; do desired_rules="${desired_rules} ${port}/udp"; done
	IFS=$old_ifs

	tracked_rules=""
	if [ -e "$host_rules_file" ] || [ -L "$host_rules_file" ]; then
		if [ -f "$host_rules_file" ] && [ ! -L "$host_rules_file" ]; then
			tracked_rules=$(cat "$host_rules_file")
		else
			warn_host "ignoring unsafe host rule record $host_rules_file"
			return 0
		fi
	fi

	kept_rules=""
	IFS='
'
	for tracked in $tracked_rules; do
		IFS=$old_ifs
		set -f
		# shellcheck disable=SC2086
		set -- $tracked
		set +f
		backend=${1:-}
		case "$backend" in
		ufw) [ "$#" -eq 2 ] && zone="" && rule=$2 ;;
		firewalld) [ "$#" -eq 3 ] && zone=$2 && rule=$3 ;;
		*) false ;;
		esac || { warn_host "dropping invalid host rule record: $tracked"; continue; }
		valid_host_rule "$rule" || { warn_host "dropping invalid host rule record: $tracked"; continue; }
		if [ "$backend" = firewalld ] && ! valid_firewalld_zone "$zone"; then
			warn_host "dropping invalid host rule record: $tracked"
			continue
		fi
		case " $desired_rules " in
		*" ${rule} "*)
			kept_rules="${kept_rules}${tracked}
"
			continue
			;;
		esac
		if [ "$backend" = ufw ]; then
			if command -v ufw >/dev/null 2>&1 && ufw --force delete allow "$rule" >/dev/null 2>&1; then
				note "ufw: removed One Node rule for $rule"
			else
				warn_host "ufw: unable to remove One Node rule for $rule; will retry"
				kept_rules="${kept_rules}${tracked}
"
			fi
		else
			if command -v firewall-cmd >/dev/null 2>&1; then
				firewall-cmd --zone="$zone" --remove-port="$rule" >/dev/null 2>&1 || true
				if firewall-cmd --permanent --zone="$zone" --remove-port="$rule" >/dev/null 2>&1; then
					note "firewalld: removed One Node port $rule from zone $zone"
					continue
				fi
			fi
			warn_host "firewalld: unable to remove One Node port $rule from zone $zone; will retry"
			kept_rules="${kept_rules}${tracked}
"
		fi
	done
	IFS=$old_ifs

	if [ -n "$desired_rules" ] && ufw_is_active; then
		for rule in $desired_rules; do
			case "$kept_rules" in *"ufw ${rule}
"*) continue ;; esac
			if ufw_output=$(ufw allow "$rule" comment one-node 2>&1); then
				case "$ufw_output" in
				*[Ss]kipping*) note "ufw: $rule is already allowed by an existing rule; leaving it unmanaged" ;;
				*)
					kept_rules="${kept_rules}ufw ${rule}
"
					note "ufw: allowed $rule"
					;;
				esac
			else
				warn_host "ufw: unable to allow $rule"
			fi
		done
	fi
	if [ -n "$desired_rules" ] && firewalld_is_running; then
		zone=$(firewall-cmd --get-default-zone 2>/dev/null || true)
		if valid_firewalld_zone "$zone"; then
			for rule in $desired_rules; do
				case "$kept_rules" in *"firewalld ${zone} ${rule}
"*) continue ;; esac
				if firewall-cmd --zone="$zone" --query-port="$rule" >/dev/null 2>&1; then
					note "firewalld: $rule is already open in zone $zone; leaving it unmanaged"
					continue
				fi
				if firewall-cmd --zone="$zone" --add-port="$rule" >/dev/null 2>&1; then
					kept_rules="${kept_rules}firewalld ${zone} ${rule}
"
					firewall-cmd --permanent --zone="$zone" --add-port="$rule" >/dev/null 2>&1 ||
						warn_host "firewalld: $rule is open until the next firewalld reload only"
					note "firewalld: opened $rule in zone $zone"
				else
					warn_host "firewalld: unable to open $rule in zone $zone"
				fi
			done
		else
			warn_host "firewalld: unable to read a valid default zone"
		fi
	fi

	if [ -z "$kept_rules" ]; then
		rm -f -- "$host_rules_file"
		return 0
	fi
	rules_temporary=$(mktemp "${host_rules_file}.XXXXXX") || {
		warn_host "unable to record host firewall rules"
		return 0
	}
	if printf '%s' "$kept_rules" >"$rules_temporary" && chmod 0600 "$rules_temporary" &&
		mv -f -- "$rules_temporary" "$host_rules_file"; then
		return 0
	fi
	rm -f -- "$rules_temporary"
	warn_host "unable to record host firewall rules"
}

write_table_source() {
	target=$1
	cat >"$target" <<'NFT'
add table inet one_node
add set inet one_node tcp_ports { type inet_service; flags interval; }
add set inet one_node udp_ports { type inet_service; flags interval; }
add chain inet one_node input { type filter hook input priority -10; policy accept; }
add rule inet one_node input iifname "lo" accept comment "one-node-loopback"
add rule inet one_node input ct state established,related accept comment "one-node-established"
add rule inet one_node input tcp dport @tcp_ports accept comment "one-node-active-tcp"
add rule inet one_node input udp dport @udp_ports accept comment "one-node-active-udp"
add rule inet one_node input tcp dport 20000-60000 drop comment "one-node-unused-tcp"
add rule inet one_node input udp dport 20000-60000 drop comment "one-node-unused-udp"
NFT
	write_restricted_chain >>"$target"
}

# The restricted base chain runs before chain input (priority -10), so its
# drops win over the @tcp_ports/@udp_ports accepts. Re-adding it is a no-op,
# which also upgrades tables created before it existed.
write_restricted_chain() {
	printf '%s\n' \
		"add chain inet one_node restricted { type filter hook input priority -15; policy accept; }"
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
		# Tables from older installs dropped loopback too, hiding local services (nginx upstreams) in 20000-60000.
		case "$table" in
		*'comment "one-node-loopback"'*) ;;
		*) nft insert rule inet one_node input iifname '"lo"' accept comment '"one-node-loopback"' || die "unable to exempt loopback in nftables table inet one_node" ;;
		esac
		return
	fi
	temporary=$(mktemp "${firewall_dir}/.table.XXXXXX")
	trap 'rm -f -- "$temporary"' EXIT HUP INT TERM
	write_table_source "$temporary"
	nft -f "$temporary" || die "unable to initialize nftables table inet one_node"
	rm -f -- "$temporary"
	trap - EXIT HUP INT TERM
}

valid_decimal() {
	case "$1" in
	0) return 0 ;;
	''|*[!0-9]*|0*|??????*) return 1 ;;
	esac
	[ "$1" -le "$2" ]
}

valid_ipv4_cidr() {
	case "$1" in
	*/*/*|*[!0-9./]*|*..*|.*|*./*) return 1 ;;
	*.*.*.*.*/*) return 1 ;;
	*.*.*.*/*) ;;
	*) return 1 ;;
	esac
	valid_decimal "${1#*/}" 32 || return 1
	ipv4_rest=${1%/*}
	while :; do
		valid_decimal "${ipv4_rest%%.*}" 255 || return 1
		case "$ipv4_rest" in *.*) ipv4_rest=${ipv4_rest#*.} ;; *) return 0 ;; esac
	done
}

# Sets ipv6_groups to the number of 1-4 digit hex groups in $1, which must be
# empty or groups joined by single colons.
count_ipv6_groups() {
	ipv6_groups=0
	[ -n "$1" ] || return 0
	case "$1" in :*|*:|*::*) return 1 ;; esac
	ipv6_rest=$1
	while :; do
		case "${ipv6_rest%%:*}" in ''|?????*|*[!0-9a-f]*) return 1 ;; esac
		ipv6_groups=$((ipv6_groups + 1))
		case "$ipv6_rest" in *:*) ipv6_rest=${ipv6_rest#*:} ;; *) return 0 ;; esac
	done
}

# Lowercase hex only, no zones or embedded IPv4, explicit prefix length.
valid_ipv6_cidr() {
	case "$1" in
	*/*/*|*[!0-9a-f:/]*|*:::*|*::*::*) return 1 ;;
	*:*/*) ;;
	*) return 1 ;;
	esac
	valid_decimal "${1#*/}" 128 || return 1
	ipv6_address=${1%/*}
	case "$ipv6_address" in
	*::*)
		count_ipv6_groups "${ipv6_address%%::*}" || return 1
		ipv6_head=$ipv6_groups
		count_ipv6_groups "${ipv6_address#*::}" || return 1
		[ $((ipv6_head + ipv6_groups)) -le 7 ]
		;;
	*)
		count_ipv6_groups "$ipv6_address" || return 1
		[ "$ipv6_groups" -eq 8 ]
		;;
	esac
}

port_listed() {
	case ",$2," in *",$1,"*) return 0 ;; esac
	return 1
}

# restricted=<tcp|udp>:<port>:<cidr>|<cidr>;... limits a listed port inside
# the managed range to the given sources. An empty source list drops every
# source. Validated sources are collected into restricted_rules as nft
# commands; nothing from the request reaches nft unvalidated.
validate_restricted() {
	restricted_rules=""
	[ -n "$restricted" ] || return 0
	case "$restricted" in
	\;*|*\;|*\;\;*|*[!0-9a-fptu:./'|;']*) return 1 ;;
	esac
	restricted_seen=";"
	restricted_count=0
	restricted_rest=$restricted
	while :; do
		entry=${restricted_rest%%;*}
		restricted_count=$((restricted_count + 1))
		[ "$restricted_count" -le 128 ] || return 1
		protocol=${entry%%:*}
		case "$entry" in *:*:*) ;; *) return 1 ;; esac
		entry_rest=${entry#*:}
		port=${entry_rest%%:*}
		sources=${entry_rest#*:}
		case "$protocol" in
		tcp) port_listed "$port" "$tcp_ports" || return 1 ;;
		udp) port_listed "$port" "$udp_ports" || return 1 ;;
		*) return 1 ;;
		esac
		valid_decimal "$port" 65535 || return 1
		[ "$port" -ge 20000 ] && [ "$port" -le 60000 ] || return 1
		case "$restricted_seen" in *";${protocol}:${port};"*) return 1 ;; esac
		restricted_seen="${restricted_seen}${protocol}:${port};"

		ipv4_sources=""
		ipv6_sources=""
		source_count=0
		case "$sources" in \|*|*\||*\|\|*) return 1 ;; esac
		sources_rest=$sources
		while [ -n "$sources_rest" ]; do
			source=${sources_rest%%|*}
			source_count=$((source_count + 1))
			[ "$source_count" -le 1024 ] || return 1
			if valid_ipv4_cidr "$source"; then
				ipv4_sources="${ipv4_sources:+${ipv4_sources}, }${source}"
			elif valid_ipv6_cidr "$source"; then
				ipv6_sources="${ipv6_sources:+${ipv6_sources}, }${source}"
			else
				return 1
			fi
			case "$sources_rest" in *"|"*) sources_rest=${sources_rest#*|} ;; *) sources_rest="" ;; esac
		done
		[ -z "$ipv4_sources" ] || restricted_rules="${restricted_rules}add rule inet one_node restricted ${protocol} dport ${port} ip saddr { ${ipv4_sources} } accept comment \"one-node-restricted-allow\"
"
		[ -z "$ipv6_sources" ] || restricted_rules="${restricted_rules}add rule inet one_node restricted ${protocol} dport ${port} ip6 saddr { ${ipv6_sources} } accept comment \"one-node-restricted-allow\"
"
		restricted_rules="${restricted_rules}add rule inet one_node restricted ${protocol} dport ${port} drop comment \"one-node-restricted-drop\"
"
		case "$restricted_rest" in *";"*) restricted_rest=${restricted_rest#*;} ;; *) return 0 ;; esac
	done
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
	# The native node runs as one-node and must read the status back.
	status_owner=$(stat -c %u:%g "$firewall_dir" 2>/dev/null) &&
		chown "$status_owner" "$temporary" 2>/dev/null || true
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
	# One nft transaction: the sets and the restricted chain change together.
	{
		write_restricted_chain
		printf '%s\n' \
			"flush chain inet one_node restricted" \
			"add rule inet one_node restricted iifname \"lo\" accept comment \"one-node-restricted-loopback\"" \
			"add rule inet one_node restricted ct state established,related accept comment \"one-node-restricted-established\""
		printf '%s' "$restricted_rules"
	} >>"$temporary"
	if ! nft -f "$temporary"; then
		rm -f -- "$temporary"
		trap - EXIT HUP INT TERM
		return 1
	fi
	rm -f -- "$temporary"
	trap - EXIT HUP INT TERM
}

if [ "${1:-}" = "--remove-host-rules" ]; then
	tcp_ports=""
	udp_ports=""
	sync_host_firewalls
	exit 0
fi

install -d -m 0700 "$firewall_dir"
initialize_table
[ "${1:-}" != "--initialize" ] || exit 0

processing_request=true
[ -f "$request_file" ] && [ ! -L "$request_file" ] || die "request is missing or unsafe"
[ "$(stat -c %a "$request_file")" = 600 ] || die "request permissions must be 0600"
# Read first so later failures can still be reported; die only echoes it
# after checking its shape.
request_id=$(sed -n 's/^request_id=//p' "$request_file")
request_lines=$(wc -l <"$request_file" | tr -d ' ')
restricted_lines=$(grep -c '^restricted=' "$request_file" || true)
# Older nodes send three lines; restricted= is the optional fourth.
[ "$request_lines" = $((3 + restricted_lines)) ] && [ "$restricted_lines" -le 1 ] ||
	die "request has an invalid field count"
tcp_ports=$(sed -n 's/^tcp_ports=//p' "$request_file")
udp_ports=$(sed -n 's/^udp_ports=//p' "$request_file")
restricted=$(sed -n 's/^restricted=//p' "$request_file")
[ "$(grep -c '^request_id=' "$request_file")" = 1 ] || die "request_id is invalid"
[ "$(grep -c '^tcp_ports=' "$request_file")" = 1 ] || die "tcp_ports is invalid"
[ "$(grep -c '^udp_ports=' "$request_file")" = 1 ] || die "udp_ports is invalid"
case "$request_id" in ????????-????-????-????-????????????) ;; *) die "request_id is invalid" ;; esac
case "$request_id" in *[!0-9a-f-]*) die "request_id is invalid" ;; esac
validate_ports "$tcp_ports" || die "tcp_ports is invalid"
validate_ports "$udp_ports" || die "udp_ports is invalid"
validate_restricted || die "restricted is invalid"

mv -f -- "$request_file" "$running_file"
if apply_ports; then
	rm -f -- "$running_file"
	sync -f "$firewall_dir"
	sync_host_firewalls
	if [ "$host_sync_warning" = true ]; then
		write_status succeeded "firewall ports applied; ufw/firewalld sync incomplete, see journalctl -u one-node-firewall"
	else
		write_status succeeded "firewall ports applied"
	fi
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
TimeoutStartSec=60s
Environment="ONE_NODE_FIREWALL_DIR=${ONE_NODE_STATE_DIR}/firewall"
Environment="ONE_NODE_FIREWALL_HOST_RULES=${INSTALL_DIR}/.firewall-host-rules"
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

# Removes only the ufw/firewalld rules the installed firewall script recorded
# as its own. Scripts from older installs never added any and lack the flag.
remove_host_firewall_rules() {
	configure_host_firewall
	[ -f "$FIREWALL_FILE" ] && [ -x "$FIREWALL_FILE" ] && [ ! -L "$FIREWALL_FILE" ] || return 0
	grep -Fq -- '--remove-host-rules' "$FIREWALL_FILE" || return 0
	ONE_NODE_FIREWALL_HOST_RULES="${INSTALL_DIR}/.firewall-host-rules" "$FIREWALL_FILE" --remove-host-rules ||
		log "firewall: warning: unable to remove ufw/firewalld rules added by One Node"
}

remove_host_firewall() {
	configure_host_firewall
	remove_host_firewall_rules
	if command -v systemctl >/dev/null 2>&1; then
		systemctl disable --now one-node-firewall.path >/dev/null 2>&1 || true
		systemctl stop one-node-firewall.service >/dev/null 2>&1 || true
	fi
	if command -v nft >/dev/null 2>&1; then
		nft delete table inet one_node >/dev/null 2>&1 || true
	fi
}
