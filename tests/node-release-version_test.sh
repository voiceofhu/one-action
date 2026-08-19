#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
test_dir="$(mktemp -d)"
trap 'rm -rf "$test_dir"' EXIT

node_dir="$test_dir/node"
node_bare="$test_dir/node-origin.git"
action_dir="$test_dir/action"
git init -q --bare "$node_bare"
git init -q "$node_dir"
git init -q "$action_dir"
for repository in "$node_dir" "$action_dir"; do
  git -C "$repository" config user.name test
  git -C "$repository" config user.email test@example.invalid
  git -C "$repository" checkout -qb main
done

printf '%s\n' 0.1.0 >"$node_dir/VERSION"
cat >"$node_dir/Makefile" <<'EOF'
.PHONY: test
test:
	@true
EOF
git -C "$node_dir" add VERSION Makefile
git -C "$node_dir" commit -qm initial
git -C "$node_dir" remote add origin https://github.com/voiceofhu/one-node-node.git
git -C "$node_dir" config url."file://$node_bare".insteadOf \
  https://github.com/voiceofhu/one-node-node.git
git -C "$node_dir" push -q -u origin main

mkdir -p "$action_dir/scripts/release" "$action_dir/scripts/github"
cp "$PROJECT_ROOT/scripts/release/deploy-node-release.sh" "$action_dir/scripts/release/"
cp "$PROJECT_ROOT/scripts/github/common.sh" \
  "$PROJECT_ROOT/scripts/github/resolve-ref.sh" \
  "$PROJECT_ROOT/scripts/github/dispatch-workflow.sh" \
  "$action_dir/scripts/github/"
git -C "$action_dir" add scripts
git -C "$action_dir" commit -qm initial

export PATH="$PROJECT_ROOT/tests/fakes:$PATH"
export FAKE_CURL_LOG="$test_dir/curl.log"
export FAKE_EXPECTED_AUTH=github_pat_node_release_contract_1234567890
export FAKE_CURL_ALLOW_POST=true
export GH_TOKEN="$FAKE_EXPECTED_AUTH"
export GITHUB_API_URL=https://api.github.com
export ACTION_REPOSITORY=voiceofhu/one-action
export ACTION_REF=main
export DRY_RUN=false
export VERSION=26.819.1234
export ONE_NODE_DIR="$node_dir"
export ONE_NODE_REPOSITORY=voiceofhu/one-node-node
: >"$FAKE_CURL_LOG"

bash "$action_dir/scripts/release/deploy-node-release.sh" >"$test_dir/output"

[[ "$(<"$node_dir/VERSION")" == 26.819.1234 ]]
git --git-dir="$node_bare" rev-parse --verify refs/tags/v26.819.1234 >/dev/null
git --git-dir="$node_bare" show refs/heads/main:VERSION | grep -qx 26.819.1234
grep -q '^POST https://api.github.com/repos/voiceofhu/one-action/actions/workflows/node.yml/dispatches$' \
  "$FAKE_CURL_LOG"
grep -q '"node_ref": "3333333333333333333333333333333333333333"' "$test_dir/output"
grep -q '"publish": true' "$test_dir/output"
grep -q '"deploy": false' "$test_dir/output"

printf '%s\n' 'One Node VERSION, source tag, and publication dispatch test passed.'
