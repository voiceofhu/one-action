#!/bin/sh
set -eu

ROOT_DIR=$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)
TEST_TEMP_DIR=$(mktemp -d)
trap 'rm -rf -- "$TEST_TEMP_DIR"' EXIT HUP INT TERM

fail() {
	printf '%s\n' "$*" >&2
	exit 1
}

# shellcheck disable=SC1090
. "$ROOT_DIR/scripts/install/common.sh"
. "$ROOT_DIR/scripts/shared/manifest.sh"
. "$ROOT_DIR/scripts/install/config.sh"
. "$ROOT_DIR/scripts/install/files.sh"
. "$ROOT_DIR/scripts/install/updater.sh"
. "$ROOT_DIR/scripts/install/docker.sh"

curl() {
	printf '%s' "${ONE_NODE_TEST_RELEASE_RESPONSE:-[]}"
}

initialize_install_config
ONE_NODE_TEST_RELEASE_RESPONSE='[{"tag_name":"node-server-v9.9.9"},{"tag_name":"one-node-v26.821.1200"},{"tag_name":"one-node-v26.820.1506"}]'
resolve_latest_node_version
[ "$ONE_NODE_VERSION" = 26.821.1200 ] || fail "latest One Node release was not selected"

curl() {
	fail "explicit One Node version unexpectedly queried GitHub"
}
ONE_NODE_VERSION=1.2.3
resolve_latest_node_version
[ "$ONE_NODE_VERSION" = 1.2.3 ] || fail "explicit One Node version changed"

curl() {
	printf '%s' "${ONE_NODE_TEST_RELEASE_RESPONSE:-[]}"
}

if (
	ONE_NODE_VERSION=
	initialize_install_config
	ONE_NODE_TEST_RELEASE_RESPONSE='[{"tag_name":"node-server-v9.9.9"}]'
	resolve_latest_node_version
) >"$TEST_TEMP_DIR/missing-release.log" 2>&1; then
	fail "latest release resolver accepted a response without One Node"
fi
grep -F 'latest One Node release response did not contain a valid version' \
	"$TEST_TEMP_DIR/missing-release.log" >/dev/null

ONE_NODE_VERSION=
ONE_NODE_DOCKER_IMAGE=
initialize_install_config
INSTALL_MODE=docker
ONE_NODE_SERVER='grpcs://control.example.test:443'
ONE_NODE_ID=41
ONE_NODE_BOOTSTRAP_TOKEN=bootstrap-fixture
ONE_NODE_TEST_RELEASE_RESPONSE='[{"tag_name":"one-node-v26.821.1200"}]'
validate_install_config
[ "$ONE_NODE_VERSION" = 26.821.1200 ] ||
	fail "Docker install did not resolve the latest One Node version"
[ "$ONE_NODE_DOCKER_IMAGE" = 'ghcr.io/voiceofhu/one-node:26.821.1200' ] ||
	fail "Docker install did not default to the selected version tag"

systemctl() {
	:
}
docker() {
	case "$1:${2:-}" in
	info:|compose:version|pull:*) ;;
	image:inspect)
		printf '%s\n' 'ghcr.io/voiceofhu/one-node@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
		;;
	run:*) printf '%s\n' 26.821.1200 ;;
	*) fail "unexpected Docker fixture command: $*" ;;
	esac
}
prepare_docker_image
[ "$ONE_NODE_DOCKER_IMAGE" = 'ghcr.io/voiceofhu/one-node@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' ] ||
	fail "Docker install did not retain the resolved immutable digest"
