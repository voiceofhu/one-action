#!/bin/sh
set -eu

ROOT_DIR=$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)
TEST_TEMP_DIR=$(mktemp -d)
trap 'rm -rf -- "$TEST_TEMP_DIR"' EXIT HUP INT TERM

INSTALL_MODULES="install/common.sh shared/manifest.sh install/config.sh install/host.sh install/files.sh install/native.sh install/native_reconfigure.sh install/docker.sh install/readiness.sh install/main.sh"
UNINSTALL_MODULES="install/common.sh uninstall/common.sh shared/manifest.sh uninstall/paths.sh uninstall/native.sh uninstall/docker.sh uninstall/main.sh"
UPGRADE_MODULES="install/common.sh shared/manifest.sh install/host.sh install/files.sh install/docker.sh install/readiness.sh upgrade/common.sh upgrade/manifest.sh upgrade/native.sh upgrade/docker.sh upgrade/rollback.sh upgrade/main.sh"

for entrypoint in install.sh uninstall.sh upgrade.sh; do
	sh -n "$ROOT_DIR/$entrypoint"
	grep -F 'https://raw.githubusercontent.com/voiceofhu/one-action/${ONE_ACTION_COMMIT}/node/scripts' \
		"$ROOT_DIR/$entrypoint" >/dev/null
	grep -F 'https://api.github.com/repos/voiceofhu/one-action/commits/main' \
		"$ROOT_DIR/$entrypoint" >/dev/null
	grep -F 'Accept: application/vnd.github.sha' "$ROOT_DIR/$entrypoint" >/dev/null
done
grep -F 'https://github.com/voiceofhu/one-action/releases/download/one-node-v${ONE_NODE_VERSION}' \
	"$ROOT_DIR/scripts/install/config.sh" >/dev/null
grep -F 'https://api.github.com/repos/voiceofhu/one-action/releases?per_page=100' \
	"$ROOT_DIR/scripts/install/config.sh" >/dev/null
if grep -R -F 'voiceofhu/one-node-node/releases' "$ROOT_DIR/scripts" >/dev/null; then
	printf '%s\n' "Node lifecycle points public downloads at the private source repository" >&2
	exit 1
fi
grep -F 'https://raw.githubusercontent.com/voiceofhu/one-action/${action_commit}/node/uninstall.sh' \
	"$ROOT_DIR/scripts/install/host.sh" >/dev/null
if grep -R -F 'voiceofhu/one-node-action' \
	"$ROOT_DIR/install.sh" "$ROOT_DIR/upgrade.sh" "$ROOT_DIR/uninstall.sh" \
	"$ROOT_DIR/scripts" >/dev/null; then
	printf '%s\n' "Node lifecycle still uses the legacy Action repository" >&2
	exit 1
fi
"$ROOT_DIR/scripts/bundle-dev-installers.sh" "$TEST_TEMP_DIR/dist"
sh -n "$TEST_TEMP_DIR/dist/install.sh" "$TEST_TEMP_DIR/dist/uninstall.sh"
grep -F 'INSTALL_DIR="/opt/one-node"' "$TEST_TEMP_DIR/dist/install.sh" >/dev/null
if grep -E '/opt/one-node-node|one-node-node\.service|manifest_load_legacy' \
	"$TEST_TEMP_DIR/dist/install.sh" >/dev/null; then
	printf '%s\n' "bundled installer contains removed legacy support" >&2
	exit 1
fi
for module in $(printf '%s\n' "$INSTALL_MODULES $UNINSTALL_MODULES $UPGRADE_MODULES" | tr ' ' '\n' | sort -u); do
	sh -n "$ROOT_DIR/scripts/$module"
done

# The permission reader supports the host's GNU or BSD stat variant.
# shellcheck disable=SC1090
. "$ROOT_DIR/scripts/install/common.sh"
mode_fixture="$TEST_TEMP_DIR/mode-fixture"
: >"$mode_fixture"
chmod 0600 "$mode_fixture"
[ "$(file_mode "$mode_fixture")" = "600" ]

canonical_fixture="$TEST_TEMP_DIR/not-created/child"
[ "$(canonical_path "$canonical_fixture")" = "$canonical_fixture" ]
[ "$(canonical_path "$TEST_TEMP_DIR/./child")" = "$TEST_TEMP_DIR/child" ]
for unsafe_path in relative/path "$TEST_TEMP_DIR//child" "$TEST_TEMP_DIR/../child"; do
	if canonical_path "$unsafe_path" >/dev/null; then
		printf '%s\n' "unsafe path was accepted: $unsafe_path" >&2
		exit 1
	fi
done

"$ROOT_DIR/install.sh" --help | grep -F "native" >/dev/null
"$ROOT_DIR/install.sh" --help | grep -F "docker" >/dev/null
"$ROOT_DIR/uninstall.sh" --help | grep -F "native" >/dev/null
"$ROOT_DIR/uninstall.sh" --help | grep -F "docker" >/dev/null
"$ROOT_DIR/upgrade.sh" --help | grep -F "roll back" >/dev/null

if "$ROOT_DIR/install.sh" --mode package >/dev/null 2>&1; then
	printf '%s\n' "installer accepted an unsupported mode" >&2
	exit 1
fi
if "$ROOT_DIR/uninstall.sh" --mode package >/dev/null 2>&1; then
	printf '%s\n' "uninstaller accepted an unsupported mode" >&2
	exit 1
fi
for module in install uninstall upgrade; do
	if sh "$ROOT_DIR/scripts/$module/main.sh" \
		>"$TEST_TEMP_DIR/standalone-$module.log" 2>&1; then
		printf '%s\n' "$module main module ran without its public loader" >&2
		exit 1
	fi
	grep -F "must be loaded through $module.sh" \
		"$TEST_TEMP_DIR/standalone-$module.log" >/dev/null
done

install -d -m 0755 "$TEST_TEMP_DIR/bin"
cat >"$TEST_TEMP_DIR/bin/curl" <<'FAKE_CURL'
#!/bin/sh
set -eu
output=""
url=""
write_out=""
while [ "$#" -gt 0 ]; do
	case "$1" in
	--output)
		output=$2
		shift 2
		;;
	--write-out)
		write_out=$2
		shift 2
		;;
	http://*|https://*)
		url=$1
		shift
		;;
	*) shift ;;
	esac
done
[ -n "$output" ] && [ -n "$url" ]
case "$url" in
https://api.github.com/repos/voiceofhu/one-action/commits/main)
	printf '%s' "${ONE_NODE_TEST_ACTION_RESPONSE:-0123456789abcdef0123456789abcdef01234567}" >"$output"
	[ -z "$write_out" ] || printf '%s' 200
	;;
*)
	relative=${url#*scripts/}
	source_file="${ONE_NODE_TEST_ROOT}/scripts/${relative}"
	[ -f "$source_file" ]
	cp "$source_file" "$output"
	;;
esac
FAKE_CURL
chmod 0755 "$TEST_TEMP_DIR/bin/curl"

export ONE_NODE_TEST_ROOT="$ROOT_DIR"
TEST_ACTION_COMMIT=0123456789abcdef0123456789abcdef01234567
for entrypoint in install.sh uninstall.sh upgrade.sh; do
	cp "$ROOT_DIR/$entrypoint" "$TEST_TEMP_DIR/$entrypoint"
	chmod 0755 "$TEST_TEMP_DIR/$entrypoint"
	PATH="$TEST_TEMP_DIR/bin:$PATH" \
		ONE_NODE_ALLOW_INSECURE=true \
		ONE_NODE_SCRIPT_BASE_URL="http://127.0.0.1:9999/scripts" \
		"$TEST_TEMP_DIR/$entrypoint" --help >/dev/null
	PATH="$TEST_TEMP_DIR/bin:$PATH" \
		ONE_ACTION_COMMIT="$TEST_ACTION_COMMIT" \
		"$TEST_TEMP_DIR/$entrypoint" --help >/dev/null
	PATH="$TEST_TEMP_DIR/bin:$PATH" \
		"$TEST_TEMP_DIR/$entrypoint" --help >/dev/null
	if PATH="$TEST_TEMP_DIR/bin:$PATH" \
		ONE_ACTION_COMMIT=0123456789ABCDEF0123456789ABCDEF01234567 \
		"$TEST_TEMP_DIR/$entrypoint" --help >/dev/null 2>&1; then
		printf '%s\n' "$entrypoint accepted a non-lowercase Action commit" >&2
		exit 1
	fi
done

if PATH="$TEST_TEMP_DIR/bin:$PATH" \
	ONE_NODE_TEST_ACTION_RESPONSE='{"object":{"sha":"0123456789abcdef0123456789abcdef01234567"}}' \
	"$TEST_TEMP_DIR/install.sh" --help >"$TEST_TEMP_DIR/invalid-commit-response.log" 2>&1; then
	printf '%s\n' "installer accepted a JSON commit response" >&2
	exit 1
fi
grep -F 'One Action commit response must be an exact lowercase commit SHA' \
	"$TEST_TEMP_DIR/invalid-commit-response.log" >/dev/null

grep -F 'MANIFEST_FORMAT_NAME="one-node-manifest"' \
	"$ROOT_DIR/scripts/shared/manifest.sh" >/dev/null
grep -F 'MANIFEST_RECORD_PATH="${MANIFEST_INSTALL_DIR}/.installation"' \
	"$ROOT_DIR/scripts/shared/manifest.sh" >/dev/null
grep -F 'version --product-name' "$ROOT_DIR/scripts/install/files.sh" >/dev/null
if grep -F 'version --name' "$ROOT_DIR/scripts/install/files.sh" >/dev/null; then
	fail "native installer still reads the sing-box core version as its product release"
fi
grep -F 'version --product-name' "$ROOT_DIR/scripts/install/docker.sh" >/dev/null
if grep -F 'version --name' "$ROOT_DIR/scripts/install/docker.sh" >/dev/null; then
	fail "Docker installer still reads the sing-box core version as its product release"
fi
grep -F 'INSTALL_MANIFEST_KIND="missing"' \
	"$ROOT_DIR/scripts/install/host.sh" >/dev/null
grep -F 'INSTALL_DIR="/opt/one-node"' "$ROOT_DIR/scripts/install/config.sh" >/dev/null
grep -F 'UNIT_FILE="/etc/systemd/system/one-node.service"' \
	"$ROOT_DIR/scripts/install/config.sh" >/dev/null
if grep -R -E '/opt/one-node-node|one-node-node\.service' \
	"$ROOT_DIR/scripts/install" >/dev/null; then
	fail "installer still references the pre-rename runtime layout"
fi
(
	# shellcheck disable=SC1090
	. "$ROOT_DIR/scripts/shared/manifest.sh"
	# shellcheck disable=SC1090
	. "$ROOT_DIR/scripts/install/files.sh"
	ONE_NODE_VERSION=""
	set_product_version 26.809.2200 fixture
	[ "$ONE_NODE_VERSION" = 26.809.2200 ]
)
if (
	# shellcheck disable=SC1090
	. "$ROOT_DIR/scripts/shared/manifest.sh"
	# shellcheck disable=SC1090
	. "$ROOT_DIR/scripts/install/files.sh"
	ONE_NODE_VERSION="26.809.2200"
	set_product_version 1.13.18 fixture
) >/dev/null 2>&1; then
	printf '%s\n' "installer accepted the sing-box core version as the One Node product release" >&2
	exit 1
fi
grep -F 'rm -rf -- "$MANIFEST_STATE_DIR"' \
	"$ROOT_DIR/scripts/uninstall/paths.sh" >/dev/null
if grep -R -E 'apt-get purge|docker system prune|docker (rm|rmi).*(xray|Xray)' \
	"$ROOT_DIR/scripts/uninstall" >/dev/null; then
	printf '%s\n' "uninstaller manages software outside its manifest" >&2
	exit 1
fi
