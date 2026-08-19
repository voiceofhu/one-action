#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
: "${VERSION:?VERSION is required}"
: "${ONE_NODE_SERVER_REPOSITORY:?ONE_NODE_SERVER_REPOSITORY is required}"
: "${ONE_NODE_SERVER_REF:?ONE_NODE_SERVER_REF is required}"
: "${ONE_NODE_WEB_REPOSITORY:?ONE_NODE_WEB_REPOSITORY is required}"
: "${ONE_NODE_WEB_REF:?ONE_NODE_WEB_REF is required}"

[[ "$VERSION" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] || {
  printf '%s\n' 'VERSION must contain three numeric components without leading zeroes' >&2
  exit 1
}

case "${DRY_RUN:-true}" in
  true|1|yes)
    printf '%s\n' \
      'One Node Server deployment plan:' \
      "  version: $VERSION" \
      "  server:  $ONE_NODE_SERVER_REPOSITORY@$ONE_NODE_SERVER_REF" \
      "  web:     $ONE_NODE_WEB_REPOSITORY@$ONE_NODE_WEB_REF" \
      '  image:   ghcr.io/voiceofhu/one-node-server:<version>@sha256:<index>' \
      '  remote:  /opt/one-node' \
      'DRY_RUN=true: no workflow was dispatched.'
    exit 0
    ;;
  false|0|no) ;;
  *) printf '%s\n' 'DRY_RUN must be true or false' >&2; exit 1 ;;
esac

action_sha="$(GH_TOKEN="${GH_TOKEN:-}" bash "$PROJECT_ROOT/scripts/github/resolve-ref.sh" \
  voiceofhu/one-action "${ACTION_REF:-main}")"
CONFIRM_DISPATCH="dispatch:node-server.yml:$action_sha" \
CONFIRM_MUTATION="mutate:node-server.yml:$action_sha" \
DRY_RUN=false \
  exec bash "$PROJECT_ROOT/scripts/github/dispatch-workflow.sh" node-server.yml \
    backend_repository="$ONE_NODE_SERVER_REPOSITORY" \
    backend_ref="$ONE_NODE_SERVER_REF" \
    web_repository="$ONE_NODE_WEB_REPOSITORY" \
    web_ref="$ONE_NODE_WEB_REF" \
    version="$VERSION" publish=true deploy=true
