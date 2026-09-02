#!/bin/sh
set -eu

ROOT_DIR=$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)
TEST_TEMP_DIR=$(mktemp -d)
trap 'rm -rf -- "$TEST_TEMP_DIR"' EXIT HUP INT TERM

INSTALL_MODULES="install/common.sh shared/manifest.sh uninstall/paths.sh uninstall/native.sh uninstall/docker.sh install/config.sh install/host.sh install/files.sh install/updater.sh install/firewall.sh install/tuning.sh install/native.sh install/native_reconfigure.sh install/docker.sh install/readiness.sh install/main.sh"
UNINSTALL_MODULES="install/common.sh install/firewall.sh uninstall/common.sh shared/manifest.sh uninstall/paths.sh uninstall/native.sh uninstall/docker.sh uninstall/main.sh"
UPGRADE_MODULES="install/common.sh shared/manifest.sh install/host.sh install/files.sh install/updater.sh install/firewall.sh install/tuning.sh install/docker.sh install/readiness.sh upgrade/common.sh upgrade/manifest.sh upgrade/native.sh upgrade/docker.sh upgrade/rollback.sh upgrade/main.sh"

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
. "$ROOT_DIR/scripts/shared/manifest.sh"
. "$ROOT_DIR/scripts/install/firewall.sh"
mode_fixture="$TEST_TEMP_DIR/mode-fixture"
: >"$mode_fixture"
chmod 0600 "$mode_fixture"
[ "$(file_mode "$mode_fixture")" = "600" ]

historical_manifest="$TEST_TEMP_DIR/historical-installation"
printf '%s\n' \
	'format=one-node-manifest' \
	'mode=native' \
	'state_dir=/var/lib/one-node' \
	'desired_config_revision=3' \
	'desired_bindings_revision=8' \
	'current_version=26.824.1500' \
	'current_binary_path=/opt/one-node/one-node' \
	'current_binary_sha256=0000000000000000000000000000000000000000000000000000000000000000' \
	'current_image=' \
	'previous_version=' \
	'previous_binary_path=' \
	'previous_binary_sha256=' \
	'previous_image=' \
	'owned_path=/opt/one-node' \
	'owned_path=/opt/one-node/.env' \
	'owned_path=/opt/one-node/.installation' \
	'owned_path=/opt/one-node/one-node' \
	'owned_path=/etc/systemd/system/one-node.service' >"$historical_manifest"
chmod 0600 "$historical_manifest"
manifest_load "$historical_manifest"
[ "$MANIFEST_HISTORICAL_BINDINGS_REVISION" = 8 ]
manifest_write "$historical_manifest"
if grep -q '^desired_bindings_revision=' "$historical_manifest"; then
	printf '%s\n' 'historical bindings revision was not removed during manifest migration' >&2
	exit 1
fi

upgrade_installer="$TEST_TEMP_DIR/upgrade-install.sh"
: >"$upgrade_installer"
chmod 0700 "$upgrade_installer"
(
	# shellcheck disable=SC1090
	. "$ROOT_DIR/scripts/upgrade/common.sh"
	ONE_NODE_INSTALLER_SOURCE=$upgrade_installer
	initialize_upgrade
	[ "$TEMP_DIR" = "$UPGRADE_TEMP_DIR" ]
	[ "$BINARY_SOURCE" = "${TEMP_DIR}/one-node.download" ]
)

canonical_fixture="$TEST_TEMP_DIR/not-created/child"
[ "$(canonical_path "$canonical_fixture")" = "$canonical_fixture" ]
[ "$(canonical_path "$TEST_TEMP_DIR/./child")" = "$TEST_TEMP_DIR/child" ]
for unsafe_path in relative/path "$TEST_TEMP_DIR//child" "$TEST_TEMP_DIR/../child"; do
	if canonical_path "$unsafe_path" >/dev/null; then
		printf '%s\n' "unsafe path was accepted: $unsafe_path" >&2
		exit 1
	fi
done

check_host_architecture() (
	machine_architecture=$1
	expected_architecture=$2
	expected_checksum=$3
	# shellcheck disable=SC1090
	. "$ROOT_DIR/scripts/install/host.sh"
	uname() {
		case "${1:-}" in
		-s) printf '%s\n' Linux ;;
		-m) printf '%s\n' "$machine_architecture" ;;
		*) return 1 ;;
		esac
	}
	ONE_NODE_BINARY_SHA256_AMD64=amd64-checksum
	ONE_NODE_BINARY_SHA256_ARM64=arm64-checksum
	resolve_host_architecture
	[ "$ONE_NODE_ARCH" = "$expected_architecture" ]
	[ "$ONE_NODE_BINARY_SHA256" = "$expected_checksum" ]
	[ "$ONE_NODE_BINARY_NAME" = "one-node-linux-${expected_architecture}" ]
)

check_host_architecture x86_64 amd64 amd64-checksum
check_host_architecture amd64 amd64 amd64-checksum
check_host_architecture aarch64 arm64 arm64-checksum
check_host_architecture arm64 arm64 arm64-checksum
if check_host_architecture ppc64le unsupported unused >"$TEST_TEMP_DIR/unsupported-architecture.log" 2>&1; then
	printf '%s\n' "installer accepted an unsupported Linux architecture" >&2
	exit 1
fi
grep -F 'only Linux amd64 and arm64 are supported' \
	"$TEST_TEMP_DIR/unsupported-architecture.log" >/dev/null

check_linux_host() (
	host_os=$1
	# shellcheck disable=SC1090
	. "$ROOT_DIR/scripts/install/host.sh"
	id() {
		[ "${1:-}" = -u ] || return 1
		printf '%s\n' 0
	}
	uname() {
		case "${1:-}" in
		-s) printf '%s\n' "$host_os" ;;
		-m) printf '%s\n' x86_64 ;;
		*) return 1 ;;
		esac
	}
	systemctl() { :; }
	nft() { :; }
	sha256sum() { :; }
	INSTALL_MODE=native
	ONE_NODE_BINARY_SHA256_AMD64=amd64-checksum
	ONE_NODE_BINARY_SHA256_ARM64=arm64-checksum
	validate_install_host
)

check_linux_host Linux
if check_linux_host Darwin >"$TEST_TEMP_DIR/unsupported-os.log" 2>&1; then
	printf '%s\n' "installer accepted a non-Linux host" >&2
	exit 1
fi
grep -F 'only Linux is supported' "$TEST_TEMP_DIR/unsupported-os.log" >/dev/null
if grep -R -E '/etc/os-release|only Debian|dpkg' \
	"$ROOT_DIR/scripts/install/host.sh" "$ROOT_DIR/scripts/upgrade/common.sh" >/dev/null; then
	printf '%s\n' "installer lifecycle still depends on a Debian host" >&2
	exit 1
fi

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
*/install.sh)
	cp "${ONE_NODE_TEST_ROOT}/install.sh" "$output"
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
grep -F 'persist_management_installer' "$ROOT_DIR/upgrade.sh" >/dev/null
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
	. "$ROOT_DIR/scripts/install/updater.sh"
	ONE_NODE_VERSION=""
	set_product_version 26.809.2200 fixture
	[ "$ONE_NODE_VERSION" = 26.809.2200 ]
)
if (
	# shellcheck disable=SC1090
	. "$ROOT_DIR/scripts/shared/manifest.sh"
	# shellcheck disable=SC1090
	. "$ROOT_DIR/scripts/install/files.sh"
	. "$ROOT_DIR/scripts/install/updater.sh"
	ONE_NODE_VERSION="26.809.2200"
	set_product_version 1.13.18 fixture
) >/dev/null 2>&1; then
	printf '%s\n' "installer accepted the sing-box core version as the One Node product release" >&2
	exit 1
fi

(
	# Native management upgrades derive the immutable Release URL and checksum file from only the version.
	# shellcheck disable=SC1090
	. "$ROOT_DIR/scripts/shared/manifest.sh"
	. "$ROOT_DIR/scripts/install/host.sh"
	. "$ROOT_DIR/scripts/upgrade/common.sh"
	INSTALL_MODE=native
	ONE_NODE_VERSION=26.824.1520
	ONE_NODE_RELEASE_BASE_URL=""
	ONE_NODE_BINARY_SHA256_AMD64=""
	ONE_NODE_BINARY_SHA256_ARM64=""
	ONE_NODE_DOCKER_IMAGE=""
	ONE_NODE_ALLOW_INSECURE=false
	MANIFEST_CURRENT_VERSION=26.824.1510
	MANIFEST_CURRENT_BINARY_SHA256=$(printf '%064d' 1)
	validate_upgrade_target
	[ "$ONE_NODE_RELEASE_BASE_URL" = "https://github.com/voiceofhu/one-action/releases/download/one-node-v26.824.1520" ]
	case "$(uname -m)" in x86_64|amd64) expected_arch=amd64 ;; *) expected_arch=arm64 ;; esac
	[ "$ONE_NODE_BINARY_URL" = "${ONE_NODE_RELEASE_BASE_URL}/one-node-linux-${expected_arch}" ]
)
(
	# Docker management upgrades accept the version tag and resolve its immutable digest during staging.
	# shellcheck disable=SC1090
	. "$ROOT_DIR/scripts/shared/manifest.sh"
	. "$ROOT_DIR/scripts/install/host.sh"
	. "$ROOT_DIR/scripts/upgrade/common.sh"
	INSTALL_MODE=docker
	ONE_NODE_VERSION=26.824.1520
	ONE_NODE_RELEASE_BASE_URL=""
	ONE_NODE_BINARY_SHA256_AMD64=""
	ONE_NODE_BINARY_SHA256_ARM64=""
	ONE_NODE_DOCKER_IMAGE=""
	ONE_NODE_ALLOW_INSECURE=false
	MANIFEST_CURRENT_VERSION=26.824.1510
	MANIFEST_CURRENT_IMAGE="ghcr.io/voiceofhu/one-node@sha256:$(printf '%064d' 2)"
	validate_upgrade_target
	[ "$ONE_NODE_DOCKER_IMAGE" = "ghcr.io/voiceofhu/one-node:26.824.1520" ]
)
grep -F 'rm -rf -- "$MANIFEST_STATE_DIR"' \
	"$ROOT_DIR/scripts/uninstall/paths.sh" >/dev/null
if grep -R -F 'pre-existing state retained' \
	"$ROOT_DIR/uninstall.sh" "$ROOT_DIR/scripts/uninstall" >/dev/null; then
	printf '%s\n' "uninstaller still retains pre-existing One Node state" >&2
	exit 1
fi
(
	# A state directory that predates the installation is absent from the
	# owned-path list, but uninstall must still validate and remove it.
	# shellcheck disable=SC1090
	. "$ROOT_DIR/scripts/shared/manifest.sh"
	# shellcheck disable=SC1090
	. "$ROOT_DIR/scripts/uninstall/paths.sh"
	MANIFEST_INSTALL_DIR="$TEST_TEMP_DIR/uninstall-all/opt/one-node"
	MANIFEST_PREVIOUS_DIR="$MANIFEST_INSTALL_DIR/previous"
	MANIFEST_BINARY_PATH="$MANIFEST_INSTALL_DIR/one-node"
	MANIFEST_PREVIOUS_BINARY_PATH_FIXED="$MANIFEST_PREVIOUS_DIR/one-node"
	MANIFEST_ENV_PATH="$MANIFEST_INSTALL_DIR/.env"
	MANIFEST_COMPOSE_PATH="$MANIFEST_INSTALL_DIR/docker-compose.yml"
	MANIFEST_RECORD_PATH="$MANIFEST_INSTALL_DIR/.installation"
	MANIFEST_UNIT_PATH="$TEST_TEMP_DIR/uninstall-all/one-node.service"
	MANIFEST_STATE_DIR="$TEST_TEMP_DIR/uninstall-all/var/lib/one-node"
	MANIFEST_OWNED_PATHS="${MANIFEST_INSTALL_DIR}
${MANIFEST_ENV_PATH}
${MANIFEST_RECORD_PATH}
${MANIFEST_BINARY_PATH}
${MANIFEST_UNIT_PATH}"
	install -d -m 0755 "$MANIFEST_INSTALL_DIR"
	install -d -m 0700 "$MANIFEST_STATE_DIR/traffic-spool"
	: >"$MANIFEST_ENV_PATH"
	: >"$MANIFEST_RECORD_PATH"
	: >"$MANIFEST_BINARY_PATH"
	: >"$MANIFEST_UNIT_PATH"
	: >"$MANIFEST_STATE_DIR/node-secret"
	: >"$MANIFEST_STATE_DIR/traffic-spool/pending.jsonl"
	preflight_owned_paths
	remove_owned_files
	[ ! -e "$MANIFEST_STATE_DIR" ]
)
if grep -R -E 'apt-get purge|docker system prune|docker (rm|rmi).*(xray|Xray)' \
	"$ROOT_DIR/scripts/uninstall" >/dev/null; then
	printf '%s\n' "uninstaller manages software outside its manifest" >&2
	exit 1
fi
