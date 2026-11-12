#!/usr/bin/env bash
set -Eeuo pipefail

# Runs the release-time version commit (scripts/lib/stamp-source.sh) against a
# throwaway App repository and its origin.
# macOS /bin/bash 3.2 ignores a failed [[ ]] or ! under set -e, so checks say `|| fail`.
fail() {
  printf '%s: check failed at line %s\n' "${BASH_SOURCE[0]##*/}" "${BASH_LINENO[0]}" >&2
  exit 1
}
PROJECT_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib/stamp-source.sh
source "$PROJECT_ROOT/scripts/lib/stamp-source.sh"
# shellcheck source=scripts/lib/app.sh
source "$PROJECT_ROOT/scripts/lib/app.sh"

test_dir="$(mktemp -d)"
trap 'rm -rf "$test_dir"' EXIT
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.invalid
export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.invalid

git init --quiet --bare --initial-branch=main "$test_dir/origin.git"
git clone --quiet "$test_dir/origin.git" "$test_dir/app" 2>/dev/null
app="$test_dir/app"
mkdir -p "$app/scripts"
printf '%s\n' '{"version":"0.1.0"}' >"$app/package.json"
cat >"$app/scripts/update-version.mjs" <<'SCRIPT'
import fs from 'node:fs';
const pkg = JSON.parse(fs.readFileSync('package.json', 'utf8'));
pkg.version = process.argv[2];
fs.writeFileSync('package.json', JSON.stringify(pkg) + '\n');
if (process.env.STRAY) fs.writeFileSync('stray.txt', 'x');
SCRIPT
git -C "$app" add -A
git -C "$app" commit --quiet -m init
git -C "$app" push --quiet origin HEAD:refs/heads/main
first="$(git -C "$app" rev-parse HEAD)"

# A new version: one commit, pushed, and the checkout stays clean.
stamp_source_version "$app" main 26.1112.1130 2>/dev/null || fail
[[ "$stamped_sha" != "$first" ]] || fail
[[ "$stamped_sha" == "$(git -C "$app" rev-parse HEAD)" ]] || fail
[[ "$stamped_sha" == "$(git -C "$test_dir/origin.git" rev-parse refs/heads/main)" ]] || fail
[[ "$(git -C "$app" log -1 --format=%s)" == 'chore(release): v26.1112.1130' ]] || fail
[[ "$(git -C "$app" log -1 --format=%b)" == '' ]] || fail
[[ "$(git -C "$app" rev-parse HEAD~1)" == "$first" ]] || fail
[[ -z "$(git -C "$app" status --porcelain --untracked-files=all)" ]] || fail
grep -q '"version":"26.1112.1130"' "$app/package.json" || fail

# The same version again changes nothing: no empty commit.
stamp_source_version "$app" main 26.1112.1130 2>/dev/null || fail
[[ "$stamped_sha" == "$(git -C "$test_dir/origin.git" rev-parse refs/heads/main)" ]] || fail
[[ "$(git -C "$app" rev-list --count HEAD)" == 2 ]] || fail

# origin moved on meanwhile: the push is refused, the commit is taken back.
git clone --quiet "$test_dir/origin.git" "$test_dir/other"
printf 'x\n' >"$test_dir/other/other.txt"
git -C "$test_dir/other" add -A
git -C "$test_dir/other" commit --quiet -m other
git -C "$test_dir/other" push --quiet origin HEAD:refs/heads/main
before="$(git -C "$app" rev-parse HEAD)"
if stamp_source_version "$app" main 26.1112.1131 2>/dev/null; then fail; fi
[[ "$(git -C "$app" rev-parse HEAD)" == "$before" ]] || fail
[[ -z "$(git -C "$app" status --porcelain --untracked-files=all)" ]] || fail
grep -q '"version":"26.1112.1130"' "$app/package.json" || fail
git -C "$app" pull --quiet --ff-only origin main

# A version script that leaves a new file behind is not committed.
before="$(git -C "$app" rev-parse HEAD)"
if STRAY=1 stamp_source_version "$app" main 26.1112.1132 2>/dev/null; then fail; fi
[[ "$(git -C "$app" rev-parse HEAD)" == "$before" ]] || fail
rm -f "$app/stray.txt"

# apps.json: only the Apps that ask for it.
load_app node
[[ "$APP_STAMP_SOURCE" == true ]] || fail
load_app mail
[[ "$APP_STAMP_SOURCE" == false ]] || fail
printf '%s\n' 'App version commit tests passed.'
