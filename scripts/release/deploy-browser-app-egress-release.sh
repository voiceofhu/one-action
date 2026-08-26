#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
ACTION_REPOSITORY=voiceofhu/one-action
ACTION_REF=${ACTION_REF:-main}

: "${VERSION:?VERSION is required}"
: "${ONE_BROWSER_EGRESS_REPOSITORY:?ONE_BROWSER_EGRESS_REPOSITORY is required}"
: "${ONE_BROWSER_EGRESS_REF:?ONE_BROWSER_EGRESS_REF is required}"
[[ "$VERSION" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]

action_sha="$(GH_TOKEN="${GH_TOKEN:-}" \
  bash "$PROJECT_ROOT/scripts/github/resolve-ref.sh" "$ACTION_REPOSITORY" "$ACTION_REF")"

CONFIRM_DISPATCH="dispatch:egress.yml:$action_sha" \
CONFIRM_MUTATION="mutate:egress.yml:$action_sha" \
ACTION_REPOSITORY="$ACTION_REPOSITORY" ACTION_REF="$ACTION_REF" \
bash "$PROJECT_ROOT/scripts/github/dispatch-workflow.sh" egress.yml \
  "egress_repository=$ONE_BROWSER_EGRESS_REPOSITORY" \
  "egress_ref=$ONE_BROWSER_EGRESS_REF" \
  "version=$VERSION" \
  'environment=prod' \
  'publish=true' \
  'deploy=false'
