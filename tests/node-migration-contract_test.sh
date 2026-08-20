#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
CALLER="$PROJECT_ROOT/.github/workflows/node.yml"
BUILD="$PROJECT_ROOT/.github/workflows/reusable-build-node.yml"
DISPATCHER="$PROJECT_ROOT/scripts/github/dispatch-workflow.sh"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

require_text() {
  local file=$1 text=$2
  grep -Fq -- "$text" "$file" || fail "missing One Node contract in ${file##*/}: $text"
}

for entrypoint in install.sh upgrade.sh uninstall.sh; do
  [[ -f "$PROJECT_ROOT/node/$entrypoint" ]] ||
    fail "missing namespaced Node entrypoint: node/$entrypoint"
  [[ ! -e "$PROJECT_ROOT/$entrypoint" ]] ||
    fail "ambiguous root lifecycle entrypoint must not exist: $entrypoint"
done

require_text "$CALLER" "'on':"
require_text "$CALLER" 'workflow_dispatch:'
require_text "$CALLER" 'expected_action_sha:'
require_text "$CALLER" 'node_repository:'
require_text "$CALLER" 'node_ref:'
require_text "$CALLER" 'uses: ./.github/workflows/reusable-build-node.yml'
require_text "$CALLER" 'source_sha: ${{ needs.normalize.outputs.node_ref }}'
require_text "$CALLER" 'https://github.com/voiceofhu/one-node-node.git'
require_text "$CALLER" "rev-parse --verify 'FETCH_HEAD^{commit}'"
require_text "$CALLER" "if: needs.normalize.outputs.publish == 'true'"
require_text "$DISPATCHER" 'require_repository node_repository voiceofhu/one-node-node'
require_text "$DISPATCHER" 'publish_supported=true'

require_text "$BUILD" 'runs-on: ubuntu-24.04'
require_text "$BUILD" '[ "$ACTION_REPOSITORY" = voiceofhu/one-action ]'
require_text "$BUILD" '[ "$SOURCE_REPOSITORY" = voiceofhu/one-node-node ]'
require_text "$BUILD" 'Action and One Node revisions must be exact commit SHAs.'
require_text "$BUILD" 'git -C action rev-parse --verify HEAD'
require_text "$BUILD" 'git -C source rev-parse --verify HEAD'
require_text "$BUILD" 'go mod verify'
require_text "$BUILD" 'make test'
require_text "$BUILD" 'go test -race ./one/access ./one/binding ./one/control ./one/runtime ./one/session ./one/state'
require_text "$BUILD" 'make test-e2e'
require_text "$BUILD" 'working-directory: action'
require_text "$BUILD" 'run: make node-check'
require_text "$BUILD" 'make build-linux-amd64'
require_text "$BUILD" 'make build-linux-arm64'
require_text "$BUILD" 'action/scripts/release/write-checksums.sh'
require_text "$BUILD" 'cd source/dist'
require_text "$BUILD" 'one-node-linux-amd64'
require_text "$BUILD" 'one-node-linux-arm64'
require_text "$BUILD" 'sha256sum -c ../../provenance/SHA256SUMS'
require_text "$BUILD" 'published: false, deployed: false'
require_text "$BUILD" 'Artifact upload/GHCR/Release/deploy: not run'
require_text "$BUILD" 'name: node-release-${{ inputs.source_sha }}'
require_text "$CALLER" 'name: Publish immutable One Node image and release'
require_text "$CALLER" 'ghcr.io/voiceofhu/one-node'
require_text "$CALLER" 'one-node-v${{ needs.build.outputs.source_version }}'
require_text "$CALLER" 'action/scripts/release/publish-node-image.sh'

if grep -Eq 'needs\.prepare|publish_authorized|secrets\.(GH_TOKEN|SOURCE_READ_TOKEN)' "$CALLER"; then
  fail 'One Node direct build workflow retains a redundant validation or repository-token gate'
fi

if grep -Fq 'action/scripts/github/resolve-ref.sh' "$CALLER"; then
  fail 'One Node normalization must not apply custom token-shape validation to GitHub runtime tokens'
fi

if grep -Fq 'voiceofhu/one-node-action' "$CALLER" "$BUILD" "$DISPATCHER"; then
  fail 'One Node workflow still trusts the legacy Action repository'
fi

printf '%s\n' 'One Node exact-SHA build and publication workflow contract tests passed.'
