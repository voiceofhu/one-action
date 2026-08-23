#!/usr/bin/env bash
set -Eeuo pipefail

: "${SSH_HOST:?SSH_HOST is required}"
: "${REMOTE_DIR:?REMOTE_DIR is required}"
: "${DOCKER_IMAGE:?DOCKER_IMAGE is required}"
: "${COMPOSE_FILE:?COMPOSE_FILE is required}"
PUBLIC_URL=${PUBLIC_URL:-https://oa.aicbe.com}

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
[[ "$DOCKER_IMAGE" =~ ^ghcr\.io/voiceofhu/one-user:(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)@sha256:[0-9a-f]{64}$ ]] || {
  printf '%s\n' 'DOCKER_IMAGE must be the fixed One User version pinned to an OCI index digest' >&2
  exit 1
}
[[ -f "$COMPOSE_FILE" && ! -L "$COMPOSE_FILE" ]] || {
  printf 'Compose file is missing or unsafe: %s\n' "$COMPOSE_FILE" >&2
  exit 1
}
PUBLIC_URL=${PUBLIC_URL%/}
[[ "$PUBLIC_URL" =~ ^https://[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?(:[0-9]{1,5})?$ ]] || {
  printf '%s\n' 'PUBLIC_URL must be an HTTPS origin without a path, query, fragment, or trailing slash' >&2
  exit 1
}

ssh "$SSH_HOST" "test -d '$REMOTE_DIR' && test -w '$REMOTE_DIR' && test -f '$REMOTE_DIR/.env' && test -d '$REMOTE_DIR/cert' && command -v curl >/dev/null && docker info >/dev/null" || {
  printf '%s\n' "$REMOTE_DIR must exist, contain .env and cert/, and be writable; curl and Docker must be available to the deploy user" >&2
  exit 1
}

scp "$COMPOSE_FILE" "$SSH_HOST:$REMOTE_DIR/docker-compose.yml.next"

ssh "$SSH_HOST" bash -s -- "$REMOTE_DIR" "$DOCKER_IMAGE" "$PUBLIC_URL" <<'REMOTE_DEPLOY'
set -Eeuo pipefail

remote_dir=$1
image=$2
public_url=$3
container_name=one-user
service_name=user

cd "$remote_dir"
test -f docker-compose.yml.next

compose() {
  local compose_file=$1
  shift
  env DOCKER_IMAGE="$image" CONTAINER_NAME="$container_name" docker compose \
    --project-name one-user \
    --project-directory "$remote_dir" \
    --env-file .env \
    --file "$compose_file" \
    "$@"
}

compose docker-compose.yml.next config --quiet
configured_images="$(compose docker-compose.yml.next config --images)"
[[ "$configured_images" == "$image" ]] || {
  printf '%s\n' 'Compose did not resolve exactly the requested immutable One User image' >&2
  exit 1
}
previous_image="$(docker inspect --format '{{.Config.Image}}' "$container_name" 2>/dev/null || true)"

rollback() {
  local exit_code=$?
  trap - ERR
  printf '%s\n' 'One User deployment failed; attempting to restore the previous container' >&2
  if [[ "$previous_image" =~ ^ghcr\.io/voiceofhu/one-user:.*@sha256:[0-9a-f]{64}$ ]] \
    && [[ "$previous_image" != "$image" ]] \
    && [[ -f docker-compose.yml ]]; then
    local failed_image=$image
    image=$previous_image
    compose docker-compose.yml up -d --no-deps --wait --wait-timeout 120 "$service_name" || true
    image=$failed_image
  fi
  rm -f docker-compose.yml.next
  exit "$exit_code"
}
trap rollback ERR

compose docker-compose.yml.next pull "$service_name"
compose docker-compose.yml.next up -d --no-deps --wait --wait-timeout 120 "$service_name"

published_port="$(docker port "$container_name" 27510/tcp 2>/dev/null | sed -n '1s/.*://p' || true)"
[[ -n "$published_port" ]] \
  && curl --fail --silent --show-error --connect-timeout 2 --max-time 5 \
    "http://127.0.0.1:$published_port/readyz" >/dev/null \
  && curl --fail --silent --show-error --connect-timeout 2 --max-time 5 \
    "http://127.0.0.1:$published_port/" >/dev/null || {
  docker logs --tail 120 "$container_name" >&2 || true
  false
}

running_image="$(docker inspect --format '{{.Config.Image}}' "$container_name")"
[[ "$running_image" == "$image" ]] || {
  printf '%s\n' 'Running container does not use the requested immutable One User image' >&2
  false
}

public_ready=false
for attempt in $(seq 1 30); do
  if curl --fail --silent --show-error --connect-timeout 3 --max-time 10 \
    "$public_url/readyz" >/dev/null \
    && curl --fail --silent --show-error --connect-timeout 3 --max-time 10 \
      "$public_url/" >/dev/null; then
    public_ready=true
    printf 'One User public endpoint is ready: %s\n' "$public_url"
    break
  fi
  if [[ "$attempt" == 30 ]]; then
    printf 'Public endpoint did not become ready: %s\n' "$public_url" >&2
    docker logs --tail 120 "$container_name" >&2 || true
    false
  fi
  sleep 2
done
[[ "$public_ready" == true ]]

mv -f docker-compose.yml.next docker-compose.yml
trap - ERR
REMOTE_DEPLOY
