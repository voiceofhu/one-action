#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
WORKFLOW="$PROJECT_ROOT/.github/workflows/egress.yml"
RELEASE_SCRIPT="$PROJECT_ROOT/scripts/release/deploy-browser-egress-release.sh"

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

require_text "$PROJECT_ROOT/make/browser.mk" 'deploy-browser-egress:'
if grep -Fq -- 'deploy-app-egress' "$PROJECT_ROOT/make/browser.mk"; then
  fail 'Legacy deploy-app-egress target must be removed'
fi
require_text "$PROJECT_ROOT/make/config.mk" 'BROWSER_EGRESS_RELEASE_VERSION ='
require_text "$PROJECT_ROOT/make/config.mk" '$(GENERATED_VERSION)'

require_text "$RELEASE_SCRIPT" 'release_tag="one-browser-egress-v$VERSION"'
require_text "$RELEASE_SCRIPT" 'unset GH_TOKEN GITHUB_TOKEN CONFIRM_DISPATCH CONFIRM_MUTATION'
require_text "$RELEASE_SCRIPT" 'make --no-print-directory -C "$PROJECT_ROOT" validate-browser-egress'
require_text "$RELEASE_SCRIPT" 'cargo fmt --manifest-path "$ONE_BROWSER_EGRESS_DIR/Cargo.toml" --all --check'
require_text "$RELEASE_SCRIPT" 'cargo clippy --manifest-path "$ONE_BROWSER_EGRESS_DIR/Cargo.toml"'
require_text "$RELEASE_SCRIPT" 'cargo test --manifest-path "$ONE_BROWSER_EGRESS_DIR/Cargo.toml"'
require_text "$RELEASE_SCRIPT" 'bash "$PROJECT_ROOT/scripts/github/dispatch-workflow.sh" egress.yml'
require_text "$RELEASE_SCRIPT" '"egress_ref=$egress_ref"'

test_line="$(line_number "$RELEASE_SCRIPT" 'cargo test --manifest-path "$ONE_BROWSER_EGRESS_DIR/Cargo.toml"')"
dispatch_line="$(line_number "$RELEASE_SCRIPT" 'bash "$PROJECT_ROOT/scripts/github/dispatch-workflow.sh" egress.yml')"
((test_line < dispatch_line)) || fail 'Egress tests must finish before workflow dispatch'

if grep -Fq -- 'git -C "$PROJECT_ROOT" tag' "$RELEASE_SCRIPT" ||
  grep -Fq -- 'git -C "$ONE_BROWSER_EGRESS_DIR" tag' "$RELEASE_SCRIPT"; then
  fail 'Local Browser Egress release must not create repository tags'
fi

require_text "$WORKFLOW" 'egress_repository: {required: true, type: string}'
require_text "$WORKFLOW" 'egress_ref: {required: true, type: string}'
require_text "$WORKFLOW" 'repository: voiceofhu/one-browser-egress'
require_text "$WORKFLOW" 'one-browser-egress-linux-amd64 one-browser-egress-linux-arm64 >SHA256SUMS'
require_text "$WORKFLOW" 'ghcr.io/voiceofhu/one-browser-egress:'
require_text "$WORKFLOW" 'gh release create "$RELEASE_TAG"'

dry_run_output="$(
  DRY_RUN=true \
  VERSION=26.901.1200 \
  ONE_BROWSER_EGRESS_DIR=/missing/one-browser-egress \
  ONE_BROWSER_EGRESS_REPOSITORY=voiceofhu/one-browser-egress \
  bash "$RELEASE_SCRIPT"
)"
grep -Fq 'One Browser Egress release plan:' <<<"$dry_run_output" ||
  fail 'Browser Egress dry-run did not print the release plan'
grep -Fq 'DRY_RUN=true:' <<<"$dry_run_output" ||
  fail 'Browser Egress dry-run did not stop before repository or API access'

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
  bash "$PROJECT_ROOT/scripts/github/dispatch-workflow.sh" egress.yml \
    egress_repository=voiceofhu/one-browser-egress \
    egress_ref=main \
    version=26.901.1200 \
    environment=prod \
    publish=true \
    deploy=false
)"
grep -Fq '"egress_ref": "2222222222222222222222222222222222222222"' <<<"$dispatch_output" ||
  fail 'Browser Egress dispatch did not pin the exact source commit'
grep -Fq '"confirmation": "enable:egress:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"' <<<"$dispatch_output" ||
  fail 'Browser Egress dispatch did not carry the publication confirmation'

printf '%s\n' 'One Browser Egress release contract tests passed.'
