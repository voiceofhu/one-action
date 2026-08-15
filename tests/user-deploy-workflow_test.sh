#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
workflow="$PROJECT_ROOT/.github/workflows/user.yml"
dispatcher="$PROJECT_ROOT/scripts/github/dispatch-workflow.sh"
deploy="$PROJECT_ROOT/scripts/deploy/deploy-user.sh"
ssh_config="$PROJECT_ROOT/scripts/deploy/configure-ssh.sh"

require_text() {
  local file="$1"
  local text="$2"
  grep -Fq -- "$text" "$file" || {
    printf 'Missing One User deployment contract in %s: %s\n' "$file" "$text" >&2
    exit 1
  }
}

require_text "$PROJECT_ROOT/make/workflows.mk" 'deploy-user:'
require_text "$PROJECT_ROOT/make/workflows.mk" 'version="$${VERSION}" environment="prod"'
require_text "$PROJECT_ROOT/make/workflows.mk" 'publish="true" deploy="true"'
require_text "$dispatcher" "deployment is supported only for One User"
require_text "$dispatcher" "One User deployment requires publication of the exact image"
require_text "$dispatcher" "One User deployment requires environment=prod"

require_text "$workflow" 'name: Deploy combined User image'
require_text "$workflow" "needs.publish.outputs.image_ref"
require_text "$workflow" 'environment:'
require_text "$workflow" 'name: one-user-prod'
require_text "$workflow" 'DEPLOY_HOST: ${{ vars.DEPLOY_HOST }}'
require_text "$workflow" "DEPLOY_PORT: \${{ vars.DEPLOY_PORT || '22' }}"
require_text "$workflow" 'packages: read'
require_text "$workflow" 'source_read_token: ${{ secrets.GH_TOKEN }}'
require_text "$workflow" 'DEPLOY_SSH_KEY: ${{ secrets.DEPLOY_SSH_KEY }}'
require_text "$workflow" 'DEPLOY_KNOWN_HOSTS: ${{ secrets.DEPLOY_KNOWN_HOSTS }}'
require_text "$workflow" 'GH_TOKEN: ${{ secrets.GH_TOKEN }}'
require_text "$workflow" 'gh api user --jq .login'
require_text "$workflow" 'bash action/scripts/deploy/deploy-user.sh'
require_text "$workflow" "if: always() && steps.registry-login.outcome == 'success'"

if grep -Fq '98.65.67.83' "$workflow"; then
  printf '%s\n' 'User workflow must read DEPLOY_HOST from GitHub Variables.' >&2
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
