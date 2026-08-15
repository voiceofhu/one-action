#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
workflow="$PROJECT_ROOT/.github/workflows/user.yml"
dispatcher="$PROJECT_ROOT/scripts/github/dispatch-workflow.sh"
deploy="$PROJECT_ROOT/scripts/deploy/deploy-user.sh"
release="$PROJECT_ROOT/scripts/release/deploy-user-release.sh"
ssh_config="$PROJECT_ROOT/scripts/deploy/configure-ssh.sh"

require_text() {
  local file="$1"
  local text="$2"
  grep -Fq -- "$text" "$file" || {
    printf 'Missing One User deployment contract in %s: %s\n' "$file" "$text" >&2
    exit 1
  }
}

require_text "$PROJECT_ROOT/make/workflows.mk" 'deploy-user: DRY_RUN = false'
require_text "$PROJECT_ROOT/make/workflows.mk" 'DRY_RUN="$(DRY_RUN)" VERSION="$(USER_RELEASE_VERSION)"'
require_text "$PROJECT_ROOT/make/workflows.mk" 'VERSION="$(USER_RELEASE_VERSION)"'
require_text "$PROJECT_ROOT/make/config.mk" 'timeZone:'\''Asia/Shanghai'\'''
require_text "$PROJECT_ROOT/make/config.mk" 'USER_RELEASE_VERSION ='
require_text "$release" "ACTION_REPOSITORY='voiceofhu/one-action'"
require_text "$release" 'control_tag="user-v$VERSION"'
require_text "$release" 'chore: bump one-user-backend version to $release_tag'
require_text "$release" 'chore: bump one-user-web version to $release_tag'
require_text "$release" 'push --atomic origin'
require_text "$release" '"refs/tags/$control_tag:refs/tags/$control_tag"'
if grep -Eq 'GH_TOKEN|CONFIRM_DISPATCH|CONFIRM_MUTATION|DISPATCHER|RESOLVER|dispatch-workflow|gh[[:space:]]+api|curl[[:space:]]' "$release"; then
  printf '%s\n' 'Local One User release must use Git tags, not GitHub API credentials.' >&2
  exit 1
fi

require_text "$dispatcher" "deployment is supported only for One User"
require_text "$dispatcher" "One User deployment requires publication of the exact image"
require_text "$dispatcher" "One User deployment requires environment=prod"

require_text "$workflow" 'name: Deploy combined User image'
require_text "$workflow" "- 'user-v*'"
require_text "$workflow" 'name: Normalize release inputs'
require_text "$workflow" 'EVENT_NAME: ${{ github.event_name }}'
require_text "$workflow" 'TAG_NAME: ${{ github.ref_name }}'
require_text "$workflow" 'version="${TAG_NAME#user-v}"'
require_text "$workflow" 'source_tag="v$version"'
require_text "$workflow" "backend_repository='voiceofhu/one-user-backend'"
require_text "$workflow" "web_repository='voiceofhu/one-user-web'"
require_text "$workflow" 'bash action/scripts/github/resolve-ref.sh'
require_text "$workflow" "environment='prod'"
require_text "$workflow" "publish='true'"
require_text "$workflow" "deploy='true'"
require_text "$workflow" 'uses: ./.github/workflows/reusable-publish-web-backend.yml'
require_text "$workflow" "needs.publish.outputs.image_ref"
require_text "$workflow" 'environment:'
require_text "$workflow" 'name: one-user-prod'
require_text "$workflow" 'DEPLOY_HOST: ${{ secrets.DEPLOY_HOST }}'
require_text "$workflow" "DEPLOY_PORT: \${{ secrets.DEPLOY_PORT || '22' }}"
require_text "$workflow" 'packages: read'
require_text "$workflow" 'source_read_token: ${{ secrets.GH_TOKEN }}'
require_text "$workflow" 'DEPLOY_SSH_KEY: ${{ secrets.DEPLOY_SSH_KEY }}'
require_text "$workflow" 'DEPLOY_KNOWN_HOSTS: ${{ secrets.DEPLOY_KNOWN_HOSTS }}'
require_text "$workflow" 'GH_TOKEN: ${{ secrets.GH_TOKEN }}'
require_text "$workflow" 'gh api user --jq .login'
require_text "$workflow" 'bash action/scripts/deploy/deploy-user.sh'
require_text "$workflow" "if: always() && steps.registry-login.outcome == 'success'"

if grep -Fq 'uses: ./.github/workflows/reusable-build-web-backend.yml' "$workflow"; then
  printf '%s\n' 'One User must not run a separate single-architecture validation build.' >&2
  exit 1
fi

prepare_line="$(grep -n '^  prepare:$' "$workflow" | cut -d: -f1)"
publish_line="$(grep -n '^  publish:$' "$workflow" | cut -d: -f1)"
deploy_line="$(grep -n '^  deploy:$' "$workflow" | cut -d: -f1)"
if ! ((prepare_line < publish_line && publish_line < deploy_line)); then
  printf '%s\n' 'One User jobs must flow from prepare to publish to deploy.' >&2
  exit 1
fi

publish_block="$(sed -n '/^  publish:$/,/^  deploy:$/p' "$workflow")"
grep -Fq -- '- prepare' <<<"$publish_block" || {
  printf '%s\n' 'One User publication must depend on exact-source preparation.' >&2
  exit 1
}
if grep -Fq -- '- build' <<<"$publish_block"; then
  printf '%s\n' 'One User publication must own its multi-architecture builds.' >&2
  exit 1
fi
deploy_block="$(sed -n '/^  deploy:$/,$p' "$workflow")"
grep -Fq -- '- publish' <<<"$deploy_block" || {
  printf '%s\n' 'One User deployment must wait for the published OCI index.' >&2
  exit 1
}

if [ -e "$PROJECT_ROOT/.github/workflows/user-release.yml" ]; then
  printf '%s\n' 'One User control tags must trigger user.yml directly.' >&2
  exit 1
fi
if grep -Fq 'actions/workflows/user.yml/dispatches' "$workflow"; then
  printf '%s\n' 'One User tag workflow must not redispatch itself through the API.' >&2
  exit 1
fi

if grep -Fq '98.65.67.83' "$workflow"; then
  printf '%s\n' 'User workflow must not hardcode DEPLOY_HOST.' >&2
  exit 1
fi
if grep -Eq 'DEPLOY_(HOST|PORT):.*vars\.DEPLOY_' "$workflow"; then
  printf '%s\n' 'User workflow must read DEPLOY_HOST and DEPLOY_PORT from Secrets.' >&2
  exit 1
fi
if grep -Fq 'secrets.SOURCE_READ_TOKEN' "$workflow"; then
  printf '%s\n' 'User workflow must use the configured GH_TOKEN for cross-repository access.' >&2
  exit 1
fi

require_text "$ssh_config" 'StrictHostKeyChecking yes'
require_text "$ssh_config" 'IdentitiesOnly yes'
require_text "$ssh_config" 'UserKnownHostsFile'
require_text "$deploy" 'ghcr\.io/voiceofhu/one-user-backend-next@sha256:'
require_text "$deploy" 'Server-owned environment file is missing or unsafe'
require_text "$deploy" 'Server-owned Compose file is missing or unsafe'
require_text "$deploy" 'printf '\''ONE_USER_IMAGE=%s\n'\'' "$image_ref"'
require_text "$deploy" '"${compose[@]}" pull "$service"'
require_text "$deploy" '"${compose[@]}" up -d --no-deps "$service"'
require_text "$deploy" 'Running container image does not match the published digest'

if grep -Eq 'scp|rsync|source[[:space:]]+.*\.env|cat[[:space:]]+.*\.env' "$deploy"; then
  printf '%s\n' 'Deployment tooling must not upload or evaluate the server environment file.' >&2
  exit 1
fi

printf '%s\n' 'One User exact-digest deployment workflow contract tests passed.'
