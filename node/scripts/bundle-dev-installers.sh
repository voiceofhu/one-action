#!/bin/sh
set -eu

ROOT_DIR=$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)
OUTPUT_DIR=${1:-"${ROOT_DIR}/dist"}

read_modules() {
	entrypoint=$1
	variable=$2
	modules=$(sed -n "s/^${variable}=\"\([^\"]*\)\"$/\\1/p" "${ROOT_DIR}/${entrypoint}")
	[ -n "$modules" ] || {
		printf '%s\n' "unable to read ${variable} from ${entrypoint}" >&2
		exit 1
	}
	printf '%s\n' "$modules"
}

bundle_entrypoint() {
	entrypoint=$1
	variable=$2
	output_name=$3
	modules=$(read_modules "$entrypoint" "$variable")
	output_path="${OUTPUT_DIR}/${output_name}"
	temporary_path=$(mktemp "${output_path}.XXXXXX")
	trap 'rm -f -- "$temporary_path"' EXIT HUP INT TERM
	{
		printf '%s\n' '#!/bin/sh' 'set -eu' 'umask 077'
		for module in $modules; do
			module_path="${ROOT_DIR}/scripts/${module}"
			[ -f "$module_path" ] && [ ! -L "$module_path" ] || {
				printf '%s\n' "installer module not found: $module" >&2
				exit 1
			}
			sed '1{/^#!\/bin\/sh$/d;}' "$module_path"
		done
		if [ "$variable" = ONE_NODE_INSTALL_MODULES ]; then
			printf '%s\n' 'ONE_NODE_INSTALLER_SOURCE=$0' 'export ONE_NODE_INSTALLER_SOURCE'
		fi
		printf '%s\n' 'main "$@"'
	} >"$temporary_path"
	chmod 0755 "$temporary_path"
	sh -n "$temporary_path"
	mv -f -- "$temporary_path" "$output_path"
	trap - EXIT HUP INT TERM
}

install -d -m 0755 "$OUTPUT_DIR"
bundle_entrypoint install.sh ONE_NODE_INSTALL_MODULES install.sh
bundle_entrypoint uninstall.sh ONE_NODE_UNINSTALL_MODULES uninstall.sh
