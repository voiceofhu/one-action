#!/usr/bin/env bash
set -Eeuo pipefail

: "${SSH_HOST:?SSH_HOST is required}"

# Each SSH alias (one per product) logs in to its own Docker config on the server, so
# products deploying to the same host at once never log each other out.
REGISTRY_ACTION=${REGISTRY_ACTION:-login}
REGISTRY_HOST=${REGISTRY_HOST:-ghcr.io}
USE_SUDO=${USE_SUDO:-0}

[[ "$SSH_HOST" =~ ^[A-Za-z0-9._-]{1,64}$ ]] || {
  printf '%s\n' 'SSH_HOST is invalid' >&2
  exit 1
}
[[ "$REGISTRY_HOST" =~ ^[A-Za-z0-9.-]{1,253}$ ]] || {
  printf '%s\n' 'REGISTRY_HOST is invalid' >&2
  exit 1
}
remote_config="\$HOME/.docker-deploy/$SSH_HOST"
case "$USE_SUDO" in
  0) remote_docker="env DOCKER_CONFIG=\"$remote_config\" docker" ;;
  1) remote_docker="sudo -n env DOCKER_CONFIG=\"$remote_config\" docker" ;;
  *) printf '%s\n' 'USE_SUDO must be 0 or 1' >&2; exit 1 ;;
esac

shell_quote() {
  printf '%q' "$1"
}

case "$REGISTRY_ACTION" in
  login)
    : "${GH_TOKEN:?GH_TOKEN is required}"
    registry_username=$(gh api user --jq .login)
    [[ "$registry_username" =~ ^[A-Za-z0-9-]{1,39}$ ]] || {
      printf '%s\n' 'GH_TOKEN returned an invalid GitHub login' >&2
      exit 1
    }
    # shellcheck disable=SC2029
    # Compose may be a per-user CLI plugin, which Docker looks up under DOCKER_CONFIG.
    printf '%s' "$GH_TOKEN" | ssh "$SSH_HOST" \
      "mkdir -p -m 700 \"$remote_config\" && { test ! -d \"\$HOME/.docker/cli-plugins\" || ln -sfn \"\$HOME/.docker/cli-plugins\" \"$remote_config/cli-plugins\"; } && $remote_docker login $(shell_quote "$REGISTRY_HOST") --username $(shell_quote "$registry_username") --password-stdin"
    ;;
  logout)
    # shellcheck disable=SC2029
    ssh "$SSH_HOST" \
      "$remote_docker logout $(shell_quote "$REGISTRY_HOST"); rm -rf \"$remote_config\""
    ;;
  *)
    printf '%s\n' 'REGISTRY_ACTION must be login or logout' >&2
    exit 1
    ;;
esac
