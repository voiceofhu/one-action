#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
test_dir="$(mktemp -d)"
trap 'rm -rf "$test_dir"' EXIT

output_file="$test_dir/output"
export FAKE_CURL_LOG="$test_dir/curl.log"
export PATH="$PROJECT_ROOT/tests/fakes:$PATH"
export GH_TOKEN=github_pat_dispatch_contract_token_1234567890
export FAKE_EXPECTED_AUTH="$GH_TOKEN"
export ACTION_REPOSITORY=voiceofhu/one-action
export ACTION_REF=main
export GITHUB_API_URL=https://api.github.com
export DRY_RUN=true
unset CONFIRM_DISPATCH CONFIRM_MUTATION FAKE_CURL_ALLOW_POST FAKE_CURL_OVERSIZE

action_sha=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa

reset_api_log() {
  : >"$FAKE_CURL_LOG"
}

assert_no_post() {
  if grep -q '^POST ' "$FAKE_CURL_LOG"; then
    printf '%s\n' 'Rejected or dry-run request unexpectedly sent POST.' >&2
    exit 1
  fi
}

expect_failure_before_api() {
  reset_api_log
  if "$@" >/dev/null 2>&1; then
    printf '%s\n' 'Invalid dispatcher input was accepted.' >&2
    exit 1
  fi
  if [ -s "$FAKE_CURL_LOG" ]; then
    printf '%s\n' 'Invalid local input reached the GitHub API boundary.' >&2
    exit 1
  fi
}

reset_api_log
bash "$PROJECT_ROOT/scripts/github/dispatch-workflow.sh" user.yml \
  backend_repository=voiceofhu/one-user-backend \
  backend_ref=main \
  web_repository=voiceofhu/one-user-web \
  web_ref=v1.0.0 \
  version= environment=dev publish=false deploy=false >"$output_file"

grep -q "\"ref\": \"$action_sha\"" "$output_file"
grep -q "\"expected_action_sha\": \"$action_sha\"" "$output_file"
grep -q '"backend_ref": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"' "$output_file"
grep -q '"web_ref": "cccccccccccccccccccccccccccccccccccccccc"' "$output_file"
grep -q "Real dispatch confirmation: dispatch:user.yml:$action_sha" "$output_file"
grep -q 'DRY_RUN=true: no workflow was dispatched.' "$output_file"
assert_no_post

reset_api_log
bash "$PROJECT_ROOT/scripts/github/dispatch-workflow.sh" user.yml \
  backend_repository=voiceofhu/one-user-backend \
  backend_ref=main \
  web_repository=voiceofhu/one-user-web \
  web_ref=main \
  version=1.2.3 environment=prod publish=true deploy=true >"$output_file"
grep -q '"publish": true' "$output_file"
grep -q '"deploy": true' "$output_file"
grep -q "Publication confirmation: mutate:user.yml:$action_sha" "$output_file"
assert_no_post

reset_api_log
bash "$PROJECT_ROOT/scripts/github/dispatch-workflow.sh" user.yml \
  backend_repository=voiceofhu/one-user-backend \
  backend_ref=main \
  web_repository=voiceofhu/one-user-web \
  web_ref=main \
  version=1.2.3 environment=prod publish=true deploy=false >"$output_file"
grep -q "\"confirmation\": \"enable:one-user:$action_sha\"" "$output_file"
grep -q "Publication confirmation: mutate:user.yml:$action_sha" "$output_file"
grep -q 'DRY_RUN=true: no workflow was dispatched.' "$output_file"
assert_no_post

expect_failure_before_api \
  bash "$PROJECT_ROOT/scripts/github/dispatch-workflow.sh" unknown.yml value=x
expect_failure_before_api \
  env ACTION_REPOSITORY=attacker/action \
  bash "$PROJECT_ROOT/scripts/github/dispatch-workflow.sh" app.yml \
    app_repository=voiceofhu/one-browser-app-next app_ref=main version= publish=false
expect_failure_before_api \
  bash "$PROJECT_ROOT/scripts/github/dispatch-workflow.sh" app.yml \
    app_repository=attacker/app app_ref=main version= publish=false
expect_failure_before_api \
  bash "$PROJECT_ROOT/scripts/github/dispatch-workflow.sh" app.yml \
    app_repository=voiceofhu/one-browser-app-next app_ref='main?token=x' version= publish=false
expect_failure_before_api \
  bash "$PROJECT_ROOT/scripts/github/dispatch-workflow.sh" app.yml \
    app_repository=voiceofhu/one-browser-app-next app_ref=main version= publish=false extra=value
expect_failure_before_api \
  bash "$PROJECT_ROOT/scripts/github/dispatch-workflow.sh" user.yml \
    backend_repository=voiceofhu/one-user-backend backend_ref=main \
    web_repository=voiceofhu/one-user-web web_ref=main \
    version=v1.2.3 environment=dev publish=false deploy=false
expect_failure_before_api \
  bash "$PROJECT_ROOT/scripts/github/dispatch-workflow.sh" user.yml \
    backend_repository=voiceofhu/one-user-backend backend_ref=main \
    web_repository=voiceofhu/one-user-web web_ref=main \
    version=1.2.3 environment=qa publish=false deploy=false
expect_failure_before_api \
  bash "$PROJECT_ROOT/scripts/github/dispatch-workflow.sh" user.yml \
    backend_repository=voiceofhu/one-user-backend backend_ref=main \
    web_repository=voiceofhu/one-user-web web_ref=main \
    version=1.2.3 environment=prod publish=false deploy=true
expect_failure_before_api \
  bash "$PROJECT_ROOT/scripts/github/dispatch-workflow.sh" one-amz.yml \
    backend_repository=voiceofhu/one-amz-backend-next backend_ref=main \
    web_repository=voiceofhu/one-amz-web-next web_ref=main \
    version=1.2.3 environment=prod publish=true deploy=true
expect_failure_before_api \
  bash "$PROJECT_ROOT/scripts/github/dispatch-workflow.sh" app-debug.yml \
    app_repository=voiceofhu/one-browser-app-next app_ref=main upload_artifact=true
expect_failure_before_api \
  bash "$PROJECT_ROOT/scripts/github/dispatch-workflow.sh" app.yml \
    app_repository=voiceofhu/one-browser-app-next app_ref=main version=1.2.3 publish=true
expect_failure_before_api \
  bash "$PROJECT_ROOT/scripts/github/dispatch-workflow.sh" egress.yml \
    egress_repository=voiceofhu/one-browser-egress-next egress_ref=main \
    version=1.2.3 environment=stage publish=true deploy=false
expect_failure_before_api \
  bash "$PROJECT_ROOT/scripts/github/dispatch-workflow.sh" browser-runtime.yml \
    runtime_repository=voiceofhu/unapproved runtime_ref=main version= publish=false

reset_api_log
bash "$PROJECT_ROOT/scripts/github/dispatch-workflow.sh" node.yml \
  node_repository=voiceofhu/one-node-node node_ref=main \
  version= publish=false deploy=false >"$output_file"
grep -q 'File: node.yml' "$output_file"
grep -q '"node_ref": "3333333333333333333333333333333333333333"' "$output_file"
grep -q "Real dispatch confirmation: dispatch:node.yml:$action_sha" "$output_file"
grep -q 'DRY_RUN=true: no workflow was dispatched.' "$output_file"
assert_no_post

expect_failure_before_api \
  bash "$PROJECT_ROOT/scripts/github/dispatch-workflow.sh" node.yml \
    node_repository=attacker/node node_ref=main version= publish=false deploy=false
expect_failure_before_api \
  bash "$PROJECT_ROOT/scripts/github/dispatch-workflow.sh" node.yml \
    node_repository=voiceofhu/one-node-node node_ref=main \
    version=1.2.3 publish=true deploy=false
expect_failure_before_api \
  env GITHUB_API_URL=https://attacker.invalid \
  bash "$PROJECT_ROOT/scripts/github/dispatch-workflow.sh" app.yml \
    app_repository=voiceofhu/one-browser-app-next app_ref=main version= publish=false
expect_failure_before_api \
  bash "$PROJECT_ROOT/scripts/github/dispatch-workflow.sh" user.yml \
    backend_repository=voiceofhu/one-user-backend backend_ref=main \
    web_repository=voiceofhu/one-user-web web_ref=main \
    version=1.2.3 environment=prod publish=true deploy=false \
    confirmation=enable:one-user

reset_api_log
export FAKE_CURL_OVERSIZE=true
if bash "$PROJECT_ROOT/scripts/github/dispatch-workflow.sh" app.yml \
  app_repository=voiceofhu/one-browser-app-next app_ref=main \
  version= publish=false >/dev/null 2>&1; then
  printf '%s\n' 'Oversized GitHub API body was accepted.' >&2
  exit 1
fi
unset FAKE_CURL_OVERSIZE
assert_no_post

reset_api_log
make --no-print-directory -s -C "$PROJECT_ROOT" dispatch-one-amz \
  ONE_AMZ_BACKEND_REF=main ONE_AMZ_WEB_REF=main DRY_RUN=true >"$output_file"
grep -q 'File: one-amz.yml' "$output_file"
grep -q '"backend_ref": "dddddddddddddddddddddddddddddddddddddddd"' "$output_file"
grep -q '"web_ref": "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"' "$output_file"
assert_no_post

backend_fixture="$test_dir/one-user-backend"
web_fixture="$test_dir/one-user-web"
mkdir -p "$backend_fixture" "$web_fixture"
git -C "$backend_fixture" init -q
git -C "$backend_fixture" config user.name test
git -C "$backend_fixture" config user.email test@example.invalid
printf '%s\n' '[package]' 'name = "one-user-backend"' 'version = "0.1.0"' \
  >"$backend_fixture/Cargo.toml"
git -C "$backend_fixture" add Cargo.toml
git -C "$backend_fixture" commit -qm initial
git -C "$backend_fixture" remote add origin \
  https://github.com/voiceofhu/one-user-backend.git

git -C "$web_fixture" init -q
git -C "$web_fixture" config user.name test
git -C "$web_fixture" config user.email test@example.invalid
printf '%s\n' '{"name":"one-user-web","version":"0.1.0"}' \
  >"$web_fixture/package.json"
git -C "$web_fixture" add package.json
git -C "$web_fixture" commit -qm initial
git -C "$web_fixture" remote add origin \
  https://github.com/voiceofhu/one-user-web.git

reset_api_log
make --no-print-directory -s -C "$PROJECT_ROOT" deploy-user \
  GENERATED_VERSION=26.815.1234 \
  ONE_USER_BACKEND_DIR="$backend_fixture" \
  ONE_USER_WEB_DIR="$web_fixture" \
  DRY_RUN=true >"$output_file"
grep -q 'File: user.yml' "$output_file"
grep -q '"version": "26.815.1234"' "$output_file"
grep -q '"environment": "prod"' "$output_file"
grep -q '"publish": true' "$output_file"
grep -q '"deploy": true' "$output_file"
assert_no_post

export DRY_RUN=false
reset_api_log
if bash "$PROJECT_ROOT/scripts/github/dispatch-workflow.sh" app.yml \
  app_repository=voiceofhu/one-browser-app-next app_ref=main \
  version= publish=false >/dev/null 2>&1; then
  printf '%s\n' 'Dispatch succeeded without Action-SHA-bound confirmation.' >&2
  exit 1
fi
assert_no_post

export CONFIRM_DISPATCH="dispatch:app.yml:$action_sha"
export FAKE_CURL_ALLOW_POST=true
reset_api_log
bash "$PROJECT_ROOT/scripts/github/dispatch-workflow.sh" app.yml \
  app_repository=voiceofhu/one-browser-app-next app_ref=main \
  version= publish=false >"$output_file"
grep -q '^POST https://api.github.com/repos/voiceofhu/one-action/actions/workflows/app.yml/dispatches$' "$FAKE_CURL_LOG"
grep -q "Dispatched app.yml at exact Action SHA $action_sha" "$output_file"

if grep -R -Fq "$GH_TOKEN" "$output_file" "$FAKE_CURL_LOG"; then
  printf '%s\n' 'GitHub token leaked into dispatcher output or request log.' >&2
  exit 1
fi

grep -Fq -- '--config -' "$PROJECT_ROOT/scripts/github/common.sh"
grep -Fq -- 'export -n GH_TOKEN' "$PROJECT_ROOT/scripts/github/common.sh"

printf '%s\n' 'Dispatcher trust-root, dry-run, input, and confirmation contracts passed.'
