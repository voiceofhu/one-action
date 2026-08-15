#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
test_dir="$(mktemp -d)"
trap 'rm -rf "$test_dir"' EXIT

export PATH="$PROJECT_ROOT/tests/fakes:$PATH"
export FAKE_CURL_LOG="$test_dir/curl.log"
export DRY_RUN=false
export VERSION=26.815.1234
export ONE_USER_BACKEND_REPOSITORY=voiceofhu/one-user-backend
export ONE_USER_WEB_REPOSITORY=voiceofhu/one-user-web
export ONE_USER_BACKEND_DIR="$test_dir/backend"
export ONE_USER_WEB_DIR="$test_dir/web"
unset GH_TOKEN CONFIRM_DISPATCH CONFIRM_MUTATION FAKE_EXPECTED_AUTH FAKE_CURL_ALLOW_POST
: >"$FAKE_CURL_LOG"

backend_bare="$test_dir/backend-origin.git"
web_bare="$test_dir/web-origin.git"
action_bare="$test_dir/action-origin.git"
action_dir="$test_dir/action"
git init -q --bare "$backend_bare"
git init -q --bare "$web_bare"
git init -q --bare "$action_bare"
git init -q "$ONE_USER_BACKEND_DIR"
git init -q "$ONE_USER_WEB_DIR"
git init -q "$action_dir"

for repository in "$ONE_USER_BACKEND_DIR" "$ONE_USER_WEB_DIR" "$action_dir"; do
  git -C "$repository" config user.name test
  git -C "$repository" config user.email test@example.invalid
  git -C "$repository" checkout -qb main
done

cat >"$ONE_USER_BACKEND_DIR/Cargo.toml" <<'EOF'
[package]
name = "one-user-backend"
version = "0.1.0"
EOF
cat >"$ONE_USER_BACKEND_DIR/Cargo.lock" <<'EOF'
version = 4

[[package]]
name = "one-user-backend"
version = "0.1.0"
EOF
git -C "$ONE_USER_BACKEND_DIR" add Cargo.toml Cargo.lock
git -C "$ONE_USER_BACKEND_DIR" commit -qm initial
git -C "$ONE_USER_BACKEND_DIR" remote add origin \
  https://github.com/voiceofhu/one-user-backend.git
git -C "$ONE_USER_BACKEND_DIR" config \
  url."file://$backend_bare".insteadOf \
  https://github.com/voiceofhu/one-user-backend.git
git -C "$ONE_USER_BACKEND_DIR" push -q -u origin main

cat >"$ONE_USER_WEB_DIR/package.json" <<'EOF'
{
  "name": "one-user-web",
  "private": true,
  "version": "0.1.0"
}
EOF
git -C "$ONE_USER_WEB_DIR" add package.json
git -C "$ONE_USER_WEB_DIR" commit -qm initial
git -C "$ONE_USER_WEB_DIR" remote add origin \
  https://github.com/voiceofhu/one-user-web.git
git -C "$ONE_USER_WEB_DIR" config \
  url."file://$web_bare".insteadOf \
  https://github.com/voiceofhu/one-user-web.git
git -C "$ONE_USER_WEB_DIR" push -q -u origin main

# Run from a temporary canonical One Action repository so the control tag cannot
# touch the developer's real checkout.
mkdir -p "$action_dir/scripts/release"
cp "$PROJECT_ROOT/scripts/release/deploy-user-release.sh" \
  "$action_dir/scripts/release/deploy-user-release.sh"
git -C "$action_dir" add scripts/release/deploy-user-release.sh
git -C "$action_dir" commit -qm initial
action_sha="$(git -C "$action_dir" rev-parse HEAD)"
git -C "$action_dir" remote add origin https://github.com/voiceofhu/one-action.git
git -C "$action_dir" config \
  url."file://$action_bare".insteadOf \
  https://github.com/voiceofhu/one-action.git
git -C "$action_dir" push -q -u origin main

bash "$action_dir/scripts/release/deploy-user-release.sh" >"$test_dir/output"

grep -Fq 'version = "26.815.1234"' "$ONE_USER_BACKEND_DIR/Cargo.toml"
grep -Fq 'version = "26.815.1234"' "$ONE_USER_BACKEND_DIR/Cargo.lock"
node -e '
  const p = require(process.argv[1]);
  if (p.version !== "26.815.1234") process.exit(1);
' "$ONE_USER_WEB_DIR/package.json"

git --git-dir="$backend_bare" rev-parse --verify refs/tags/v26.815.1234 >/dev/null
git --git-dir="$web_bare" rev-parse --verify refs/tags/v26.815.1234 >/dev/null
git --git-dir="$backend_bare" show refs/heads/main:Cargo.toml |
  grep -Fq 'version = "26.815.1234"'
git --git-dir="$web_bare" show refs/heads/main:package.json |
  grep -Fq '"version": "26.815.1234"'

control_sha="$(
  git --git-dir="$action_bare" rev-parse 'refs/tags/user-v26.815.1234^{commit}'
)"
[ "$control_sha" = "$action_sha" ] || {
  printf '%s\n' 'One User control tag does not point to the exact Action commit.' >&2
  exit 1
}

if [ -s "$FAKE_CURL_LOG" ]; then
  printf '%s\n' 'Local One User release unexpectedly called the GitHub API.' >&2
  exit 1
fi

printf '%s\n' 'One User source and control-tag release test passed without a local token.'
