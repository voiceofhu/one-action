#!/bin/sh

if ! command -v initialize_uninstall_config >/dev/null 2>&1; then
	printf '%s\n' \
		"[one-node] error: uninstaller main module must be loaded through uninstall.sh" >&2
	exit 1
fi

main() {
	umask 077
	initialize_uninstall_config
	parse_uninstall_arguments "$@"
	[ "$(id -u)" -eq 0 ] || die "run this uninstaller as root"
	command -v stat >/dev/null 2>&1 ||
		die "stat is required (install coreutils)"
	if ! load_installation; then
		return 0
	fi
	preflight_owned_paths

	if [ "$installed_mode" = "native" ]; then
		uninstall_native
	else
		uninstall_docker
	fi
	remove_owned_files
	if manifest_has_owned_path "$state_dir"; then
		log "One Node sing-box runtime and installer-owned state were removed"
	else
		log "One Node sing-box runtime was uninstalled; pre-existing state retained at ${state_dir}"
	fi
}
