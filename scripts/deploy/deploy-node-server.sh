#!/usr/bin/env bash
set -Eeuo pipefail

: "${SSH_HOST:?SSH_HOST is required}"
: "${REMOTE_DIR:?REMOTE_DIR is required}"
: "${DOCKER_IMAGE:?DOCKER_IMAGE is required}"
: "${COMPOSE_FILE:?COMPOSE_FILE is required}"

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
[[ "$DOCKER_IMAGE" =~ ^ghcr\.io/voiceofhu/node-server:(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)@sha256:[0-9a-f]{64}$ ]] || {
  printf '%s\n' 'DOCKER_IMAGE must be the fixed One Node Server version pinned to an OCI index digest' >&2
  exit 1
}
[[ -f "$COMPOSE_FILE" && ! -L "$COMPOSE_FILE" ]] || {
  printf 'Compose file is missing or unsafe: %s\n' "$COMPOSE_FILE" >&2
  exit 1
}

ssh "$SSH_HOST" "test -d '$REMOTE_DIR' && test -w '$REMOTE_DIR' && test -f '$REMOTE_DIR/.env' && docker info >/dev/null" || {
  printf '%s\n' "$REMOTE_DIR must exist, contain .env, and be writable; the deploy user must be able to run Docker" >&2
  exit 1
}

scp "$COMPOSE_FILE" "$SSH_HOST:$REMOTE_DIR/docker-compose.yml.next"

ssh "$SSH_HOST" bash -s -- "$REMOTE_DIR" "$DOCKER_IMAGE" <<'REMOTE_DEPLOY'
set -Eeuo pipefail

remote_dir=$1
image=$2
container_name=one-node-server
service_name=server

cd "$remote_dir"
test -f docker-compose.yml.next

compose() {
  local compose_file=$1
  shift
  env DOCKER_IMAGE="$image" CONTAINER_NAME="$container_name" docker compose \
    --project-name one-node \
    --project-directory "$remote_dir" \
    --env-file .env \
    --file "$compose_file" \
    "$@"
}

compose docker-compose.yml.next config --quiet
configured_images="$(compose docker-compose.yml.next config --images)"
[[ "$configured_images" == "$image" ]] || {
  printf '%s\n' 'Compose did not resolve exactly the requested immutable One Node Server image' >&2
  exit 1
}
previous_image="$(docker inspect --format '{{.Config.Image}}' "$container_name" 2>/dev/null || true)"

rollback() {
  local exit_code=$?
  trap - ERR
  printf '%s\n' 'One Node Server deployment failed; attempting to restore the previous container' >&2
  if [[ "$previous_image" =~ ^ghcr\.io/voiceofhu/node-server:.*@sha256:[0-9a-f]{64}$ ]] \
    && [[ "$previous_image" != "$image" ]] \
    && [[ -f docker-compose.yml ]]; then
    local failed_image=$image
    image=$previous_image
    compose docker-compose.yml up -d --no-deps "$service_name" || true
    image=$failed_image
  fi
  rm -f docker-compose.yml.next
  exit "$exit_code"
}
trap rollback ERR

compose docker-compose.yml.next pull "$service_name"
compose docker-compose.yml.next up -d --no-deps "$service_name"

for attempt in $(seq 1 30); do
  container_status="$(docker inspect --format '{{.State.Status}}' "$container_name" 2>/dev/null || true)"
  case "$container_status" in
    restarting|exited|dead)
      printf 'Container %s entered %s during startup\n' "$container_name" "$container_status" >&2
      docker logs --tail 120 "$container_name" >&2 || true
      false
      ;;
  esac
  published_port="$(docker port "$container_name" 27517/tcp 2>/dev/null | sed -n '1s/.*://p' || true)"
  if [[ -n "$published_port" ]] \
    && curl --fail --silent --show-error --connect-timeout 2 --max-time 5 \
      "http://127.0.0.1:$published_port/api/healthz" >/dev/null \
    && curl --fail --silent --show-error --connect-timeout 2 --max-time 5 \
      "http://127.0.0.1:$published_port/" >/dev/null; then
    printf '%s\n' 'One Node Server is healthy and serving Web at /'
    break
  fi
  if [[ "$attempt" == 30 ]]; then
    docker logs --tail 120 "$container_name" >&2 || true
    false
  fi
  sleep 2
done

running_image="$(docker inspect --format '{{.Config.Image}}' "$container_name")"
[[ "$running_image" == "$image" ]] || {
  printf '%s\n' 'Running container does not use the requested immutable image' >&2
  false
}
mv -f docker-compose.yml.next docker-compose.yml
trap - ERR
REMOTE_DEPLOY
