#!/usr/bin/env bash
# shellcheck disable=SC2154 # checkout_sha and stamped_sha are set by functions in scripts/lib
# Builds an App's signed Android APK on this machine and publishes it as the
# one-<key>-android-v<VERSION> release of voiceofhu/one-action.
#
# The APK is built locally, not in CI: the release keystore lives only in the
# App checkout's gitignored android-signing/ (see the App's make/android.mk).
# The source rules match release-app.sh: one-action at origin/main, the App
# checkout clean and pushed; with `stamp_source` the version is committed and
# pushed to the App repository once the build succeeded.
set -Eeuo pipefail
umask 077

PROJECT_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=scripts/lib/git-remote.sh
source "$PROJECT_ROOT/scripts/lib/git-remote.sh"
# shellcheck source=scripts/lib/app.sh
source "$PROJECT_ROOT/scripts/lib/app.sh"
# shellcheck source=scripts/lib/stamp-source.sh
source "$PROJECT_ROOT/scripts/lib/stamp-source.sh"
# shellcheck source=scripts/lib/checkout.sh
source "$PROJECT_ROOT/scripts/lib/checkout.sh"

ACTION_REPOSITORY=voiceofhu/one-action

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

require_tool() {
  command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

[[ "$#" -eq 1 ]] || die 'usage: release-android.sh APP'
load_app "$1"
[[ -n "$APP_ANDROID_APK" ]] || die "$APP_TITLE has no android_apk in apps.json"
: "${VERSION:?VERSION is required}"
[[ "$VERSION" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] || die 'Invalid App version'
SOURCE_ROOT=${SOURCE_ROOT:-$(cd -- "$PROJECT_ROOT/.." && pwd)}
app_env_prefix="ONE_$(printf '%s' "$APP_KEY" | tr '[:lower:]' '[:upper:]')_APP"
app_dir_variable="${app_env_prefix}_DIR"
app_ref_variable="${app_env_prefix}_REF"
app_dir=${!app_dir_variable:-$SOURCE_ROOT/$APP_SOURCE_DIR}
app_ref=${!app_ref_variable:-main}
[[ "$app_ref" =~ ^[A-Za-z0-9][A-Za-z0-9._/-]{0,255}$ && "$app_ref" != *..* ]] ||
  die "$app_ref_variable must be a branch name"
release_tag="$APP_ANDROID_RELEASE_PREFIX-v$VERSION"
asset_name="$APP_ANDROID_RELEASE_PREFIX-$VERSION.apk"

printf '%s Android release: %s from %s branch %s, built locally (%s)\n' \
  "$APP_TITLE" "$release_tag" "$APP_REPOSITORY" "$app_ref" "$app_dir" >&2
printf 'Assets: %s + SHA256SUMS on %s\n' "$asset_name" "$ACTION_REPOSITORY" >&2
[[ "$APP_STAMP_SOURCE" != true ]] ||
  printf 'Version %s is committed and pushed to %s branch %s after the build\n' \
    "$VERSION" "$APP_REPOSITORY" "$app_ref" >&2
case "${DRY_RUN:-true}" in
  true|1|yes)
    printf '%s\n' 'DRY_RUN=true: nothing was built and no release was published.'
    exit 0
    ;;
  false|0|no) ;;
  *) die 'DRY_RUN must be true or false' ;;
esac

require_tool git
require_tool gh
require_tool make
require_tool node
require_tool pnpm
require_tool go
require_tool cargo

action_origin="$(origin_remote_url "$PROJECT_ROOT")"
is_github_remote "$action_origin" "$ACTION_REPOSITORY" ||
  die "Action origin must be $ACTION_REPOSITORY, got $action_origin"
[[ -z "$(git -C "$PROJECT_ROOT" status --porcelain --untracked-files=all)" ]] ||
  die 'Action repository must be clean'
action_sha="$(git -C "$PROJECT_ROOT" rev-parse --verify HEAD)"
git -C "$PROJECT_ROOT" fetch --no-tags origin '+refs/heads/main:refs/remotes/origin/main'
[[ "$action_sha" == "$(git -C "$PROJECT_ROOT" rev-parse refs/remotes/origin/main)" ]] ||
  die 'Action HEAD must exactly match published origin/main'

verify_checkout App "$app_dir" "$APP_REPOSITORY" "$app_ref" "$app_ref_variable" \
  "restore its Git metadata or set $app_dir_variable to a valid App checkout"
# shellcheck disable=SC2154 # set by verify_checkout (scripts/lib/checkout.sh)
app_sha=$checkout_sha
[[ -f "$app_dir/android-signing/keystore.properties" ]] ||
  die "missing $app_dir/android-signing/keystore.properties (release keystore)"

existing="$(mktemp)"
trap 'rm -f "$existing"' EXIT
if gh release view "$release_tag" --repo "$ACTION_REPOSITORY" >"$existing" 2>&1; then
  die "Release $release_tag already exists; choose a new VERSION"
elif ! grep -qi 'release not found' "$existing"; then
  cat "$existing" >&2
  die 'Unable to verify Android release availability; refusing to build'
fi

android_home=${ANDROID_HOME:-$HOME/Library/Android/sdk}
build_tools="$(find "$android_home/build-tools" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort -V | tail -n 1)"
[[ -n "$build_tools" && -x "$build_tools/apksigner" && -x "$build_tools/aapt2" ]] ||
  die "Android build-tools (apksigner, aapt2) not found under $android_home/build-tools"

# Build with the version in the working tree. Until the stamp below the
# checkout must go back to app_sha whatever happens.
restore_app() {
  git -C "$app_dir" checkout --quiet -- . 2>/dev/null || true
}
trap 'rm -f "$existing"; restore_app' EXIT
(cd -- "$app_dir" && node scripts/update-version.mjs "$VERSION" >/dev/null)
apk="$app_dir/$APP_ANDROID_APK"
rm -f -- "$apk"
printf 'Building the signed APK (make android-release)...\n' >&2
make -C "$app_dir" android-release
[[ -f "$apk" ]] || die "build did not produce $APP_ANDROID_APK"

"$build_tools/apksigner" verify --min-sdk-version 26 "$apk" ||
  die 'APK signature does not verify'
apk_version="$("$build_tools/aapt2" dump badging "$apk" | sed -nE "s/.* versionName='([^']*)'.*/\1/p" | head -n 1)"
[[ "$apk_version" == "$VERSION" ]] || die "APK versionName is $apk_version, expected $VERSION"

# The build may only have touched the version files.
[[ "$(git -C "$app_dir" rev-parse HEAD)" == "$app_sha" ]] || die 'App HEAD changed during the build'
if [[ -n "$(git -C "$app_dir" status --porcelain --untracked-files=all | grep -v '^ M ' || true)" ]]; then
  git -C "$app_dir" status --short >&2
  die 'the build left untracked or staged files in the App checkout'
fi
[[ "$action_sha" == "$(git -C "$PROJECT_ROOT" rev-parse HEAD)" ]] ||
  die 'Action HEAD changed during the build'

assets="$(mktemp -d)"
trap 'rm -f "$existing"; rm -rf "$assets"; restore_app' EXIT
cp -- "$apk" "$assets/$asset_name"
bash "$PROJECT_ROOT/scripts/release/write-checksums.sh" "$assets/SHA256SUMS" "$assets/$asset_name"

if [[ "$APP_STAMP_SOURCE" == true ]]; then
  stamp_source_version "$app_dir" "$app_ref" "$VERSION" || die 'App version was not committed'
  app_sha=$stamped_sha
else
  restore_app
fi
trap 'rm -f "$existing"; rm -rf "$assets"' EXIT

notes="$(printf '%s Android %s (arm64, signed APK).\n\nSource: %s@%s\n\nVerify: `shasum -a 256 -c SHA256SUMS`' \
  "$APP_TITLE" "$VERSION" "$APP_REPOSITORY" "$app_sha")"
gh release create "$release_tag" --repo "$ACTION_REPOSITORY" --target "$action_sha" \
  --title "$APP_TITLE Android $VERSION" --notes "$notes" \
  "$assets/$asset_name" "$assets/SHA256SUMS"
printf 'Published https://github.com/%s/releases/tag/%s\n' "$ACTION_REPOSITORY" "$release_tag"
