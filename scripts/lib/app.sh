#!/usr/bin/env bash
# shellcheck disable=SC2034 # APP_* variables are consumed by the sourcing script.
# Loads one Tauri desktop client from apps.json into APP_* variables.
#
# Source it and call `load_app <key>`, or execute it as `app.sh <key>` to
# print the fields as GitHub output lines. The release tag prefix, artifact
# prefix and entry workflow are derived as one-<key>-app / <key>-app.yml.

APP_MANIFEST="${APP_MANIFEST:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)/apps.json}"

app_die() {
  printf '%s\n' "$*" >&2
  exit 1
}

app_field() {
  jq -er --arg key "$APP_KEY" --arg field "$1" '
    .[$key][$field] | if type == "string" then . else error("missing string field") end
  ' "$APP_MANIFEST" 2>/dev/null || app_die "apps.json: $APP_KEY.$1 must be a string"
}

app_require() {
  local value=$1 pattern=$2 label=$3
  [[ "$value" =~ $pattern ]] || app_die "apps.json: $APP_KEY.$label is invalid: $value"
}

load_app() {
  APP_KEY=${1:-}
  [[ "$APP_KEY" =~ ^[a-z][a-z0-9]*$ ]] || app_die "Invalid app key: ${APP_KEY:-<empty>}"
  command -v jq >/dev/null || app_die 'jq is required'
  [[ -f "$APP_MANIFEST" && ! -L "$APP_MANIFEST" ]] || app_die "App manifest is missing: $APP_MANIFEST"
  jq -e --arg key "$APP_KEY" 'has($key)' "$APP_MANIFEST" >/dev/null || app_die "Unknown app: $APP_KEY"

  APP_TITLE="$(app_field title)"
  APP_REPOSITORY="$(app_field repository)"
  APP_SOURCE_DIR="$(app_field source_dir)"
  APP_CARGO_PACKAGE="$(app_field cargo_package)"
  APP_PNPM_VERSION="$(app_field pnpm_version)"
  APP_MACOS_CONFIG="$(jq -r --arg key "$APP_KEY" '.[$key].macos_config // ""' "$APP_MANIFEST")"

  app_require "$APP_TITLE" '^One [A-Za-z0-9 ]+$' title
  app_require "$APP_REPOSITORY" '^voiceofhu/[a-z0-9-]+$' repository
  app_require "$APP_SOURCE_DIR" '^one-[a-z0-9-]+/[a-z0-9-]+$' source_dir
  app_require "$APP_CARGO_PACKAGE" '^[a-z0-9_-]+$' cargo_package
  app_require "$APP_PNPM_VERSION" '^[0-9]+\.[0-9]+\.[0-9]+$' pnpm_version
  app_require "$APP_MACOS_CONFIG" '^(src-tauri/[a-z0-9.-]+\.json)?$' macos_config

  APP_RELEASE_PREFIX="one-$APP_KEY-app"
  APP_WORKFLOW="$APP_KEY-app.yml"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  set -Eeuo pipefail
  load_app "${1:-}"
  printf '%s=%s\n' \
    title "$APP_TITLE" \
    repository "$APP_REPOSITORY" \
    pnpm_version "$APP_PNPM_VERSION" \
    macos_config "$APP_MACOS_CONFIG" \
    release_prefix "$APP_RELEASE_PREFIX"
fi
