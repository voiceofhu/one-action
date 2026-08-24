#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
WORKFLOW="$PROJECT_ROOT/.github/workflows/node.yml"
RELEASE_SCRIPT="$PROJECT_ROOT/scripts/release/deploy-node-release.sh"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

require_text() {
  local file=$1 text=$2
  grep -Fq -- "$text" "$file" || fail "missing contract in ${file##*/}: $text"
}

line_number() {
  local file=$1 text=$2 matches count
  matches="$(grep -nF -- "$text" "$file")" || fail "missing ordered contract: $text"
  count="$(printf '%s\n' "$matches" | wc -l | tr -d '[:space:]')"
  [[ "$count" == 1 ]] || fail "ordered contract must occur once: $text"
  printf '%s\n' "${matches%%:*}"
}

job_timeout() {
  local job=$1
  awk -v job="$job" '
    $0 == "  " job ":" { inside = 1; next }
    inside && /^  [[:alnum:]_-]+:/ { exit }
    inside && /timeout-minutes:/ { print $2; exit }
  ' "$WORKFLOW"
}

for entrypoint in install.sh upgrade.sh uninstall.sh; do
  [[ -f "$PROJECT_ROOT/node/$entrypoint" ]] ||
    fail "missing namespaced Node entrypoint: node/$entrypoint"
  [[ ! -e "$PROJECT_ROOT/$entrypoint" ]] ||
    fail "ambiguous root lifecycle entrypoint must not exist: $entrypoint"
done

require_text "$WORKFLOW" "'on':"
require_text "$WORKFLOW" 'workflow_dispatch:'
require_text "$WORKFLOW" 'expected_action_sha:'
require_text "$WORKFLOW" 'node_repository:'
require_text "$WORKFLOW" 'node_ref:'
require_text "$WORKFLOW" 'version:'
if grep -Eq '^  push:' "$WORKFLOW"; then
  fail 'One Node Action must be dispatched instead of tag-triggered'
fi
for forbidden in reusable-build-node node-check 'go test' 'make test' lint; do
  if grep -Fqi -- "$forbidden" "$WORKFLOW"; then
    fail "One Node Action retains non-build work: $forbidden"
  fi
done

[[ "$(job_timeout build)" == 15 ]] || fail 'One Node architecture builds must time out at 15 minutes'
[[ "$(job_timeout publish-image)" == 5 ]] || fail 'One Node image publication must time out at 5 minutes'
upload_timeout="$(job_timeout upload-release)"
[[ "$upload_timeout" =~ ^[0-9]+$ ]] && ((upload_timeout <= 8)) ||
  fail 'One Node draft upload must time out within 8 minutes'
release_timeout="$(job_timeout publish-release)"
[[ "$release_timeout" == 2 ]] || fail 'One Node Release finalizer must time out at 2 minutes'

[[ "$(grep -Ec '^[[:space:]]+- arch: (amd64|arm64)$' "$WORKFLOW")" == 2 ]] ||
  fail 'One Node build matrix must contain exactly amd64 and arm64'
[[ "$(grep -Fc -- '- arch: amd64' "$WORKFLOW")" == 1 ]] || fail 'amd64 build is missing or duplicated'
[[ "$(grep -Fc -- '- arch: arm64' "$WORKFLOW")" == 1 ]] || fail 'arm64 build is missing or duplicated'
require_text "$WORKFLOW" 'runner: ubuntu-24.04-arm'
require_text "$WORKFLOW" 'make --no-print-directory "build-linux-$ARCH"'
require_text "$WORKFLOW" 'uses: actions/upload-artifact@v4'
require_text "$WORKFLOW" 'name: one-node-linux-${{ matrix.arch }}'
require_text "$WORKFLOW" 'uses: docker/build-push-action@v6'
require_text "$WORKFLOW" 'platforms: linux/${{ matrix.arch }}'
require_text "$WORKFLOW" 'push: true'
require_text "$WORKFLOW" 'ghcr.io/voiceofhu/one-node:build-${{ needs.prepare.outputs.node_sha }}-${{ github.run_id }}-${{ github.run_attempt }}-${{ matrix.arch }}'

require_text "$WORKFLOW" 'sha256sum one-node-linux-amd64 one-node-linux-arm64 >SHA256SUMS'
require_text "$WORKFLOW" 'docker buildx imagetools create'
require_text "$WORKFLOW" 'inspect_raw() {'
require_text "$WORKFLOW" 'for attempt in 1 2 3 4 5; do'
require_text "$WORKFLOW" 'Could not read back OCI image %s after %s attempts:'
require_text "$WORKFLOW" 'inspect_raw "$1" |'
require_text "$WORKFLOW" 'candidate_fingerprint="$(fingerprint "$candidate")"'
require_text "$WORKFLOW" 'version_ref="$image:$VERSION"'
require_text "$WORKFLOW" 'verify_final "$version_ref"'
require_text "$WORKFLOW" '[[ "$(fingerprint "$version_ref")" == "$candidate_fingerprint" ]]'
if grep -Fq -- 'revision_ref=' "$WORKFLOW" ||
  grep -Fq -- 'index:org.opencontainers.image.revision=' "$WORKFLOW"; then
  fail 'One Node image publication must not restore the removed revision tag contract'
fi
require_text "$WORKFLOW" 'gh release create "$RELEASE_TAG"'
require_text "$WORKFLOW" 'gh release upload "$RELEASE_TAG"'
require_text "$WORKFLOW" 'gh release edit "$RELEASE_TAG"'
require_text "$WORKFLOW" '- publish-image'
require_text "$WORKFLOW" '- upload-release'
require_text "$WORKFLOW" 'dist/SHA256SUMS dist/one-node-linux-amd64 dist/one-node-linux-arm64'
require_text "$WORKFLOW" '--repo voiceofhu/one-action'
require_text "$WORKFLOW" 'login=$(gh api user --jq .login)'
if grep -Fq -- '--repo voiceofhu/one-node-node' "$WORKFLOW"; then
  fail 'One Node Release assets must not be published to the private source repository'
fi

require_text "$RELEASE_SCRIPT" 'release_tag="one-node-v$VERSION"'
require_text "$RELEASE_SCRIPT" 'unset GH_TOKEN GITHUB_TOKEN CONFIRM_DISPATCH CONFIRM_MUTATION'
require_text "$RELEASE_SCRIPT" 'bash "$PROJECT_ROOT/scripts/github/dispatch-workflow.sh" node.yml'
require_text "$RELEASE_SCRIPT" '"node_repository=$ONE_NODE_REPOSITORY"'
require_text "$RELEASE_SCRIPT" '"node_ref=$node_ref"'
require_text "$RELEASE_SCRIPT" '"version=$VERSION"'
require_text "$RELEASE_SCRIPT" 'make --no-print-directory -C "$PROJECT_ROOT" validate-node'
upgrade_line="$(line_number "$RELEASE_SCRIPT" 'make --no-print-directory -C "$ONE_NODE_DIR" verify-upgrade')"
dispatch_line="$(line_number "$RELEASE_SCRIPT" 'bash "$PROJECT_ROOT/scripts/github/dispatch-workflow.sh" node.yml')"
((upgrade_line < dispatch_line)) ||
  fail 'Node verify-upgrade must finish before workflow dispatch'
if grep -Fq -- 'git -C "$PROJECT_ROOT" tag' "$RELEASE_SCRIPT" ||
  grep -Fq -- 'git -C "$PROJECT_ROOT" push origin "refs/tags/' "$RELEASE_SCRIPT" ||
  grep -Fq -- 'git -C "$ONE_NODE_DIR" tag' "$RELEASE_SCRIPT" ||
  grep -Fq -- 'VERSION.tmp' "$RELEASE_SCRIPT"; then
  fail 'Local One Node release must not create release commits or tags'
fi
if grep -Fxq -- 'make --no-print-directory -C "$PROJECT_ROOT" validate' "$RELEASE_SCRIPT"; then
  fail 'One Node release must not run the unrelated One Action validation suite'
fi

dispatch_fixture="$(mktemp -d)"
trap 'rm -rf "$dispatch_fixture"' EXIT
ln -s "$PROJECT_ROOT/tests/fakes/curl" "$dispatch_fixture/curl"
: >"$dispatch_fixture/curl.log"
dispatch_output="$(
  PATH="$dispatch_fixture:$PATH" \
  GH_TOKEN=abcdefghijklmnopqrstuvwxyz123456 \
  FAKE_EXPECTED_AUTH=abcdefghijklmnopqrstuvwxyz123456 \
  FAKE_CURL_LOG="$dispatch_fixture/curl.log" \
  DRY_RUN=true \
  ACTION_REPOSITORY=voiceofhu/one-action \
  ACTION_REF=main \
  bash "$PROJECT_ROOT/scripts/github/dispatch-workflow.sh" node.yml \
    node_repository=voiceofhu/one-node-node \
    node_ref=main \
    version=26.824.1500
)"
grep -Fq '"node_ref": "3333333333333333333333333333333333333333"' <<<"$dispatch_output" ||
  fail 'Node dispatch did not pin the exact source commit'
grep -Fq '"confirmation": "enable:node:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"' <<<"$dispatch_output" ||
  fail 'Node dispatch did not carry the fixed publication confirmation'

cat >"$dispatch_fixture/git" <<'SCRIPT'
#!/usr/bin/env bash
set -Eeuo pipefail
[[ "$1" == credential && "$2" == fill ]]
cat >/dev/null
printf '%s\n' 'username=fixture' 'password=abcdefghijklmnopqrstuvwxyz123456'
SCRIPT
chmod 0755 "$dispatch_fixture/git"
dispatch_output="$(
  env -u GH_TOKEN \
  PATH="$dispatch_fixture:$PATH" \
  FAKE_EXPECTED_AUTH=abcdefghijklmnopqrstuvwxyz123456 \
  FAKE_CURL_LOG="$dispatch_fixture/curl.log" \
  DRY_RUN=true \
  ACTION_REPOSITORY=voiceofhu/one-action \
  ACTION_REF=main \
  bash "$PROJECT_ROOT/scripts/github/dispatch-workflow.sh" node.yml \
    node_repository=voiceofhu/one-node-node \
    node_ref=main \
    version=26.824.1501
)"
grep -Fq 'DRY_RUN=true: no workflow was dispatched.' <<<"$dispatch_output" ||
  fail 'Node dispatch did not reuse the Git HTTPS credential helper'

printf '%s\n' 'One Node dispatched compile/upload contract tests passed.'
