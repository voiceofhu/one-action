#!/usr/bin/env bash
set -Eeuo pipefail

: "${SSH_HOST:?SSH_HOST is required}"
: "${REMOTE_DIR:?REMOTE_DIR is required}"
: "${DOCKER_IMAGE:?DOCKER_IMAGE is required}"
: "${COMPOSE_PROJECT_NAME:?COMPOSE_PROJECT_NAME is required}"
: "${COMPOSE_SERVICE_NAME:?COMPOSE_SERVICE_NAME is required}"
: "${READY_URL:?READY_URL is required}"
: "${USE_SUDO:?USE_SUDO is required}"
: "${LOG_TAIL:?LOG_TAIL is required}"

valid_image_ref() {
  [[ "$1" =~ ^ghcr\.io/voiceofhu/one-user:(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)@sha256:[0-9a-f]{64}$ ]]
}

valid_image_ref "$DOCKER_IMAGE" || {
  printf '%s\n' 'DOCKER_IMAGE must be the fixed One User version tag pinned to an OCI index digest' >&2
  exit 1
}
[[ "$SSH_HOST" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$ ]] || {
  printf '%s\n' 'SSH_HOST is invalid' >&2
  exit 1
}
[[ "$REMOTE_DIR" =~ ^/opt/[A-Za-z0-9._/-]*[A-Za-z0-9._-]$ ]] \
  && [[ "$REMOTE_DIR" != *//* ]] \
  && [[ "/$REMOTE_DIR/" != *'/../'* ]] || {
  printf '%s\n' 'REMOTE_DIR must be a canonical path below /opt' >&2
  exit 1
}
[[ "$COMPOSE_PROJECT_NAME" =~ ^[a-z0-9][a-z0-9_-]{0,62}$ ]] || {
  printf '%s\n' 'COMPOSE_PROJECT_NAME is invalid' >&2
  exit 1
}
[[ "$COMPOSE_SERVICE_NAME" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$ ]] || {
  printf '%s\n' 'COMPOSE_SERVICE_NAME is invalid' >&2
  exit 1
}
[[ "$READY_URL" =~ ^https?://(127\.0\.0\.1|localhost)(:[0-9]{1,5})?/readyz$ ]] || {
  printf '%s\n' 'READY_URL must be a loopback /readyz URL' >&2
  exit 1
}
case "$USE_SUDO" in
  0 | 1) ;;
  *) printf '%s\n' 'USE_SUDO must be 0 or 1' >&2; exit 1 ;;
esac
[[ "$LOG_TAIL" =~ ^[1-9][0-9]{0,3}$ ]] || {
  printf '%s\n' 'LOG_TAIL must be between 1 and 9999' >&2
  exit 1
}

shell_quote() {
  printf '%q' "$1"
}

# Values are validated above and deliberately shell-quoted on the client before
# they become environment assignments for the non-interactive remote process.
# shellcheck disable=SC2029
ssh "$SSH_HOST" \
  "REMOTE_DIR=$(shell_quote "$REMOTE_DIR") \
  DOCKER_IMAGE=$(shell_quote "$DOCKER_IMAGE") \
  COMPOSE_PROJECT_NAME=$(shell_quote "$COMPOSE_PROJECT_NAME") \
  COMPOSE_SERVICE_NAME=$(shell_quote "$COMPOSE_SERVICE_NAME") \
  READY_URL=$(shell_quote "$READY_URL") \
  USE_SUDO=$(shell_quote "$USE_SUDO") \
  LOG_TAIL=$(shell_quote "$LOG_TAIL") \
  bash -s" <<'REMOTE_DEPLOY'
set -Eeuo pipefail

wait_timeout=120
new_image=$DOCKER_IMAGE

valid_image_ref() {
  [[ "$1" =~ ^ghcr\.io/voiceofhu/one-user:(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)@sha256:[0-9a-f]{64}$ ]]
}

valid_image_ref "$DOCKER_IMAGE" || {
  printf '%s\n' 'Remote DOCKER_IMAGE validation failed' >&2
  exit 1
}
[[ -d "$REMOTE_DIR" && ! -L "$REMOTE_DIR" ]] || {
  printf '%s\n' "Deployment directory is missing or unsafe: $REMOTE_DIR" >&2
  exit 1
}

env_file="$REMOTE_DIR/.env"
compose_file="$REMOTE_DIR/docker-compose.yml"
cert_dir="$REMOTE_DIR/cert"
[[ -f "$env_file" && ! -L "$env_file" && -r "$env_file" ]] || {
  printf '%s\n' "Server-owned environment file is missing, unreadable, or unsafe: $env_file" >&2
  exit 1
}
[[ -f "$compose_file" && ! -L "$compose_file" && -r "$compose_file" ]] || {
  printf '%s\n' "Server-owned Compose file is missing, unreadable, or unsafe: $compose_file" >&2
  exit 1
}
[[ -d "$cert_dir" && ! -L "$cert_dir" ]] || {
  printf '%s\n' "Server-owned certificate directory is missing or unsafe: $cert_dir" >&2
  exit 1
}
command -v curl >/dev/null 2>&1 || {
  printf '%s\n' 'curl is required on the deployment host' >&2
  exit 1
}

docker_run() {
  local runtime_env=("DOCKER_IMAGE=$DOCKER_IMAGE")
  if [[ "$USE_SUDO" == 1 ]]; then
    sudo -n env "${runtime_env[@]}" docker "$@"
  else
    env "${runtime_env[@]}" docker "$@"
  fi
}

compose() {
  docker_run compose \
    --project-name "$COMPOSE_PROJECT_NAME" \
    --project-directory "$REMOTE_DIR" \
    --env-file "$env_file" \
    --file "$compose_file" \
    "$@"
}

docker_run compose version >/dev/null
compose config --quiet
configured_images="$(compose config --images)"
[[ "$configured_images" == "$DOCKER_IMAGE" ]] || {
  printf '%s\n' 'Compose did not resolve exactly the requested immutable One User image' >&2
  exit 1
}

previous_container_id="$(compose ps -q "$COMPOSE_SERVICE_NAME" 2>/dev/null || true)"
previous_image_ref=
previous_image_id=
if [[ "$previous_container_id" =~ ^[0-9a-f]{12,64}$ ]]; then
  previous_image_ref="$(docker_run inspect --format '{{.Config.Image}}' "$previous_container_id" 2>/dev/null || true)"
  previous_image_id="$(docker_run inspect --format '{{.Image}}' "$previous_container_id" 2>/dev/null || true)"
fi

compose pull "$COMPOSE_SERVICE_NAME"
expected_image_id="$(docker_run image inspect --format '{{.Id}}' "$DOCKER_IMAGE")"
[[ "$expected_image_id" =~ ^sha256:[0-9a-f]{64}$ ]] || {
  printf '%s\n' 'Pulled One User image did not resolve to a content-addressed local image' >&2
  exit 1
}

show_failure_logs() {
  compose ps >&2 || true
  compose logs --no-color --tail "$LOG_TAIL" "$COMPOSE_SERVICE_NAME" >&2 || true
}

rollback() {
  local reason=$1
  local rollback_images restored_container_id restored_image_id

  printf 'One User deployment failed: %s\n' "$reason" >&2
  show_failure_logs

  if valid_image_ref "$previous_image_ref" \
    && [[ "$previous_image_ref" != "$new_image" ]] \
    && [[ "$previous_image_id" =~ ^sha256:[0-9a-f]{64}$ ]]; then
    DOCKER_IMAGE=$previous_image_ref
    rollback_images="$(compose config --images 2>/dev/null || true)"
    if [[ "$rollback_images" == "$previous_image_ref" ]] \
      && compose config --quiet \
      && compose up -d --no-deps --wait --wait-timeout "$wait_timeout" "$COMPOSE_SERVICE_NAME"; then
      restored_container_id="$(compose ps -q "$COMPOSE_SERVICE_NAME" 2>/dev/null || true)"
      restored_image_id="$(docker_run inspect --format '{{.Image}}' "$restored_container_id" 2>/dev/null || true)"
      if [[ "$restored_image_id" == "$previous_image_id" ]] \
        && curl --fail --silent --show-error --connect-timeout 2 --max-time 5 "$READY_URL" >/dev/null; then
        printf 'Previous One User image was restored: %s\n' "$previous_image_ref" >&2
        DOCKER_IMAGE=$new_image
        return
      fi
    fi
    compose logs --no-color --tail "$LOG_TAIL" "$COMPOSE_SERVICE_NAME" >&2 || true
    printf '%s\n' 'Rollback failed; manual server recovery is required.' >&2
    DOCKER_IMAGE=$new_image
    return
  fi

  printf '%s\n' 'No distinct digest-pinned running image is available for automatic rollback.' >&2
}

if ! compose up -d --no-deps --wait --wait-timeout "$wait_timeout" "$COMPOSE_SERVICE_NAME"; then
  rollback 'Compose did not make the requested service healthy'
  exit 1
fi

container_id="$(compose ps -q "$COMPOSE_SERVICE_NAME")"
if [[ ! "$container_id" =~ ^[0-9a-f]{12,64}$ ]]; then
  rollback 'Compose did not return exactly one service container'
  exit 1
fi

running="$(docker_run inspect --format '{{.State.Running}}' "$container_id")"
container_image_id="$(docker_run inspect --format '{{.Image}}' "$container_id")"
if [[ "$running" != true || "$container_image_id" != "$expected_image_id" ]]; then
  rollback 'Running container image ID does not match the pulled immutable image'
  exit 1
fi

ready=false
for _ in {1..15}; do
  if curl --fail --silent --show-error --connect-timeout 2 --max-time 5 "$READY_URL" >/dev/null; then
    ready=true
    break
  fi
  sleep 2
done
if [[ "$ready" != true ]]; then
  rollback "Readiness check failed: $READY_URL"
  exit 1
fi

printf 'Deployed One User image %s as container %s\n' "$DOCKER_IMAGE" "$container_id"
REMOTE_DEPLOY
