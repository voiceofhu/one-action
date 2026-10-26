#!/bin/sh
# Inlines scripts/shared/bootstrap.sh into install.sh, upgrade.sh, and
# uninstall.sh between the generated markers. Piped `curl | sh` entrypoints
# cannot source an unverified file, so the shared bootstrap ships inside each.
#
# Usage: scripts/sync-bootstrap.sh [--check]
set -eu

ROOT_DIR=$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)
SOURCE="${ROOT_DIR}/scripts/shared/bootstrap.sh"
BEGIN_MARKER='# >>> one-node bootstrap: generated from scripts/shared/bootstrap.sh by scripts/sync-bootstrap.sh; edit the source >>>'
END_MARKER='# <<< one-node bootstrap <<<'
CHECK=false
case "${1:-}" in
'') ;;
--check) CHECK=true ;;
*) printf '%s\n' "usage: $0 [--check]" >&2; exit 2 ;;
esac

status=0
for entrypoint in install.sh upgrade.sh uninstall.sh; do
	target="${ROOT_DIR}/${entrypoint}"
	[ "$(grep -cxF "$BEGIN_MARKER" "$target")" = 1 ] &&
		[ "$(grep -cxF "$END_MARKER" "$target")" = 1 ] || {
		printf '%s\n' "${entrypoint}: generated bootstrap markers are missing or duplicated" >&2
		exit 1
	}
	rendered=$(mktemp "${target}.XXXXXX")
	awk -v begin="$BEGIN_MARKER" -v end="$END_MARKER" -v source="$SOURCE" '
		$0 == begin {
			print
			skip_header = 1
			while ((getline line < source) > 0) {
				if (skip_header && (line ~ /^#!/ || line == "")) continue
				skip_header = 0
				print line
			}
			close(source)
			inside = 1
			next
		}
		$0 == end { inside = 0 }
		!inside { print }
	' "$target" >"$rendered"
	if cmp -s "$rendered" "$target"; then
		rm -f -- "$rendered"
		continue
	fi
	if [ "$CHECK" = true ]; then
		rm -f -- "$rendered"
		printf '%s\n' "${entrypoint}: inlined bootstrap is stale; run scripts/sync-bootstrap.sh" >&2
		status=1
		continue
	fi
	chmod 0755 "$rendered"
	sh -n "$rendered"
	mv -f -- "$rendered" "$target"
	printf '%s\n' "updated ${entrypoint}"
done
exit "$status"
