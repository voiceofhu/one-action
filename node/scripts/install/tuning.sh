#!/bin/sh

configure_network_tuning() {
	NETWORK_TUNING_FILE=${NETWORK_TUNING_FILE:-/etc/sysctl.d/99-zz-one-node.conf}
	BBR_MODULE_FILE=${BBR_MODULE_FILE:-/etc/modules-load.d/90-one-node-bbr.conf}
	NETWORK_MEMINFO_FILE=${NETWORK_MEMINFO_FILE:-/proc/meminfo}
}

normalize_tuning_value() {
	awk '{$1=$1; print}'
}

network_setting_matches() {
	setting_key=$1
	expected_value=$2
	actual_value=$(sysctl -n "$setting_key" 2>/dev/null | normalize_tuning_value) || return 1
	[ "$actual_value" = "$expected_value" ]
}

# Only the per-socket ceilings grow with RAM. The initial windows stay at the
# kernel defaults (rmem 131072, wmem 16384) so idle connections cost no more
# memory than before, and autotuning raises busy sockets up to the ceiling.
calculate_network_tuning_profile() {
	memory_kib=$1
	case "$memory_kib" in ''|*[!0-9]*|0) return 1 ;; esac
	if [ "$memory_kib" -lt 2097152 ]; then
		tcp_max_mib=64
	else
		tcp_max_mib=128
	fi
	tcp_max_bytes=$((tcp_max_mib * 1024 * 1024))
	tcp_rmem_value="4096 131072 ${tcp_max_bytes}"
	tcp_wmem_value="4096 16384 ${tcp_max_bytes}"
	# About 128 tracked flows per MiB keeps the conntrack table under ~4% of
	# RAM even when full (roughly 320 bytes per entry).
	conntrack_max=$(((memory_kib / 1024) * 128))
	[ "$conntrack_max" -ge 65536 ] || conntrack_max=65536
	[ "$conntrack_max" -le 1048576 ] || conntrack_max=1048576
}

# Prints the larger of the kernel's current value and the One Node minimum so
# an administrator's higher setting is never lowered.
network_setting_at_least() {
	setting_key=$1
	minimum_value=$2
	current_value=$(sysctl -n "$setting_key" 2>/dev/null | normalize_tuning_value) || current_value=""
	case "$current_value" in
	''|*[!0-9]*) printf '%s\n' "$minimum_value" ;;
	*)
		if [ "$current_value" -gt "$minimum_value" ]; then
			printf '%s\n' "$current_value"
		else
			printf '%s\n' "$minimum_value"
		fi
		;;
	esac
}

bbr_is_persisted() {
	for modules_file in \
		/etc/modules \
		/etc/modules-load.d/*.conf \
		/run/modules-load.d/*.conf \
		/usr/local/lib/modules-load.d/*.conf \
		/usr/lib/modules-load.d/*.conf
	do
		[ -f "$modules_file" ] && [ ! -L "$modules_file" ] || continue
		grep -Eq '^[[:space:]]*tcp_bbr([[:space:]]*(#.*)?)?$' "$modules_file" && return 0
	done
	return 1
}

apply_network_tuning() {
	if node_role_is_monitor; then
		log "network tuning: skipped for a monitor node"
		return 0
	fi
	configure_network_tuning
	log "network tuning: checking BBR, fq, TCP buffer, backlog, and conntrack settings"
	command -v sysctl >/dev/null 2>&1 || die "sysctl is required for One Node network tuning"
	command -v cmp >/dev/null 2>&1 || die "cmp is required for One Node network tuning"
	tuning_temp_dir=$(mktemp -d "/tmp/one-node-network-tuning.XXXXXX")
	chmod 0700 "$tuning_temp_dir"
	tuning_source="${tuning_temp_dir}/99-zz-one-node.conf"
	bbr_source="${tuning_temp_dir}/90-one-node-bbr.conf"
	tuning_changed=false
	effective_changed=false
	bbr_enabled=false
	memory_kib=$(awk '/^MemTotal:[[:space:]]+[0-9]+[[:space:]]+kB$/ { print $2; exit }' "$NETWORK_MEMINFO_FILE" 2>/dev/null)
	calculate_network_tuning_profile "$memory_kib" || die "unable to calculate network tuning from system memory"
	memory_mib=$(((memory_kib + 1023) / 1024))
	somaxconn_value=$(network_setting_at_least net.core.somaxconn 4096)
	# nf_conntrack only exposes this key once the module is loaded; hosts
	# without connection tracking keep their kernel defaults.
	conntrack_value=""
	if sysctl -n net.netfilter.nf_conntrack_max >/dev/null 2>&1; then
		conntrack_value=$(network_setting_at_least net.netfilter.nf_conntrack_max "$conntrack_max")
	fi
	log "network tuning: detected ${memory_mib} MiB RAM; TCP buffer max ${tcp_max_mib} MiB (initial windows at kernel defaults), listen backlog ${somaxconn_value}, conntrack max ${conntrack_value:-unavailable}"

	if sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null |
		grep -Eq '(^|[[:space:]])bbr($|[[:space:]])'; then
		bbr_enabled=true
	elif command -v modprobe >/dev/null 2>&1 && modprobe tcp_bbr >/dev/null 2>&1 &&
		sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null |
		grep -Eq '(^|[[:space:]])bbr($|[[:space:]])'; then
		bbr_enabled=true
	fi

	cat >"$tuning_source" <<EOF
net.core.default_qdisc = fq
net.core.rmem_max = ${tcp_max_bytes}
net.core.wmem_max = ${tcp_max_bytes}
net.ipv4.tcp_rmem = ${tcp_rmem_value}
net.ipv4.tcp_wmem = ${tcp_wmem_value}
net.core.somaxconn = ${somaxconn_value}
# Large send buffers otherwise queue unsent data and add latency under BBR.
net.ipv4.tcp_notsent_lowat = 131072
# Probe the path MTU only after a black hole is detected.
net.ipv4.tcp_mtu_probing = 1
EOF
	if [ -n "$conntrack_value" ]; then
		printf '%s\n' "net.netfilter.nf_conntrack_max = ${conntrack_value}" >>"$tuning_source"
	fi
	if [ "$bbr_enabled" = true ]; then
		printf '%s\n' 'net.ipv4.tcp_congestion_control = bbr' >>"$tuning_source"
		printf '%s\n' 'tcp_bbr' >"$bbr_source"
		if ! bbr_is_persisted; then
			install -d -m 0755 "$(dirname "$BBR_MODULE_FILE")"
			[ ! -L "$BBR_MODULE_FILE" ] || die "BBR modules-load path must not be a symlink"
			[ ! -e "$BBR_MODULE_FILE" ] || [ -f "$BBR_MODULE_FILE" ] || die "BBR modules-load path must be a regular file"
			install -m 0644 "$bbr_source" "$BBR_MODULE_FILE"
			tuning_changed=true
		fi
	else
		log "network tuning: warning: BBR is unavailable; retaining the kernel congestion control"
	fi

	[ ! -L "$NETWORK_TUNING_FILE" ] || die "network tuning path must not be a symlink"
	[ ! -e "$NETWORK_TUNING_FILE" ] || [ -f "$NETWORK_TUNING_FILE" ] || die "network tuning path must be a regular file"
	if [ ! -f "$NETWORK_TUNING_FILE" ] || ! cmp -s "$tuning_source" "$NETWORK_TUNING_FILE"; then
		install -d -m 0755 "$(dirname "$NETWORK_TUNING_FILE")"
		install -m 0644 "$tuning_source" "$NETWORK_TUNING_FILE"
		tuning_changed=true
	fi

	for tuning_pair in \
		'net.core.default_qdisc|fq' \
		"net.core.rmem_max|${tcp_max_bytes}" \
		"net.core.wmem_max|${tcp_max_bytes}" \
		"net.ipv4.tcp_rmem|${tcp_rmem_value}" \
		"net.ipv4.tcp_wmem|${tcp_wmem_value}" \
		"net.core.somaxconn|${somaxconn_value}" \
		'net.ipv4.tcp_notsent_lowat|131072' \
		'net.ipv4.tcp_mtu_probing|1'
	do
		tuning_key=${tuning_pair%%|*}
		tuning_value=${tuning_pair#*|}
		if ! network_setting_matches "$tuning_key" "$tuning_value"; then
			effective_changed=true
			break
		fi
	done
	if [ "$bbr_enabled" = true ] &&
		! network_setting_matches net.ipv4.tcp_congestion_control bbr; then
		effective_changed=true
	fi
	if [ -n "$conntrack_value" ] &&
		! network_setting_matches net.netfilter.nf_conntrack_max "$conntrack_value"; then
		effective_changed=true
	fi

	if [ "$effective_changed" = true ]; then
		sysctl -p "$NETWORK_TUNING_FILE" >/dev/null || die "unable to apply One Node network tuning"
	fi
	rm -rf -- "$tuning_temp_dir"

	if [ "$tuning_changed" = true ] || [ "$effective_changed" = true ]; then
		if [ "$bbr_enabled" = true ]; then
			log "network tuning: applied fq + BBR and the ${tcp_max_mib} MiB dynamic socket-buffer profile"
		else
			log "network tuning: applied fq and the ${tcp_max_mib} MiB dynamic socket-buffer profile"
		fi
	else
		log "network tuning: already optimized"
	fi
}
