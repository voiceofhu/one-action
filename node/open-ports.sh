#!/bin/sh
set -eu

PORT_MIN=20000
PORT_MAX=60000
PORT_RANGE="${PORT_MIN}:${PORT_MAX}"
NFT_PORT_RANGE="${PORT_MIN}-${PORT_MAX}"

log() {
	printf '%s\n' "[one-node] $*"
}

die() {
	printf '%s\n' "[one-node] error: $*" >&2
	exit 1
}

require_root() {
	[ "$(id -u)" -eq 0 ] || die "run this script as root"
}

persist_iptables() {
	if command -v netfilter-persistent >/dev/null 2>&1; then
		netfilter-persistent save
		log "saved firewall rules with netfilter-persistent"
		return
	fi
	if command -v service >/dev/null 2>&1 && service iptables save >/dev/null 2>&1; then
		log "saved firewall rules with the iptables service"
		return
	fi
	if command -v iptables-save >/dev/null 2>&1 && [ -d /etc/iptables ]; then
		rules_temp=$(mktemp /etc/iptables/rules.v4.XXXXXX) || die "unable to create iptables rules file"
		trap 'rm -f -- "$rules_temp"' EXIT HUP INT TERM
		iptables-save >"$rules_temp" || die "unable to serialize iptables rules"
		chmod 0600 "$rules_temp"
		mv -f -- "$rules_temp" /etc/iptables/rules.v4
		trap - EXIT HUP INT TERM
		log "saved firewall rules to /etc/iptables/rules.v4"
		return
	fi
	log "warning: no iptables persistence service was found; rules may be lost after reboot"
}

open_with_ufw() {
	ufw allow "${PORT_RANGE}/tcp" comment "One Node TCP"
	ufw allow "${PORT_RANGE}/udp" comment "One Node UDP"
	ufw reload
	log "opened TCP/UDP ${PORT_RANGE} with UFW"
}

open_with_firewalld() {
	zones=$(firewall-cmd --get-active-zones 2>/dev/null |
		awk 'NF && $1 != "interfaces:" && $1 != "sources:" && $1 !~ /^[[:space:]]/ { print $1 }')
	if [ -z "$zones" ]; then
		zones=$(firewall-cmd --get-default-zone) || die "unable to resolve the firewalld zone"
	fi
	for zone in $zones; do
		firewall-cmd --permanent --zone="$zone" --query-port="${NFT_PORT_RANGE}/tcp" >/dev/null 2>&1 ||
			firewall-cmd --permanent --zone="$zone" --add-port="${NFT_PORT_RANGE}/tcp" >/dev/null
		firewall-cmd --permanent --zone="$zone" --query-port="${NFT_PORT_RANGE}/udp" >/dev/null 2>&1 ||
			firewall-cmd --permanent --zone="$zone" --add-port="${NFT_PORT_RANGE}/udp" >/dev/null
	done
	firewall-cmd --reload >/dev/null
	log "opened TCP/UDP ${PORT_RANGE} with firewalld"
}

resolve_nft_input_chain() {
	nft -nn list ruleset 2>/dev/null | awk '
		$1 == "table" && NF >= 3 { family = $2; table_name = $3 }
		$1 == "chain" && NF >= 2 { chain_name = $2 }
		/type[[:space:]]+filter[[:space:]]+hook[[:space:]]+input/ && family != "" && table_name != "" && chain_name != "" {
			print family, table_name, chain_name
			exit
		}
	'
}

open_with_nftables() {
	nft_input=$(resolve_nft_input_chain)
	set -- $nft_input
	[ "$#" -eq 3 ] || die "unable to resolve the active nftables input chain"
	nft_family=$1
	nft_table=$2
	nft_chain=$3
	if ! nft list chain "$nft_family" "$nft_table" "$nft_chain" 2>/dev/null |
		grep -F 'one-node-managed-tcp' >/dev/null; then
		nft insert rule "$nft_family" "$nft_table" "$nft_chain" \
			tcp dport "$NFT_PORT_RANGE" counter accept comment "one-node-managed-tcp"
	fi
	if ! nft list chain "$nft_family" "$nft_table" "$nft_chain" 2>/dev/null |
		grep -F 'one-node-managed-udp' >/dev/null; then
		nft insert rule "$nft_family" "$nft_table" "$nft_chain" \
			udp dport "$NFT_PORT_RANGE" counter accept comment "one-node-managed-udp"
	fi
	log "warning: raw nftables rules were applied at runtime; persist them in the host nftables configuration"
	log "opened TCP/UDP ${PORT_RANGE} with nftables"
}

insert_iptables_rule() {
	protocol=$1
	comment=$2
	if iptables -C INPUT -p "$protocol" --dport "$PORT_RANGE" -j ACCEPT 2>/dev/null; then
		return
	fi
	reject_line=$(iptables -L INPUT -n --line-numbers 2>/dev/null |
		awk '$2 == "REJECT" || $2 == "DROP" { print $1; exit }')
	if [ -n "$reject_line" ]; then
		iptables -I INPUT "$reject_line" -p "$protocol" --dport "$PORT_RANGE" \
			-m comment --comment "$comment" -j ACCEPT
	else
		iptables -A INPUT -p "$protocol" --dport "$PORT_RANGE" \
			-m comment --comment "$comment" -j ACCEPT
	fi
}

open_with_iptables() {
	iptables -S INPUT >/dev/null 2>&1 || die "iptables INPUT chain is unavailable"
	insert_iptables_rule tcp "One Node TCP"
	insert_iptables_rule udp "One Node UDP"
	persist_iptables
	log "opened TCP/UDP ${PORT_RANGE} with iptables"
}

main() {
	require_root

	if command -v ufw >/dev/null 2>&1 &&
		ufw status 2>/dev/null | grep -Eq '^Status:[[:space:]]+active'; then
		open_with_ufw
	elif command -v firewall-cmd >/dev/null 2>&1 &&
		firewall-cmd --state 2>/dev/null | grep -qx running; then
		open_with_firewalld
	elif command -v nft >/dev/null 2>&1 && command -v systemctl >/dev/null 2>&1 &&
		systemctl is-active --quiet nftables; then
		open_with_nftables
	elif command -v iptables >/dev/null 2>&1; then
		open_with_iptables
	elif command -v nft >/dev/null 2>&1 && [ -n "$(resolve_nft_input_chain)" ]; then
		open_with_nftables
	else
		log "no supported active host firewall was detected; no local rule was required"
	fi

	log "cloud security groups, provider firewalls, and router ACLs must allow the same range"
}

main "$@"
