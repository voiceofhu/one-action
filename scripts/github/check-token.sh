#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

require_tool curl
require_tool jq
normalize_github_token
action_repository="${ACTION_REPOSITORY:-}"
validate_repository "$action_repository"
[[ "$action_repository" == "$FIXED_ACTION_REPOSITORY" ]] ||
  die 'ACTION_REPOSITORY must be the fixed central Action repository'

response_file="$(mktemp)"
trap 'rm -f "$response_file"' EXIT
github_get user "$response_file"
login="$(jq -er '.login' "$response_file")" || die "GitHub user response has no login"
[[ "$login" =~ ^[A-Za-z0-9-]{1,39}$ ]] || die 'GitHub user response has an invalid login'
printf 'OK token identity: %s\n' "$login"

github_get "repos/$action_repository" "$response_file"
printf 'OK action repository: %s\n' "$action_repository"

for workflow in user.yml node-server.yml node.yml reusable-publish-web-backend.yml \
  app.yml one-browser-backend.yml egress.yml; do
  github_get "repos/$action_repository/actions/workflows/$workflow" "$response_file"
  printf 'OK workflow: %s\n' "$workflow"
done

unset GH_TOKEN
printf '%s\n' 'Read-only token checks passed; no workflow was dispatched.'
