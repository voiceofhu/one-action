#!/bin/sh

log() {
	printf '%s\n' "[one-node] $*"
}

die() {
	printf '%s\n' "[one-node] error: $*" >&2
	if [ "${SHOW_UNINSTALL_ON_ERROR:-false}" = "true" ] &&
		command -v print_installation_uninstall_command >/dev/null 2>&1; then
		print_installation_uninstall_command ||
			printf '%s\n' \
				"[one-node] run the commit-pinned node/uninstall.sh from voiceofhu/one-action, then retry" >&2
	fi
	exit 1
}

file_mode() {
	stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1" 2>/dev/null
}

canonical_path() {
	canonical_input=$1
	case "$canonical_input" in
	/*) ;;
	*) return 1 ;;
	esac
	case "$canonical_input" in
	*'//'*) return 1 ;;
	*'
'*|*''*) return 1 ;;
	esac
	case "/${canonical_input#/}/" in
	*'/../'*) return 1 ;;
	esac

	if command -v realpath >/dev/null 2>&1; then
		canonical_result=$(realpath -m -- "$canonical_input" 2>/dev/null) && {
			printf '%s\n' "$canonical_result"
			return 0
		}
	fi

	canonical_rest=${canonical_input#/}
	canonical_result=""
	while [ -n "$canonical_rest" ]; do
		case "$canonical_rest" in
		*/*)
			canonical_part=${canonical_rest%%/*}
			canonical_rest=${canonical_rest#*/}
			;;
		*)
			canonical_part=$canonical_rest
			canonical_rest=""
			;;
		esac
		[ "$canonical_part" = "." ] && continue
		canonical_result="${canonical_result}/${canonical_part}"
	done
	[ -n "$canonical_result" ] || canonical_result=/
	printf '%s\n' "$canonical_result"
}

show_help() {
	printf '%s\n' \
		"Install the One Node sing-box data plane." \
		"" \
		"Usage: install.sh --mode <native|docker> [--reset]" \
		"" \
		"  native  Install one one-node systemd service." \
		"  docker  Install one complete immutable One Node image." \
		"  --reset Remove the existing One Node development installation first."
}

require_value() {
	name=$1
	value=$2
	[ -n "$value" ] || die "${name} is required"
}

require_single_line() {
	name=$1
	value=$2
	case "$value" in
	*'
'*|*''*) die "${name} must be a single line" ;;
	esac
}

normalize_sha256() {
	printf '%s' "$1" | tr 'A-F' 'a-f'
}

validate_sha256() {
	digest=$1
	case "$digest" in
	''|*[!0-9a-f]*) return 1 ;;
	esac
	[ "${#digest}" -eq 64 ]
}

validate_decimal() {
	value=$1
	case "$value" in
	''|*[!0-9]*) return 1 ;;
	esac
	[ "$value" = "0" ] || [ "${value#0}" = "$value" ]
}

escape_dotenv() {
	printf '%s' "$1" | sed \
		-e 's/\\/\\\\/g' \
		-e 's/"/\\"/g' \
		-e 's/\$/\\$/g'
}

write_env() {
	key=$1
	value=$2
	escaped=$(escape_dotenv "$value")
	printf '%s="%s"\n' "$key" "$escaped" >>"$ENV_SOURCE"
}

download_file() {
	url=$1
	destination=$2
	case "$url" in
	https://*) protocols='=https' ;;
	http://*)
		[ "$ONE_NODE_ALLOW_INSECURE" = "true" ] ||
			die "HTTP downloads require ONE_NODE_ALLOW_INSECURE=true"
		protocols='=http,https'
		;;
	*) die "download URL must use HTTP or HTTPS" ;;
	esac
	curl --fail --location --silent --show-error --retry 3 \
		--proto "$protocols" --proto-redir "$protocols" \
		--output "$destination" "$url"
}
