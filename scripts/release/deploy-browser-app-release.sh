#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
ACTION_REPOSITORY=voiceofhu/one-action
ACTION_REF=${ACTION_REF:-main}

: "${VERSION:?VERSION is required}"
: "${ONE_BROWSER_APP_REPOSITORY:?ONE_BROWSER_APP_REPOSITORY is required}"
: "${ONE_BROWSER_APP_REF:?ONE_BROWSER_APP_REF is required}"
[[ "$VERSION" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]

action_sha="$(GH_TOKEN="${GH_TOKEN:-}" \
  bash "$PROJECT_ROOT/scripts/github/resolve-ref.sh" "$ACTION_REPOSITORY" "$ACTION_REF")"

CONFIRM_DISPATCH="dispatch:app.yml:$action_sha" \
CONFIRM_MUTATION="mutate:app.yml:$action_sha" \
ACTION_REPOSITORY="$ACTION_REPOSITORY" ACTION_REF="$ACTION_REF" \
bash "$PROJECT_ROOT/scripts/github/dispatch-workflow.sh" app.yml \
  "app_repository=$ONE_BROWSER_APP_REPOSITORY" \
  "app_ref=$ONE_BROWSER_APP_REF" \
  "version=$VERSION" \
  'publish=true'
