#!/bin/sh

uninstall_path_kind() {
	case "$1" in
	"$MANIFEST_INSTALL_DIR"|"$MANIFEST_PREVIOUS_DIR") printf '%s\n' directory ;;
	"$MANIFEST_STATE_DIR")
		manifest_has_owned_path "$MANIFEST_STATE_DIR" || return 1
		printf '%s\n' state
		;;
	"$MANIFEST_BINARY_PATH"|"$MANIFEST_PREVIOUS_BINARY_PATH_FIXED"|"$MANIFEST_ENV_PATH"|"$MANIFEST_COMPOSE_PATH"|"$MANIFEST_RECORD_PATH"|"$MANIFEST_UNIT_PATH")
		printf '%s\n' file
		;;
	*) return 1 ;;
	esac
}

preflight_owned_path() {
	owned_path=$1
	[ "$(canonical_path "$owned_path")" = "$owned_path" ] ||
		die "manifest path is not canonical: $owned_path"
	owned_kind=$(uninstall_path_kind "$owned_path") ||
		die "manifest path is outside the One Node allowlist: $owned_path"
	[ ! -L "$owned_path" ] || die "refusing symlink manifest path: $owned_path"
	if [ -e "$owned_path" ]; then
		case "$owned_kind" in
		file) [ -f "$owned_path" ] || die "manifest file has an unsafe type: $owned_path" ;;
		directory|state) [ -d "$owned_path" ] || die "manifest directory has an unsafe type: $owned_path" ;;
		esac
	fi
}

preflight_owned_paths() {
	uninstall_old_ifs=$IFS
	IFS='
'
	for owned_path in $MANIFEST_OWNED_PATHS; do
		preflight_owned_path "$owned_path"
	done
	IFS=$uninstall_old_ifs
}

remove_owned_files() {
	uninstall_old_ifs=$IFS
	IFS='
'
	for owned_path in $MANIFEST_OWNED_PATHS; do
		[ "$owned_path" = "$MANIFEST_RECORD_PATH" ] && continue
		[ "$(uninstall_path_kind "$owned_path")" = file ] || continue
		rm -f -- "$owned_path"
	done
	IFS=$uninstall_old_ifs
	if manifest_has_owned_path "$MANIFEST_STATE_DIR"; then
		rm -rf -- "$MANIFEST_STATE_DIR"
	fi
	rm -f -- "$MANIFEST_RECORD_PATH"
	if manifest_has_owned_path "$MANIFEST_PREVIOUS_DIR"; then
		rmdir -- "$MANIFEST_PREVIOUS_DIR" 2>/dev/null || true
	fi
	rmdir -- "$MANIFEST_INSTALL_DIR" 2>/dev/null || true
}
