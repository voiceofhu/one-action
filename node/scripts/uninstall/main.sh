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
	if manifest_has_owned_path "$MANIFEST_UPDATER_PATH_UNIT_PATH"; then
		systemctl disable --now one-node-updater.path >/dev/null 2>&1 || true
		systemctl stop one-node-updater.service >/dev/null 2>&1 || true
	fi

	if [ "$installed_mode" = "native" ]; then
		uninstall_native
	else
		uninstall_docker
	fi
	remove_owned_files
	command -v systemctl >/dev/null 2>&1 && systemctl daemon-reload || true
	log "One Node sing-box runtime and all runtime state were removed"
}
