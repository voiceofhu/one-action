#!/bin/sh
# Signed-release chain of trust: entrypoints verify SHA256SUMS.sig with the
# embedded Ed25519 key, then refuse any module that differs from it.
set -eu

ROOT_DIR=$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)
TEST_TEMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/one-node-signing-test.XXXXXX")
trap '[ -n "${KEEP:-}" ] || rm -rf -- "$TEST_TEMP_DIR"' EXIT HUP INT TERM

fail() {
	printf '%s\n' "$*" >&2
	exit 1
}

case "$(openssl version 2>/dev/null)" in
"OpenSSL "[3-9].*|"OpenSSL "[1-9][0-9]*) ;;
*) fail "signing tests require OpenSSL 3 or newer" ;;
esac

"$ROOT_DIR/scripts/sync-bootstrap.sh" --check ||
	fail "entrypoints do not embed scripts/shared/bootstrap.sh"

# The shipped key must be a valid Ed25519 public key.
sed -n "/^ONE_NODE_RELEASE_PUBLIC_KEY='/,/^-----END PUBLIC KEY-----'\$/p" \
	"$ROOT_DIR/scripts/shared/bootstrap.sh" |
	sed -e "s/^ONE_NODE_RELEASE_PUBLIC_KEY='//" -e "s/'\$//" >"$TEST_TEMP_DIR/shipped.pem"
openssl pkey -pubin -in "$TEST_TEMP_DIR/shipped.pem" -noout -text 2>/dev/null |
	grep -F 'ED25519' >/dev/null || fail "embedded release key is not an Ed25519 public key"
shipped_line=$(sed -n '2p' "$TEST_TEMP_DIR/shipped.pem")

# A test copy of the node tree that trusts a throwaway key.
openssl genpkey -algorithm ed25519 -out "$TEST_TEMP_DIR/test.pem" 2>/dev/null
openssl pkey -in "$TEST_TEMP_DIR/test.pem" -pubout -out "$TEST_TEMP_DIR/test.pub.pem"
openssl genpkey -algorithm ed25519 -out "$TEST_TEMP_DIR/other.pem" 2>/dev/null
test_line=$(sed -n '2p' "$TEST_TEMP_DIR/test.pub.pem")
SOURCE="$TEST_TEMP_DIR/source/node"
install -d -m 0755 "$SOURCE"
cp -R "$ROOT_DIR/install.sh" "$ROOT_DIR/upgrade.sh" "$ROOT_DIR/uninstall.sh" "$ROOT_DIR/scripts" "$SOURCE/"
for file in "$SOURCE/install.sh" "$SOURCE/upgrade.sh" "$SOURCE/uninstall.sh" "$SOURCE/scripts/shared/bootstrap.sh"; do
	sed "s|^${shipped_line}\$|${test_line}|" "$file" >"$file.new"
	mv "$file.new" "$file"
	grep -F "$test_line" "$file" >/dev/null || fail "unable to substitute the test key in $file"
done
chmod 0755 "$SOURCE"/*.sh "$SOURCE"/scripts/*.sh

VERSION=1.2.3
COMMIT=0123456789abcdef0123456789abcdef01234567
RELEASE="$TEST_TEMP_DIR/release"
install -d -m 0755 "$RELEASE"
printf '%s\n' amd64 >"$RELEASE/one-node-linux-amd64"
printf '%s\n' arm64 >"$RELEASE/one-node-linux-arm64"
(
	cd "$RELEASE"
	for binary in one-node-linux-amd64 one-node-linux-arm64; do
		printf '%s  %s\n' "$(openssl dgst -sha256 -r "$binary" | awk '{ print $1 }')" "$binary"
	done >SHA256SUMS
)
"$SOURCE/scripts/sign-release.sh" "$RELEASE" "$TEST_TEMP_DIR/test.pem" "$TEST_TEMP_DIR/test.pub.pem" >/dev/null
grep -F '  node/scripts/install/main.sh' "$RELEASE/SHA256SUMS" >/dev/null ||
	fail "signed manifest does not list installer modules"
grep -F '  node/upgrade.sh' "$RELEASE/SHA256SUMS" >/dev/null ||
	fail "signed manifest does not list entrypoints"
if "$SOURCE/scripts/sign-release.sh" "$RELEASE" "$TEST_TEMP_DIR/test.pem" "$TEST_TEMP_DIR/test.pub.pem" >/dev/null 2>&1; then
	fail "release signing appended installer files twice"
fi
cp "$RELEASE/SHA256SUMS" "$TEST_TEMP_DIR/release.SHA256SUMS"
# A secret that does not match the shipped key must fail the release.
install -d -m 0755 "$TEST_TEMP_DIR/mismatch"
cp "$RELEASE/one-node-linux-amd64" "$TEST_TEMP_DIR/mismatch/"
printf '%s  %s\n' 0000000000000000000000000000000000000000000000000000000000000000 one-node-linux-amd64 \
	>"$TEST_TEMP_DIR/mismatch/SHA256SUMS"
if "$SOURCE/scripts/sign-release.sh" "$TEST_TEMP_DIR/mismatch" "$TEST_TEMP_DIR/other.pem" >/dev/null 2>&1; then
	fail "release signing accepted a key that does not match the embedded public key"
fi

FAKE_BIN="$TEST_TEMP_DIR/bin"
install -d -m 0755 "$FAKE_BIN"
cat >"$FAKE_BIN/curl" <<'FAKE_CURL'
#!/bin/sh
set -eu
output=""
url=""
write_out=""
while [ "$#" -gt 0 ]; do
	case "$1" in
	--output) output=$2; shift 2 ;;
	--write-out) write_out=$2; shift 2 ;;
	http://*|https://*) url=$1; shift ;;
	*) shift ;;
	esac
done
printf '%s\n' "$url" >>"$FAKE_CURL_LOG"
emit() {
	if [ -n "$output" ]; then cp "$1" "$output"; else cat "$1"; fi
}
case "$url" in
"https://api.github.com/repos/voiceofhu/one-action/releases?per_page=100")
	printf '%s' '[{"tag_name":"one-node-v1.2.3"},{"tag_name":"one-node-v1.2.0"}]'
	;;
https://api.github.com/repos/voiceofhu/one-action/commits/one-node-v1.2.3)
	printf '%s' "${FAKE_COMMIT_RESPONSE:-$FAKE_COMMIT}" >"$output"
	[ -z "$write_out" ] || printf '%s' 200
	;;
https://github.com/voiceofhu/one-action/releases/download/one-node-v1.2.3/SHA256SUMS)
	emit "$FAKE_RELEASE/SHA256SUMS"
	;;
https://github.com/voiceofhu/one-action/releases/download/one-node-v1.2.3/SHA256SUMS.sig)
	[ "${FAKE_UNSIGNED:-false}" = false ] || exit 22
	emit "$FAKE_RELEASE/SHA256SUMS.sig"
	;;
"https://raw.githubusercontent.com/voiceofhu/one-action/${FAKE_COMMIT}/node/"*)
	relative=${url#*/node/}
	[ -f "$FAKE_SOURCE/$relative" ] || exit 22
	cp "$FAKE_SOURCE/$relative" "$output"
	if [ "${FAKE_TAMPER:-}" = "$relative" ]; then
		printf '%s\n' '# tampered' >>"$output"
	fi
	;;
*) exit 22 ;;
esac
FAKE_CURL
cat >"$FAKE_BIN/id" <<'FAKE_ID'
#!/bin/sh
[ "${1:-}" = -u ] && printf '%s\n' 0
FAKE_ID
chmod 0755 "$FAKE_BIN/curl" "$FAKE_BIN/id"

# Entrypoints run from outside the source tree, like a piped download.
RUN="$TEST_TEMP_DIR/run"
install -d -m 0755 "$RUN"
cp "$SOURCE/install.sh" "$SOURCE/upgrade.sh" "$SOURCE/uninstall.sh" "$RUN/"
export FAKE_CURL_LOG="$TEST_TEMP_DIR/curl.log"
export FAKE_RELEASE="$RELEASE"
export FAKE_SOURCE="$SOURCE"
export FAKE_COMMIT="$COMMIT"
export ONE_NODE_INSTALL_DIR="$TEST_TEMP_DIR/not-installed"

run_entrypoint() {
	: >"$FAKE_CURL_LOG"
	PATH="$FAKE_BIN:$PATH" ONE_NODE_INSTALLER_LIBRARY_ONLY=1 ONE_NODE_UPGRADER_LIBRARY_ONLY=1 \
		ONE_NODE_UNINSTALLER_LIBRARY_ONLY=1 "$@"
}

expect_failure() {
	expected=$1
	shift
	if run_entrypoint "$@" >"$TEST_TEMP_DIR/failure.log" 2>&1; then
		fail "accepted: $*"
	fi
	grep -F "$expected" "$TEST_TEMP_DIR/failure.log" >/dev/null ||
		fail "expected '$expected', got: $(cat "$TEST_TEMP_DIR/failure.log")"
}

# Latest release: the tag commit is resolved, never main, and every module is verified.
run_entrypoint "$RUN/install.sh" >"$TEST_TEMP_DIR/install.log"
grep -F 'using latest published One Node version 1.2.3' "$TEST_TEMP_DIR/install.log" >/dev/null
grep -F 'commits/one-node-v1.2.3' "$FAKE_CURL_LOG" >/dev/null || fail "release tag commit was not resolved"
if grep -F 'commits/main' "$FAKE_CURL_LOG" >/dev/null; then
	fail "installer resolved the moving main branch"
fi
grep -F "one-action/${COMMIT}/node/scripts/install/main.sh" "$FAKE_CURL_LOG" >/dev/null
grep -F "one-action/${COMMIT}/node/install.sh" "$FAKE_CURL_LOG" >/dev/null
grep -F 'one-node-v1.2.3/SHA256SUMS.sig' "$FAKE_CURL_LOG" >/dev/null

# An explicit commit is used as given; the version comes from the command.
run_entrypoint env ONE_ACTION_COMMIT=$COMMIT ONE_NODE_VERSION=$VERSION "$RUN/upgrade.sh"
if grep -F 'api.github.com' "$FAKE_CURL_LOG" >/dev/null; then
	fail "pinned commit and version still queried the GitHub API"
fi
# Uninstall and rollback verify against the installed version.
install -d -m 0700 "$TEST_TEMP_DIR/installed"
printf '%s\n' "current_version=$VERSION" >"$TEST_TEMP_DIR/installed/.installation"
run_entrypoint env ONE_NODE_INSTALL_DIR="$TEST_TEMP_DIR/installed" "$RUN/uninstall.sh"
if grep -F 'releases?per_page' "$FAKE_CURL_LOG" >/dev/null; then
	fail "uninstall ignored the installed version"
fi

expect_failure 'ONE_ACTION_COMMIT must be an exact lowercase commit SHA' \
	env ONE_ACTION_COMMIT=0123456789ABCDEF0123456789ABCDEF01234567 "$RUN/install.sh"
expect_failure 'One Action commit response must be an exact lowercase commit SHA' \
	env FAKE_COMMIT_RESPONSE='{"object":{"sha":"0123456789abcdef0123456789abcdef01234567"}}' "$RUN/install.sh"
expect_failure 'does not match signed release one-node-v1.2.3' \
	env FAKE_TAMPER=scripts/install/files.sh "$RUN/install.sh"
expect_failure 'does not match signed release one-node-v1.2.3' \
	env FAKE_TAMPER=install.sh "$RUN/upgrade.sh"
expect_failure 'release checksums are unsigned' env FAKE_UNSIGNED=true "$RUN/install.sh"
# Development opt-in downgrades a broken chain of trust to a warning.
run_entrypoint env FAKE_UNSIGNED=true ONE_NODE_ALLOW_INSECURE=true "$RUN/install.sh" \
	>"$TEST_TEMP_DIR/insecure.log" 2>&1
grep -F 'warning: release checksums are unsigned' "$TEST_TEMP_DIR/insecure.log" >/dev/null

# A signature from another key, or a modified manifest, is refused.
openssl pkeyutl -sign -inkey "$TEST_TEMP_DIR/other.pem" -rawin \
	-in "$RELEASE/SHA256SUMS" -out "$RELEASE/SHA256SUMS.sig.other"
cp "$RELEASE/SHA256SUMS.sig" "$TEST_TEMP_DIR/good.sig"
cp "$RELEASE/SHA256SUMS.sig.other" "$RELEASE/SHA256SUMS.sig"
expect_failure 'release checksum signature verification failed' "$RUN/install.sh"
cp "$TEST_TEMP_DIR/good.sig" "$RELEASE/SHA256SUMS.sig"
printf '%s\n' "$(printf '%064d' 0)  node/scripts/install/extra.sh" >>"$RELEASE/SHA256SUMS"
expect_failure 'release checksum signature verification failed' "$RUN/install.sh"
cp "$TEST_TEMP_DIR/release.SHA256SUMS" "$RELEASE/SHA256SUMS"

# The persistent manager verifies upgrade.sh before running it.
install -d -m 0700 "$TEST_TEMP_DIR/managed"
printf '%s\n' 'mode=native' "current_version=$VERSION" >"$TEST_TEMP_DIR/managed/.installation"
chmod 0600 "$TEST_TEMP_DIR/managed/.installation"
run_entrypoint env ONE_NODE_INSTALL_DIR="$TEST_TEMP_DIR/managed" "$RUN/install.sh" --upgrade "$VERSION"
grep -F "one-action/${COMMIT}/node/upgrade.sh" "$FAKE_CURL_LOG" >/dev/null
expect_failure 'node/upgrade.sh does not match signed release' \
	env ONE_NODE_INSTALL_DIR="$TEST_TEMP_DIR/managed" FAKE_TAMPER=upgrade.sh "$RUN/install.sh" --upgrade "$VERSION"

# Binary checksums fetched by modules are signature-checked too.
(
	. "$SOURCE/scripts/shared/bootstrap.sh"
	. "$SOURCE/scripts/install/common.sh"
	PATH="$FAKE_BIN:$PATH"
	ONE_NODE_ALLOW_INSECURE=false
	: >"$FAKE_CURL_LOG"
	download_file "https://github.com/voiceofhu/one-action/releases/download/one-node-v1.2.3/SHA256SUMS" \
		"$TEST_TEMP_DIR/binary-sums"
	grep -F 'SHA256SUMS.sig' "$FAKE_CURL_LOG" >/dev/null
)
if (
	. "$SOURCE/scripts/shared/bootstrap.sh"
	. "$SOURCE/scripts/install/common.sh"
	PATH="$FAKE_BIN:$PATH"
	ONE_NODE_ALLOW_INSECURE=false
	FAKE_UNSIGNED=true
	export FAKE_UNSIGNED
	download_file "https://github.com/voiceofhu/one-action/releases/download/one-node-v1.2.3/SHA256SUMS" \
		"$TEST_TEMP_DIR/binary-sums"
) >/dev/null 2>&1; then
	fail "binary checksum download accepted an unsigned release"
fi
if (
	. "$SOURCE/scripts/install/common.sh"
	PATH="$FAKE_BIN:$PATH"
	ONE_NODE_ALLOW_INSECURE=false
	download_file "https://github.com/voiceofhu/one-action/releases/download/one-node-v1.2.3/SHA256SUMS" \
		"$TEST_TEMP_DIR/binary-sums"
) >/dev/null 2>&1; then
	fail "binary checksum download succeeded without a signature verifier"
fi

# The development bundle carries the verifier for its SHA256SUMS downloads.
"$ROOT_DIR/scripts/bundle-dev-installers.sh" "$TEST_TEMP_DIR/dist"
grep -F 'bootstrap_verify_checksums_signature()' "$TEST_TEMP_DIR/dist/install.sh" >/dev/null

printf '%s\n' 'One Node release signing tests passed.'
