#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
ACTION_REPOSITORY=voiceofhu/one-action
ACTION_REF=${ACTION_REF:-main}

: "${VERSION:?VERSION is required}"
: "${ONE_BROWSER_BACKEND_REPOSITORY:?ONE_BROWSER_BACKEND_REPOSITORY is required}"
: "${ONE_BROWSER_BACKEND_REF:?ONE_BROWSER_BACKEND_REF is required}"
: "${ONE_BROWSER_WEB_REPOSITORY:?ONE_BROWSER_WEB_REPOSITORY is required}"
: "${ONE_BROWSER_WEB_REF:?ONE_BROWSER_WEB_REF is required}"
[[ "$VERSION" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]

action_sha="$(GH_TOKEN="${GH_TOKEN:-}" \
  bash "$PROJECT_ROOT/scripts/github/resolve-ref.sh" "$ACTION_REPOSITORY" "$ACTION_REF")"

CONFIRM_DISPATCH="dispatch:one-browser-backend.yml:$action_sha" \
CONFIRM_MUTATION="mutate:one-browser-backend.yml:$action_sha" \
ACTION_REPOSITORY="$ACTION_REPOSITORY" ACTION_REF="$ACTION_REF" \
bash "$PROJECT_ROOT/scripts/github/dispatch-workflow.sh" one-browser-backend.yml \
  "backend_repository=$ONE_BROWSER_BACKEND_REPOSITORY" \
  "backend_ref=$ONE_BROWSER_BACKEND_REF" \
  "web_repository=$ONE_BROWSER_WEB_REPOSITORY" \
  "web_ref=$ONE_BROWSER_WEB_REF" \
  "version=$VERSION" \
  'environment=prod' \
  'publish=true' \
  'deploy=false'
