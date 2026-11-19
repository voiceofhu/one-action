#!/usr/bin/env bash
# Resolves the exact One Node runtime sources for node-runtime.yml (step
# "Resolve exact One Node source"): checks the pinned core commit exists and
# records the Xray / Hysteria versions the Node go.mod pins.
# Env: GH_TOKEN NODE_REPOSITORY NODE_SHA CORE_REPOSITORY CORE_SHA VERSION GITHUB_SHA GITHUB_OUTPUT.
set -Eeuo pipefail
[[ -n "$GH_TOKEN" ]]
# The embedded data plane cores are plain Go dependencies of the
# Node module; record the versions its go.mod pins.
go_mod="$(gh api "repos/$NODE_REPOSITORY/contents/go.mod?ref=$NODE_SHA" --jq .content |
  base64 --decode | tr -d '\r')"
module_version() {
  awk -v module="$1" '$1 == "require" { $1 = ""; $0 = substr($0, 2) } $1 == module { print $2; exit }' <<<"$go_mod"
}
xray_version="$(module_version github.com/xtls/xray-core)"
hysteria_version="$(module_version github.com/apernet/hysteria/core/v2)"
[[ "$xray_version" =~ ^v[0-9][0-9A-Za-z.+-]*$ ]]
[[ "$hysteria_version" =~ ^v[0-9][0-9A-Za-z.+-]*$ ]]

printf 'version=%s\n' "$VERSION" >>"$GITHUB_OUTPUT"
printf 'node_sha=%s\n' "$NODE_SHA" >>"$GITHUB_OUTPUT"
[[ "$(gh api "repos/$CORE_REPOSITORY/commits/$CORE_SHA" --jq .sha)" == "$CORE_SHA" ]]
printf 'core_sha=%s\n' "$CORE_SHA" >>"$GITHUB_OUTPUT"
printf 'action_sha=%s\n' "$GITHUB_SHA" >>"$GITHUB_OUTPUT"
printf 'xray_version=%s\n' "$xray_version" >>"$GITHUB_OUTPUT"
printf 'hysteria_version=%s\n' "$hysteria_version" >>"$GITHUB_OUTPUT"
