#!/bin/sh

# Canonical sing-box installer entrypoint.

set -eu
umask 077

ONE_NODE_INSTALL_MODULES="install/common.sh shared/manifest.sh install/config.sh install/host.sh install/files.sh install/native.sh install/native_reconfigure.sh install/docker.sh install/readiness.sh install/main.sh"
ONE_NODE_ENTRYPOINT_TEMP_DIR=""

entrypoint_die() {
	printf '%s\n' "[one-node] error: $*" >&2
	exit 1
}

entrypoint_cleanup() {
	[ -z "$ONE_NODE_ENTRYPOINT_TEMP_DIR" ] ||
		rm -rf -- "$ONE_NODE_ENTRYPOINT_TEMP_DIR"
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
			--header 'Accept: application/vnd.github+json' \
			--header 'X-GitHub-Api-Version: 2022-11-28' \
			--user-agent 'one-node-installer' \
			--write-out '%{http_code}' \
			'https://api.github.com/repos/voiceofhu/one-action/git/ref/heads/main' \
			--output "$response_path") ||
			entrypoint_die "unable to resolve the One Action commit"
		[ "$status_code" = 200 ] || entrypoint_die "unexpected One Action ref response"
		action_commit=$(sed -n \
			's/^[[:space:]]*"sha"[[:space:]]*:[[:space:]]*"\([0-9a-f][0-9a-f]*\)"[,[:space:]]*$/\1/p' \
			"$response_path")
		[ "$(printf '%s\n' "$action_commit" | awk 'NF { count++ } END { print count + 0 }')" -eq 1 ] ||
			entrypoint_die "One Action ref response must contain exactly one commit"
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
		entrypoint_resolve_action_commit "${destination}/one-action-ref.json"
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
}

entrypoint_load_modules() {
	source_dir=$(entrypoint_local_source_dir 2>/dev/null || true)
	if [ -z "$source_dir" ]; then
		ONE_NODE_ENTRYPOINT_TEMP_DIR=$(mktemp -d "/tmp/one-node-installer.XXXXXX")
		chmod 0700 "$ONE_NODE_ENTRYPOINT_TEMP_DIR"
		trap entrypoint_cleanup EXIT HUP INT TERM
		entrypoint_download_modules "$ONE_NODE_ENTRYPOINT_TEMP_DIR"
		source_dir=$ONE_NODE_ENTRYPOINT_TEMP_DIR
	fi
	for module in $ONE_NODE_INSTALL_MODULES; do
		module_path="${source_dir}/${module}"
		[ -f "$module_path" ] && [ ! -L "$module_path" ] ||
			entrypoint_die "installer module must be a regular file: $module"
		# shellcheck disable=SC1090
		. "$module_path"
	done
	entrypoint_cleanup
	ONE_NODE_ENTRYPOINT_TEMP_DIR=""
	trap - EXIT HUP INT TERM
}

entrypoint_load_modules

if [ "${ONE_NODE_INSTALLER_LIBRARY_ONLY:-0}" != "1" ]; then
	main "$@"
fi
