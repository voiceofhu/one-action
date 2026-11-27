#!/usr/bin/env bash
# shellcheck disable=SC2154 # checkout_sha and stamped_sha are set by functions in scripts/lib
# Builds an App's signed Android APK on this machine and publishes it as the
# one-<key>-android-v<VERSION> release of voiceofhu/one-action.
#
# With `android_updater_key` the APK also gets a minisign signature (the
# desktop updater's key) and the release an android.json, which the App's
# backend serves as the in-app update manifest. ANDROID_R2_BUCKET (and
# optionally ANDROID_R2_PREFIX, default one-<key>/android/) also uploads the
# APK to that Cloudflare R2 bucket with wrangler before the release is
# created, for a backend whose ONE_NODE_ANDROID_DOWNLOAD_URL points at it.
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

[[ "$#" -eq 1 || "$#" -eq 5 ]] ||
  die 'usage: release-android.sh APP [ACTION_SHA APP_SHA WEB_SHA CORE_SHA]'
load_app "$1"
expected_action_sha=${2:-}
expected_app_sha=${3:-}
expected_web_sha=${4:-}
expected_core_sha=${5:-}
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
r2_bucket=${ANDROID_R2_BUCKET:-}
r2_prefix=${ANDROID_R2_PREFIX:-one-$APP_KEY/android/}
[[ -z "$r2_bucket" || "$r2_bucket" =~ ^[a-z0-9][a-z0-9-]{1,61}[a-z0-9]$ ]] || die 'ANDROID_R2_BUCKET is not a bucket name'
[[ "$r2_prefix" =~ ^([A-Za-z0-9._-]+/)*$ ]] || die 'ANDROID_R2_PREFIX must be empty or end with /'

printf '%s Android release: %s from %s branch %s, built locally (%s)\n' \
  "$APP_TITLE" "$release_tag" "$APP_REPOSITORY" "$app_ref" "$app_dir" >&2
printf 'Assets: %s%s + SHA256SUMS on %s\n' "$asset_name" \
  "$([[ -n "$APP_ANDROID_UPDATER_KEY" ]] && printf ' (+ .sig, android.json)')" "$ACTION_REPOSITORY" >&2
[[ -z "$r2_bucket" ]] || printf 'Also uploaded to R2: %s/%s%s\n' "$r2_bucket" "$r2_prefix" "$asset_name" >&2
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
require_tool jq
require_tool shasum

action_origin="$(origin_remote_url "$PROJECT_ROOT")"
is_github_remote "$action_origin" "$ACTION_REPOSITORY" ||
  die "Action origin must be $ACTION_REPOSITORY, got $action_origin"
[[ -z "$(git -C "$PROJECT_ROOT" status --porcelain --untracked-files=all)" ]] ||
  die 'Action repository must be clean'
action_sha="$(git -C "$PROJECT_ROOT" rev-parse --verify HEAD)"
git -C "$PROJECT_ROOT" fetch --no-tags origin '+refs/heads/main:refs/remotes/origin/main'
[[ "$action_sha" == "$(git -C "$PROJECT_ROOT" rev-parse refs/remotes/origin/main)" ]] ||
  die 'Action HEAD must exactly match published origin/main'
[[ -z "$expected_action_sha" || "$action_sha" == "$expected_action_sha" ]] ||
  die 'Action HEAD changed since desktop validation'

verify_checkout App "$app_dir" "$APP_REPOSITORY" "$app_ref" "$app_ref_variable" \
  "restore its Git metadata or set $app_dir_variable to a valid App checkout"
# shellcheck disable=SC2154 # set by verify_checkout (scripts/lib/checkout.sh)
app_sha=$checkout_sha
[[ -z "$expected_app_sha" || "$app_sha" == "$expected_app_sha" ]] ||
  die 'App HEAD changed since desktop validation'

check_bundled_sources() {
  local repo dir expected
  for repo in web core; do
    expected="expected_${repo}_sha"
    [[ -n "${!expected}" ]] || continue
    dir="$(dirname -- "$app_dir")/$repo"
    [[ "${!expected}" == "$(git -C "$dir" rev-parse --verify HEAD)" &&
      -z "$(git -C "$dir" status --porcelain --untracked-files=all)" ]] ||
      die "$repo source changed since desktop validation"
  done
}
check_bundled_sources

release_notes() {
  printf '%s Android %s (arm64, signed APK).\n\nSource: %s@%s\n' \
    "$APP_TITLE" "$VERSION" "$APP_REPOSITORY" "$app_sha"
  if [[ -n "$expected_action_sha" ]]; then
    printf 'Action: %s@%s\n' "$ACTION_REPOSITORY" "$action_sha"
    [[ -z "$expected_web_sha" ]] || printf 'Bundled web: %s@%s\n' "$APP_WEB_REPOSITORY" "$expected_web_sha"
    [[ -z "$expected_core_sha" ]] || printf 'Shared core module: %s@%s\n' "$APP_CORE_REPOSITORY" "$expected_core_sha"
  fi
  printf '\nVerify: `shasum -a 256 -c SHA256SUMS`'
}

existing="$(mktemp)"
trap 'rm -f "$existing"' EXIT
if gh release view "$release_tag" --repo "$ACTION_REPOSITORY" --json body,assets,isDraft,isPrerelease >"$existing" 2>&1; then
  # A retry can finish the desktop trigger for the same sources after the APK was published.
  if [[ -n "$expected_action_sha" ]] &&
    jq -e --arg notes "$(release_notes)" --arg apk "$asset_name" --arg key "$APP_ANDROID_UPDATER_KEY" '
      .body == $notes and .isDraft == false and .isPrerelease == false
      and ([.assets[].name] | index($apk) != null and index("SHA256SUMS") != null
        and ($key == "" or (index($apk + ".sig") != null and index("android.json") != null)))
    ' "$existing" >/dev/null; then
    printf 'Android release %s already published for these sources\n' "$release_tag"
    exit 0
  fi
  die "Release $release_tag already exists; choose a new VERSION"
elif ! grep -qi 'release not found' "$existing"; then
  cat "$existing" >&2
  die 'Unable to verify Android release availability; refusing to build'
fi

[[ -f "$app_dir/android-signing/keystore.properties" ]] ||
  die "missing $app_dir/android-signing/keystore.properties (release keystore)"
if [[ -n "$APP_ANDROID_UPDATER_KEY" ]]; then
  updater_key="$app_dir/$APP_ANDROID_UPDATER_KEY"
  updater_password="${updater_key%.key}.password"
  [[ -f "$updater_key" && -f "$updater_password" ]] ||
    die "missing $updater_key or its .password (in-app updater key)"
fi
[[ -z "$r2_bucket" ]] || require_tool pnpm

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
check_bundled_sources

assets="$(mktemp -d)"
trap 'rm -f "$existing"; rm -rf "$assets"; restore_app' EXIT
cp -- "$apk" "$assets/$asset_name"
upload=("$assets/$asset_name")
if [[ -n "$APP_ANDROID_UPDATER_KEY" ]]; then
  # Tauri's minisign signer, as for the desktop updater bundles: <apk>.sig.
  (cd -- "$app_dir" && TAURI_SIGNING_PRIVATE_KEY_PASSWORD="$(cat -- "$updater_password")" \
    pnpm exec tauri signer sign --private-key-path "$updater_key" "$assets/$asset_name" >/dev/null)
  [[ -s "$assets/$asset_name.sig" ]] || die 'the APK was not signed for the updater'
  jq -n --arg version "$VERSION" --arg url "$asset_name" \
    --arg signature "$(cat -- "$assets/$asset_name.sig")" \
    --arg sha256 "$(shasum -a 256 -- "$assets/$asset_name" | cut -d ' ' -f 1)" \
    --argjson size "$(wc -c <"$assets/$asset_name" | tr -d ' ')" \
    --arg pub_date "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{version: $version, notes: "", pub_date: $pub_date, url: $url, signature: $signature, size: $size, sha256: $sha256}' \
    >"$assets/android.json"
  upload+=("$assets/$asset_name.sig" "$assets/android.json")
fi
bash "$PROJECT_ROOT/scripts/release/write-checksums.sh" "$assets/SHA256SUMS" "${upload[@]}"

if [[ "$APP_STAMP_SOURCE" == true ]]; then
  stamp_source_version "$app_dir" "$app_ref" "$VERSION" || die 'App version was not committed'
  app_sha=$stamped_sha
else
  restore_app
fi
trap 'rm -f "$existing"; rm -rf "$assets"' EXIT

# R2 first: once the release exists the backend offers it, so the file must already be there.
if [[ -n "$r2_bucket" ]]; then
  printf 'Uploading %s to R2 %s/%s...\n' "$asset_name" "$r2_bucket" "$r2_prefix" >&2
  (cd -- "$app_dir" && pnpm dlx wrangler@4 r2 object put "$r2_bucket/$r2_prefix$asset_name" --remote \
    --file "$assets/$asset_name" --content-type application/vnd.android.package-archive \
    --cache-control 'public, max-age=31536000, immutable') || die 'R2 upload failed'
fi

gh release create "$release_tag" --repo "$ACTION_REPOSITORY" --target "$action_sha" \
  --title "$APP_TITLE Android $VERSION" --notes "$(release_notes)" \
  "${upload[@]}" "$assets/SHA256SUMS"
printf 'Published https://github.com/%s/releases/tag/%s\n' "$ACTION_REPOSITORY" "$release_tag"
