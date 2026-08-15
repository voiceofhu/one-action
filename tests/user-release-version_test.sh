#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
test_dir="$(mktemp -d)"
trap 'rm -rf "$test_dir"' EXIT

export PATH="$PROJECT_ROOT/tests/fakes:$PATH"
export GH_TOKEN=github_pat_user_release_contract_1234567890
export FAKE_EXPECTED_AUTH="$GH_TOKEN"
export FAKE_CURL_LOG="$test_dir/curl.log"
export FAKE_CURL_ALLOW_POST=true
export ACTION_REPOSITORY=voiceofhu/one-action
export ACTION_REF=main
export GITHUB_API_URL=https://api.github.com
export DRY_RUN=false
export VERSION=26.815.1234
export CONFIRM_DISPATCH=dispatch:user.yml:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
export CONFIRM_MUTATION=mutate:user.yml:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
export ONE_USER_BACKEND_REPOSITORY=voiceofhu/one-user-backend
export ONE_USER_WEB_REPOSITORY=voiceofhu/one-user-web
export ONE_USER_BACKEND_DIR="$test_dir/backend"
export ONE_USER_WEB_DIR="$test_dir/web"

backend_bare="$test_dir/backend-origin.git"
web_bare="$test_dir/web-origin.git"
git init -q --bare "$backend_bare"
git init -q --bare "$web_bare"
git init -q "$ONE_USER_BACKEND_DIR"
git init -q "$ONE_USER_WEB_DIR"

for repository in "$ONE_USER_BACKEND_DIR" "$ONE_USER_WEB_DIR"; do
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

bash "$PROJECT_ROOT/scripts/release/deploy-user-release.sh" >"$test_dir/output"

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

grep -Fq 'POST https://api.github.com/repos/voiceofhu/one-action/actions/workflows/user.yml/dispatches' \
  "$FAKE_CURL_LOG"
grep -Fq 'Dispatched user.yml at exact Action SHA aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.' \
  "$test_dir/output"

if grep -R -Fq "$GH_TOKEN" "$test_dir/output" "$FAKE_CURL_LOG"; then
  printf '%s\n' 'User release leaked GH_TOKEN.' >&2
  exit 1
fi

printf '%s\n' 'One User generated-version release and dispatch test passed.'
