#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
workflow="$PROJECT_ROOT/.github/workflows/user.yml"
release="$PROJECT_ROOT/scripts/release/deploy-user-release.sh"

require_text() {
  local file="$1"
  local text="$2"
  grep -Fq -- "$text" "$file" || {
    printf 'Missing One User publication contract in %s: %s\n' "$file" "$text" >&2
    exit 1
  }
}

reject_text() {
  local file="$1"
  local text="$2"
  if grep -Fq -- "$text" "$file"; then
    printf 'Unexpected One User deployment contract in %s: %s\n' "$file" "$text" >&2
    exit 1
  fi
}

require_text "$PROJECT_ROOT/make/workflows.mk" 'release-user: DRY_RUN = false'
require_text "$PROJECT_ROOT/make/workflows.mk" 'DRY_RUN="$(DRY_RUN)" VERSION="$(USER_RELEASE_VERSION)"'
require_text "$PROJECT_ROOT/make/config.mk" 'timeZone:'\''Asia/Shanghai'\'''
require_text "$release" "ACTION_REPOSITORY='voiceofhu/one-action'"
require_text "$release" 'control_tag="user-v$VERSION"'
require_text "$release" 'push --atomic origin'
require_text "$release" 'Triggered One User image publication with Action control tag:'
if grep -Eq 'GH_TOKEN|CONFIRM_DISPATCH|CONFIRM_MUTATION|DISPATCHER|RESOLVER|dispatch-workflow|gh[[:space:]]+api|curl[[:space:]]' "$release"; then
  printf '%s\n' 'Local One User release must use Git tags, not GitHub API credentials.' >&2
  exit 1
fi

require_text "$workflow" "- 'user-v*'"
require_text "$workflow" 'name: Normalize release inputs'
require_text "$workflow" 'version="${TAG_NAME#user-v}"'
require_text "$workflow" "backend_repository='voiceofhu/one-user-backend'"
require_text "$workflow" "web_repository='voiceofhu/one-user-web'"
require_text "$workflow" "publish='true'"
require_text "$workflow" 'Publication requires a canonical version.'
require_text "$workflow" 'uses: ./.github/workflows/reusable-publish-web-backend.yml'
require_text "$workflow" 'backend_sha: ${{ needs.normalize.outputs.backend_ref }}'
require_text "$workflow" 'web_sha: ${{ needs.normalize.outputs.web_ref }}'
require_text "$workflow" 'environment: prod'
require_text "$workflow" 'source_read_token: ${{ secrets.GH_TOKEN }}'
require_text "$PROJECT_ROOT/.github/workflows/reusable-publish-web-backend.yml" \
  'registry_image=ghcr.io/voiceofhu/one-user'
require_text "$PROJECT_ROOT/.github/workflows/reusable-publish-web-backend.yml" \
  'publish_tag="$VERSION"'
require_text "$PROJECT_ROOT/scripts/release/publish-ghcr-multiarch.sh" \
  'image_ref="$PUBLISH_IMAGE:$PUBLISH_TAG"'

for text in \
  'deploy:' \
  'inputs.deploy' \
  'inputs.environment' \
  'DEPLOY_' \
  'docker-compose' \
  'scripts/deploy/' \
  'ssh one-user-deploy' \
  'name: one-user-prod'; do
  reject_text "$workflow" "$text"
done

if [ -e "$PROJECT_ROOT/scripts/deploy/deploy-user.sh" ] \
  || [ -e "$PROJECT_ROOT/scripts/deploy/configure-ssh.sh" ]; then
  printf '%s\n' 'One User server deployment scripts must be removed.' >&2
  exit 1
fi

if grep -Fq 'actions/workflows/user.yml/dispatches' "$workflow"; then
  printf '%s\n' 'One User tag workflow must not redispatch itself through the API.' >&2
  exit 1
fi

printf '%s\n' 'One User publish-only workflow contract tests passed.'
