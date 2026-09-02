#!/bin/sh

# Canonical sing-box installer entrypoint.

set -eu
umask 077

ONE_NODE_INSTALL_MODULES="install/common.sh shared/manifest.sh uninstall/paths.sh uninstall/native.sh uninstall/docker.sh install/config.sh install/host.sh install/files.sh install/updater.sh install/firewall.sh install/tuning.sh install/native.sh install/native_reconfigure.sh install/docker.sh install/readiness.sh install/main.sh"
ONE_NODE_ENTRYPOINT_TEMP_DIR=""
ONE_NODE_INSTALLER_SOURCE=""
ONE_NODE_INSTALL_DIR=${ONE_NODE_INSTALL_DIR:-/opt/one-node}
ONE_NODE_INSTALL_RECORD="${ONE_NODE_INSTALL_DIR}/.installation"

entrypoint_die() {
	printf '%s\n' "[one-node] error: $*" >&2
	exit 1
}

entrypoint_cleanup() {
	[ -z "$ONE_NODE_ENTRYPOINT_TEMP_DIR" ] ||
		rm -rf -- "$ONE_NODE_ENTRYPOINT_TEMP_DIR"
}

manager_die() {
	printf '%s\n' "[one-node] error: $*" >&2
	exit 1
}

manager_require_root() {
	[ "$(id -u)" -eq 0 ] || manager_die "run ./install.sh as root"
}

manager_manifest_value() {
	manager_key=$1
	manager_matches=$(sed -n "s/^${manager_key}=//p" "$ONE_NODE_INSTALL_RECORD")
	[ -n "$manager_matches" ] || return 1
	[ "$(printf '%s\n' "$manager_matches" | wc -l | tr -d ' ')" = 1 ] || return 1
	printf '%s\n' "$manager_matches"
}

manager_env_value() {
	manager_key=$1
	sed -n "s/^${manager_key}=\"\(.*\)\"$/\1/p" "${ONE_NODE_INSTALL_DIR}/.env" | sed -n '1p'
}

manager_process_details() {
	manager_pid=$1
	MANAGER_MEMORY="-"
	MANAGER_UPTIME="-"
	case "$manager_pid" in
	''|*[!0-9]*|0) return ;;
	esac
	if [ -r "/proc/${manager_pid}/status" ]; then
		manager_rss=$(sed -n 's/^VmRSS:[[:space:]]*\([0-9][0-9]*\)[[:space:]]*kB$/\1/p' "/proc/${manager_pid}/status")
		if [ -n "$manager_rss" ]; then
			MANAGER_MEMORY=$(awk -v kib="$manager_rss" 'BEGIN {
				if (kib >= 1048576) printf "%.2f GiB", kib / 1048576;
				else if (kib >= 1024) printf "%.1f MiB", kib / 1024;
				else printf "%d KiB", kib
			}')
		fi
	fi
	if command -v ps >/dev/null 2>&1; then
		MANAGER_UPTIME=$(ps -o etime= -p "$manager_pid" 2>/dev/null | sed 's/^[[:space:]]*//' || true)
		[ -n "$MANAGER_UPTIME" ] || MANAGER_UPTIME="-"
	fi
}

manager_status() {
	manager_require_root
	[ -f "$ONE_NODE_INSTALL_RECORD" ] && [ ! -L "$ONE_NODE_INSTALL_RECORD" ] ||
		manager_die "One Node installation manifest was not found"
	manager_mode=$(manager_manifest_value mode) || manager_die "installation mode is missing"
	manager_version=$(manager_manifest_value current_version) || manager_die "current version is missing"
	manager_previous=$(manager_manifest_value previous_version 2>/dev/null || true)
	manager_node_id=$(manager_env_value NODE_NODE_ID 2>/dev/null || true)
	manager_pid=""
	manager_state="unknown"
	manager_memory="-"
	case "$manager_mode" in
	native)
		if command -v systemctl >/dev/null 2>&1; then
			manager_state=$(systemctl is-active one-node.service 2>/dev/null || true)
			manager_pid=$(systemctl show one-node.service -p MainPID --value 2>/dev/null || true)
		fi
		manager_process_details "$manager_pid"
		manager_memory=$MANAGER_MEMORY
		;;
	docker)
		if command -v docker >/dev/null 2>&1; then
			manager_state=$(docker inspect -f '{{.State.Status}}' one-node 2>/dev/null || true)
			manager_pid=$(docker inspect -f '{{.State.Pid}}' one-node 2>/dev/null || true)
			manager_memory=$(docker stats --no-stream --format '{{.MemUsage}}' one-node 2>/dev/null || true)
		fi
		manager_process_details "$manager_pid"
		[ -n "$manager_memory" ] || manager_memory=$MANAGER_MEMORY
		;;
	*) manager_die "unsupported installation mode: $manager_mode" ;;
	esac
	[ -n "$manager_state" ] || manager_state="unavailable"
	[ -n "$manager_pid" ] || manager_pid="-"
	[ -n "$manager_memory" ] || manager_memory="-"
	[ -n "$manager_node_id" ] || manager_node_id="-"
	[ -n "$manager_previous" ] || manager_previous="-"
	printf '%s\n' \
		"One Node status" \
		"  mode:             $manager_mode" \
		"  version:          $manager_version" \
		"  previous version: $manager_previous" \
		"  node id:          $manager_node_id" \
		"  state:            $manager_state" \
		"  pid:              $manager_pid" \
		"  memory:           $manager_memory" \
		"  uptime:           $MANAGER_UPTIME"
}

manager_doctor() {
	manager_status
	manager_mode=$(manager_manifest_value mode)
	[ -f "${ONE_NODE_INSTALL_DIR}/.env" ] && [ ! -L "${ONE_NODE_INSTALL_DIR}/.env" ] || manager_die "environment file is missing or unsafe"
	case "$manager_mode" in
	native)
		command -v systemctl >/dev/null 2>&1 || manager_die "systemctl is unavailable"
		systemctl is-active --quiet one-node.service || manager_die "one-node.service is not active"
		;;
	docker)
		command -v docker >/dev/null 2>&1 || manager_die "Docker is unavailable"
		docker compose version >/dev/null 2>&1 || manager_die "Docker Compose v2 is unavailable"
		docker inspect -f '{{.State.Running}}' one-node 2>/dev/null | grep -qx true || manager_die "One Node container is not running"
		;;
	esac
	command -v nft >/dev/null 2>&1 || manager_die "nftables is unavailable"
	command -v systemctl >/dev/null 2>&1 || manager_die "systemctl is unavailable"
	systemctl is-active --quiet one-node-firewall.path || manager_die "one-node-firewall.path is not active"
	nft -nn list table inet one_node >/dev/null 2>&1 || manager_die "One Node nftables table is unavailable"
	printf '%s\n' '[one-node] environment check passed'
}

manager_resolve_latest_version() {
	manager_releases=$(curl -q --proto '=https' --proto-redir '=https' --tlsv1.2 \
		--fail --silent --show-error --no-location \
		--connect-timeout 10 --max-time 30 --max-filesize 8388608 \
		--header 'Accept: application/vnd.github+json' \
		--header 'X-GitHub-Api-Version: 2022-11-28' \
		--user-agent 'one-node-manager' \
		'https://api.github.com/repos/voiceofhu/one-action/releases?per_page=100') ||
		manager_die "unable to resolve the latest One Node release"
	manager_version=$(printf '%s' "$manager_releases" |
		grep -Eo '"tag_name"[[:space:]]*:[[:space:]]*"one-node-v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)"' |
		sed -n '1s/^.*"one-node-v\([^"]*\)"$/\1/p')
	[ -n "$manager_version" ] || manager_die "latest One Node release was not found"
	printf '%s\n' "$manager_version"
}

manager_run_entrypoint() {
	manager_entrypoint=$1
	shift
	command -v curl >/dev/null 2>&1 || manager_die "curl is required"
	manager_temp=$(mktemp "/tmp/one-node-manager.XXXXXX") || manager_die "unable to create temporary file"
	manager_sha_file="${manager_temp}.sha"
	trap 'rm -f -- "$manager_temp" "$manager_sha_file"' EXIT HUP INT TERM
	entrypoint_resolve_action_commit "$manager_sha_file"
	rm -f -- "$manager_sha_file"
	curl -q --proto '=https' --proto-redir '=https' --tlsv1.2 \
		--fail --silent --show-error --no-location \
		--connect-timeout 10 --max-time 30 --max-filesize 1048576 \
		"https://raw.githubusercontent.com/voiceofhu/one-action/${ONE_ACTION_COMMIT}/node/${manager_entrypoint}" \
		--output "$manager_temp" || manager_die "unable to download ${manager_entrypoint}"
	chmod 0700 "$manager_temp"
	/bin/sh -n "$manager_temp" || manager_die "downloaded ${manager_entrypoint} has invalid syntax"
	/bin/sh "$manager_temp" "$@"
	manager_status=$?
	rm -f -- "$manager_temp"
	trap - EXIT HUP INT TERM
	return "$manager_status"
}

manager_upgrade() {
	manager_target=${1:-latest}
	if [ "$manager_target" = latest ]; then
		manager_target=$(manager_resolve_latest_version)
	fi
	case "$manager_target" in
	''|*[!0-9.]*) manager_die "upgrade version must contain three numeric components" ;;
	esac
	ONE_NODE_VERSION=$manager_target
	export ONE_NODE_VERSION
	manager_run_entrypoint upgrade.sh
}

manager_restart() {
	manager_require_root
	manager_mode=$(manager_manifest_value mode) || manager_die "installation mode is missing"
	case "$manager_mode" in
	native) systemctl restart one-node.service ;;
	docker) docker compose -f "${ONE_NODE_INSTALL_DIR}/docker-compose.yml" up -d --force-recreate ;;
	*) manager_die "unsupported installation mode: $manager_mode" ;;
	esac
	manager_status
}

manager_logs() {
	manager_require_root
	manager_follow=${1:-false}
	manager_mode=$(manager_manifest_value mode) || manager_die "installation mode is missing"
	case "$manager_mode:$manager_follow" in
	native:true) exec journalctl -u one-node.service -n 100 -f ;;
	native:false) journalctl -u one-node.service -n 100 --no-pager ;;
	docker:true) exec docker logs --tail 100 -f one-node ;;
	docker:false) docker logs --tail 100 one-node ;;
	*) manager_die "unsupported log request" ;;
	esac
}

manager_confirm_uninstall() {
	printf '%s' 'Remove One Node, its identity, and all runtime state? [y/N] '
	read -r manager_answer || return 1
	case "$manager_answer" in y|Y|yes|YES) return 0 ;; esac
	return 1
}

manager_help() {
	printf '%s\n' \
		'Manage the installed One Node runtime.' \
		'' \
		'Usage: ./install.sh [option]' \
		'' \
		'  --status' \
		'  --doctor' \
		'  --upgrade [latest|VERSION]' \
		'  --rollback' \
		'  --restart' \
		'  --logs [--follow]' \
		'  --uninstall [--yes]'
}

manager_interactive() {
	while :; do
		printf '%s\n' \
			'' \
			'One Node' \
			'  1. Status' \
			'  2. Doctor' \
			'  3. Upgrade to latest' \
			'  4. Upgrade to version' \
			'  5. Roll back' \
			'  6. Restart' \
			'  7. Logs' \
			'  8. Follow logs' \
			'  9. Uninstall' \
			'  0. Exit'
		printf '%s' 'Select: '
		read -r manager_choice || return 0
		case "$manager_choice" in
		1) manager_status ;;
		2) manager_doctor ;;
		3) manager_upgrade latest ;;
		4) printf '%s' 'Version: '; read -r manager_version; manager_upgrade "$manager_version" ;;
		5) manager_run_entrypoint upgrade.sh --rollback ;;
		6) manager_restart ;;
		7) manager_logs false ;;
		8) manager_logs true ;;
		9) manager_confirm_uninstall && manager_run_entrypoint uninstall.sh ;;
		0) return 0 ;;
		*) printf '%s\n' '[one-node] invalid selection' ;;
		esac
	done
}

manager_main() {
	manager_require_root
	if [ "$#" -eq 0 ]; then
		if [ -t 0 ] && [ -t 1 ]; then
			manager_interactive
		else
			manager_help
		fi
		return
	fi
	case "$1" in
	--status) [ "$#" -eq 1 ] || manager_die "--status takes no arguments"; manager_status ;;
	--doctor) [ "$#" -eq 1 ] || manager_die "--doctor takes no arguments"; manager_doctor ;;
	--upgrade) [ "$#" -le 2 ] || manager_die "--upgrade accepts one version"; manager_upgrade "${2:-latest}" ;;
	--rollback) [ "$#" -eq 1 ] || manager_die "--rollback takes no arguments"; manager_run_entrypoint upgrade.sh --rollback ;;
	--restart) [ "$#" -eq 1 ] || manager_die "--restart takes no arguments"; manager_restart ;;
	--logs) [ "$#" -le 2 ] || manager_die "--logs accepts only --follow"; [ "${2:-}" = --follow ] && manager_logs true || manager_logs false ;;
	--uninstall)
		if [ "${2:-}" = --yes ]; then manager_run_entrypoint uninstall.sh
		elif [ "$#" -eq 1 ] && [ -t 0 ]; then manager_confirm_uninstall && manager_run_entrypoint uninstall.sh
		else manager_die "--uninstall requires --yes outside an interactive terminal"
		fi
		;;
	--help|-h) manager_help ;;
	*) manager_die "unknown management option: $1" ;;
	esac
}

entrypoint_management_requested() {
	[ -f "$ONE_NODE_INSTALL_RECORD" ] && [ ! -L "$ONE_NODE_INSTALL_RECORD" ] || return 1
	[ "$#" -eq 0 ] && return 0
	case "$1" in
	--status|--doctor|--upgrade|--rollback|--restart|--logs|--uninstall|--help|-h) return 0 ;;
	esac
	return 1
}

entrypoint_local_source_dir() {
	case "$0" in
	*/*) ;;
	*) return 1 ;;
	esac
	entrypoint_dir=$(CDPATH='' cd -- "$(dirname "$0")" 2>/dev/null && pwd) ||
		return 1
	source_dir="${entrypoint_dir}/scripts"
	[ -f "${source_dir}/install/main.sh" ] && [ ! -L "${source_dir}/install/main.sh" ] ||
		return 1
	printf '%s\n' "$source_dir"
}

entrypoint_validate_action_commit() {
	case "$1" in
	''|*[!0-9a-f]*) return 1 ;;
	esac
	[ "${#1}" -eq 40 ]
}

entrypoint_resolve_action_commit() {
	response_path=$1
	action_commit=${ONE_ACTION_COMMIT:-}
	if [ -z "$action_commit" ]; then
		status_code=$(curl -q --proto '=https' --proto-redir '=https' --tlsv1.2 \
			--fail --silent --show-error --no-location \
			--connect-timeout 10 --max-time 30 --max-filesize 1048576 \
			--header 'Accept: application/vnd.github.sha' \
			--header 'X-GitHub-Api-Version: 2022-11-28' \
			--user-agent 'one-node-installer' \
			--write-out '%{http_code}' \
			'https://api.github.com/repos/voiceofhu/one-action/commits/main' \
			--output "$response_path") ||
			entrypoint_die "unable to resolve the One Action commit"
		[ "$status_code" = 200 ] || entrypoint_die "unexpected One Action commit response"
		action_commit=$(tr -d '\r\n' <"$response_path")
		entrypoint_validate_action_commit "$action_commit" ||
			entrypoint_die "One Action commit response must be an exact lowercase commit SHA"
	fi
	entrypoint_validate_action_commit "$action_commit" ||
		entrypoint_die "ONE_ACTION_COMMIT must be an exact lowercase commit SHA"
	ONE_ACTION_COMMIT=$action_commit
	export ONE_ACTION_COMMIT
}

entrypoint_module_base_url() {
	if [ -n "${ONE_NODE_SCRIPT_BASE_URL:-}" ]; then
		base_url=${ONE_NODE_SCRIPT_BASE_URL%/}
		case "$base_url" in
		http://127.0.0.1:*|http://localhost:*|http://host.orb.internal:*)
			[ "${ONE_NODE_ALLOW_INSECURE:-false}" = "true" ] ||
				entrypoint_die "local HTTP modules require ONE_NODE_ALLOW_INSECURE=true"
			;;
		*) entrypoint_die "ONE_NODE_SCRIPT_BASE_URL is only available for local development" ;;
		esac
	else
		base_url="https://raw.githubusercontent.com/voiceofhu/one-action/${ONE_ACTION_COMMIT}/node/scripts"
	fi
	base_url=${base_url%/}
	case "$base_url" in
	*/scripts) ;;
	*) entrypoint_die "ONE_NODE_SCRIPT_BASE_URL must end in scripts" ;;
	esac
	case "$base_url" in
	https://*) ;;
	http://127.0.0.1:*|http://localhost:*|http://host.orb.internal:*) ;;
	*) entrypoint_die "installer modules must use HTTPS" ;;
	esac
	printf '%s\n' "$base_url"
}

entrypoint_download_modules() {
	destination=$1
	command -v curl >/dev/null 2>&1 ||
		entrypoint_die "curl is required to load the installer"
	if [ -z "${ONE_NODE_SCRIPT_BASE_URL:-}" ]; then
		entrypoint_resolve_action_commit "${destination}/one-action-commit.sha"
	fi
	base_url=$(entrypoint_module_base_url)
	case "$base_url" in
	https://*) protocols='=https' ;;
	*) protocols='=http,https' ;;
	esac
	for module in $ONE_NODE_INSTALL_MODULES; do
		module_dir=${module%/*}
		install -d -m 0700 "${destination}/${module_dir}"
		curl -q --proto "$protocols" --proto-redir "$protocols" --tlsv1.2 \
			--fail --silent --show-error --no-location \
			--connect-timeout 10 --max-time 30 --max-filesize 1048576 \
			"${base_url}/${module}" --output "${destination}/${module}" ||
			entrypoint_die "unable to download installer module: $module"
		[ -s "${destination}/${module}" ] ||
			entrypoint_die "downloaded installer module is empty: $module"
		chmod 0600 "${destination}/${module}"
		/bin/sh -n "${destination}/${module}" ||
			entrypoint_die "downloaded installer module has invalid syntax: $module"
	done
	installer_url="${base_url%/scripts}/install.sh"
	curl -q --proto "$protocols" --proto-redir "$protocols" --tlsv1.2 \
		--fail --silent --show-error --no-location \
		--connect-timeout 10 --max-time 30 --max-filesize 1048576 \
		"$installer_url" --output "${destination}/install.sh" ||
		entrypoint_die "unable to download the persistent installer"
	[ -s "${destination}/install.sh" ] || entrypoint_die "downloaded installer is empty"
	chmod 0700 "${destination}/install.sh"
	/bin/sh -n "${destination}/install.sh" || entrypoint_die "downloaded installer has invalid syntax"
	ONE_NODE_INSTALLER_SOURCE="${destination}/install.sh"
	export ONE_NODE_INSTALLER_SOURCE
}

entrypoint_load_modules() {
	source_dir=$(entrypoint_local_source_dir 2>/dev/null || true)
	if [ -z "$source_dir" ]; then
		ONE_NODE_ENTRYPOINT_TEMP_DIR=$(mktemp -d "/tmp/one-node-installer.XXXXXX")
		chmod 0700 "$ONE_NODE_ENTRYPOINT_TEMP_DIR"
		trap entrypoint_cleanup EXIT HUP INT TERM
		entrypoint_download_modules "$ONE_NODE_ENTRYPOINT_TEMP_DIR"
		source_dir=$ONE_NODE_ENTRYPOINT_TEMP_DIR
	else
		ONE_NODE_INSTALLER_SOURCE="${source_dir%/scripts}/install.sh"
		export ONE_NODE_INSTALLER_SOURCE
	fi
	for module in $ONE_NODE_INSTALL_MODULES; do
		module_path="${source_dir}/${module}"
		[ -f "$module_path" ] && [ ! -L "$module_path" ] ||
			entrypoint_die "installer module must be a regular file: $module"
		# shellcheck disable=SC1090
		. "$module_path"
	done
}

if entrypoint_management_requested "$@"; then
	manager_main "$@"
	exit $?
fi

entrypoint_load_modules

if [ "${ONE_NODE_INSTALLER_LIBRARY_ONLY:-0}" != "1" ]; then
	main "$@"
fi
