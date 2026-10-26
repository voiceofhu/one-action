#!/bin/sh
# Appends the installer files of this checkout to DIST_DIR/SHA256SUMS and
# signs the result with an Ed25519 key, writing DIST_DIR/SHA256SUMS.sig.
# The signature is checked against the public key embedded in
# scripts/shared/bootstrap.sh (or PUBLIC_KEY_FILE in tests) before it is kept,
# so a release secret that does not match the shipped key fails the release.
#
# Usage: scripts/sign-release.sh DIST_DIR PRIVATE_KEY_FILE [PUBLIC_KEY_FILE]
# Requires OpenSSL 3 or newer (pkeyutl -rawin).
set -eu

[ "$#" -ge 2 ] && [ "$#" -le 3 ] || {
	printf '%s\n' "usage: $0 DIST_DIR PRIVATE_KEY_FILE [PUBLIC_KEY_FILE]" >&2
	exit 2
}
NODE_DIR=$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)
DIST_DIR=$1
PRIVATE_KEY_FILE=$2
PUBLIC_KEY_FILE=${3:-}
SUMS="${DIST_DIR}/SHA256SUMS"

fail() {
	printf '%s\n' "sign-release: $*" >&2
	exit 1
}

[ -s "$SUMS" ] || fail "${SUMS} must already list the release binaries"
[ -f "$PRIVATE_KEY_FILE" ] || fail "private key file is missing"
case "$(openssl version 2>/dev/null)" in
"OpenSSL "[3-9].*|"OpenSSL "[1-9][0-9]*) ;;
*) fail "OpenSSL 3 or newer is required" ;;
esac
grep -q ' node/' "$SUMS" && fail "${SUMS} already lists installer files"
"${NODE_DIR}/scripts/sync-bootstrap.sh" --check ||
	fail "entrypoints do not embed the current shared bootstrap"

sha256() {
	if command -v sha256sum >/dev/null 2>&1; then
		sha256sum "$1" | awk '{ print $1 }'
	else
		shasum -a 256 "$1" | awk '{ print $1 }'
	fi
}

work_dir=$(mktemp -d "${TMPDIR:-/tmp}/one-node-sign.XXXXXX")
trap 'rm -rf -- "$work_dir"' EXIT HUP INT TERM

# Paths are relative to the One Action root, e.g. node/scripts/install/main.sh.
(
	cd "${NODE_DIR}/.."
	{
		printf '%s\n' node/install.sh node/upgrade.sh node/uninstall.sh
		find node/scripts -type f -name '*.sh'
	} | LC_ALL=C sort
) >"${work_dir}/files"
while IFS= read -r path; do
	case "$path" in
	*[!A-Za-z0-9._/-]*) fail "unexpected installer path: $path" ;;
	esac
	printf '%s  %s\n' "$(sha256 "${NODE_DIR}/../${path}")" "$path"
done <"${work_dir}/files" >>"$SUMS"

openssl pkeyutl -sign -inkey "$PRIVATE_KEY_FILE" -rawin \
	-in "$SUMS" -out "${SUMS}.sig"

if [ -z "$PUBLIC_KEY_FILE" ]; then
	PUBLIC_KEY_FILE="${work_dir}/public.pem"
	awk '
		/^ONE_NODE_RELEASE_PUBLIC_KEY=/ { inside = 1; sub(/^ONE_NODE_RELEASE_PUBLIC_KEY=\x27/, "") }
		inside { line = $0; if (sub(/\x27$/, "", line)) { print line; exit } ; print line }
	' "${NODE_DIR}/scripts/shared/bootstrap.sh" >"$PUBLIC_KEY_FILE"
fi
openssl pkeyutl -verify -pubin -inkey "$PUBLIC_KEY_FILE" -rawin \
	-in "$SUMS" -sigfile "${SUMS}.sig" >/dev/null ||
	fail "signature does not verify with the embedded release public key"
printf '%s\n' "signed $(wc -l <"$SUMS" | tr -d ' ') entries in ${SUMS}"
