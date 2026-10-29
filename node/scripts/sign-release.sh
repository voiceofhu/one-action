#!/bin/sh
# Appends the installer files of this checkout to DIST_DIR/SHA256SUMS and
# signs the result twice: Ed25519 (DIST_DIR/SHA256SUMS.sig, the primary
# signature) and RSA PKCS#1 v1.5 SHA-256 (DIST_DIR/SHA256SUMS.rsa.sig, for
# macOS LibreSSL and Windows PowerShell, which cannot verify Ed25519).
# Each signature is checked against the public key the installers embed
# (scripts/shared/bootstrap.sh; install.ps1 carries the same RSA key), or the
# PUBLIC_KEY_FILE / RSA_PUBLIC_KEY_FILE in tests, before it is kept, so a
# release secret that does not match the shipped key fails the release.
#
# Usage: scripts/sign-release.sh DIST_DIR PRIVATE_KEY_FILE RSA_PRIVATE_KEY_FILE \
#          [PUBLIC_KEY_FILE [RSA_PUBLIC_KEY_FILE]]
# Requires OpenSSL 3 or newer (pkeyutl -rawin).
set -eu

[ "$#" -ge 3 ] && [ "$#" -le 5 ] || {
	printf '%s\n' "usage: $0 DIST_DIR PRIVATE_KEY_FILE RSA_PRIVATE_KEY_FILE [PUBLIC_KEY_FILE [RSA_PUBLIC_KEY_FILE]]" >&2
	exit 2
}
NODE_DIR=$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)
DIST_DIR=$1
PRIVATE_KEY_FILE=$2
RSA_PRIVATE_KEY_FILE=$3
PUBLIC_KEY_FILE=${4:-}
RSA_PUBLIC_KEY_FILE=${5:-}
SUMS="${DIST_DIR}/SHA256SUMS"

fail() {
	printf '%s\n' "sign-release: $*" >&2
	exit 1
}

[ -s "$SUMS" ] || fail "${SUMS} must already list the release binaries"
[ -f "$PRIVATE_KEY_FILE" ] || fail "private key file is missing"
[ -f "$RSA_PRIVATE_KEY_FILE" ] || fail "RSA private key file is missing"
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
		printf '%s\n' node/install.sh node/install.ps1 node/upgrade.sh node/uninstall.sh
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

openssl dgst -sha256 -sign "$RSA_PRIVATE_KEY_FILE" -out "${SUMS}.rsa.sig" "$SUMS"

# Prints the PEM assigned to shell variable $1 in the shared bootstrap.
embedded_key() {
	awk -v name="$1" '
		index($0, name "=\x27") == 1 { inside = 1; sub("^" name "=\x27", "") }
		inside { line = $0; if (sub(/\x27$/, "", line)) { print line; exit } ; print line }
	' "${NODE_DIR}/scripts/shared/bootstrap.sh"
}

if [ -z "$PUBLIC_KEY_FILE" ]; then
	PUBLIC_KEY_FILE="${work_dir}/public.pem"
	embedded_key ONE_NODE_RELEASE_PUBLIC_KEY >"$PUBLIC_KEY_FILE"
fi
if [ -z "$RSA_PUBLIC_KEY_FILE" ]; then
	RSA_PUBLIC_KEY_FILE="${work_dir}/rsa-public.pem"
	embedded_key ONE_NODE_RELEASE_RSA_PUBLIC_KEY >"$RSA_PUBLIC_KEY_FILE"
	# install.ps1 embeds the same key as a bare modulus.
	modulus_hex=$(openssl rsa -pubin -in "$RSA_PUBLIC_KEY_FILE" -noout -modulus 2>/dev/null | sed 's/^Modulus=//')
	modulus=$(perl -e 'print pack("H*", $ARGV[0])' "$modulus_hex" | openssl base64 -A)
	[ -n "$modulus_hex" ] && [ -n "$modulus" ] || fail "unable to read the embedded RSA release public key"
	grep -Fq "$modulus" "${NODE_DIR}/install.ps1" ||
		fail "install.ps1 does not embed the RSA release public key of the shared bootstrap"
fi
openssl pkeyutl -verify -pubin -inkey "$PUBLIC_KEY_FILE" -rawin \
	-in "$SUMS" -sigfile "${SUMS}.sig" >/dev/null ||
	fail "signature does not verify with the embedded release public key"
openssl dgst -sha256 -verify "$RSA_PUBLIC_KEY_FILE" -signature "${SUMS}.rsa.sig" "$SUMS" >/dev/null ||
	fail "RSA signature does not verify with the embedded RSA release public key"
printf '%s\n' "signed $(wc -l <"$SUMS" | tr -d ' ') entries in ${SUMS}"
