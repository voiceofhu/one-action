#!/usr/bin/env bash
# Replaces the Compose `web` service of a products.json product whose
# web_runtime is next with a new Web image, keeping the running Server image;
# the previous Web container is restored if a health check fails.
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/product.sh
source "$SCRIPT_DIR/../lib/product.sh"

: "${PRODUCT:?PRODUCT is required}"
: "${SSH_HOST:?SSH_HOST is required}"
: "${WEB_DOCKER_IMAGE:?WEB_DOCKER_IMAGE is required}"
load_product "$PRODUCT"
REMOTE_DIR=${REMOTE_DIR:-$PRODUCT_REMOTE_DIR}
PUBLIC_URL=${PUBLIC_URL:-$PRODUCT_PUBLIC_URL}
PUBLIC_URL=${PUBLIC_URL%/}

[[ "$PRODUCT_WEB_RUNTIME" == next ]] || {
  printf '%s Web is static; use deploy-web.sh\n' "$PRODUCT_TITLE" >&2
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
web_image_reference=${WEB_DOCKER_IMAGE#"$PRODUCT_WEB_IMAGE":}
[[ "$web_image_reference" != "$WEB_DOCKER_IMAGE" \
  && "$web_image_reference" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)@sha256:[0-9a-f]{64}$ ]] || {
  printf 'WEB_DOCKER_IMAGE must be a %s version pinned to an OCI index digest\n' "$PRODUCT_WEB_IMAGE" >&2
  exit 1
}
[[ "$PUBLIC_URL" =~ ^https://[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?(:[0-9]{1,5})?$ ]] || {
  printf '%s\n' 'PUBLIC_URL must be an HTTPS origin without a path, query, fragment, or trailing slash' >&2
  exit 1
}

remote_arguments=(
  "$REMOTE_DIR" "$WEB_DOCKER_IMAGE" "$PUBLIC_URL" "$PRODUCT_TITLE" "$PRODUCT_IMAGE"
  "$PRODUCT_CONTAINER" "$PRODUCT_NAME" "$PRODUCT_WEB_IMAGE" "$PRODUCT_WEB_CONTAINER"
  "$PRODUCT_WEB_SERVICE" "$PRODUCT_WEB_PORT" "$PRODUCT_WEB_HEALTH_PATH"
)
remote_command="REGISTRY_CONFIG_NAME=$SSH_HOST bash -s --$(printf ' %q' "${remote_arguments[@]}")"
# shellcheck disable=SC2029 # The command is built from validated, quoted values.
ssh "$SSH_HOST" "$remote_command" <<'REMOTE_DEPLOY'
set -Eeuo pipefail

remote_dir=$1
web_image=$2
public_url=$3
title=$4
image_repository=$5
container_name=$6
project_name=$7
web_image_repository=$8
web_container_name=$9
web_service_name=${10}
web_port=${11}
web_health_path=${12}

cd "$remote_dir"
test -f .env && test -f docker-compose.yml || {
  printf 'Deploy %s Server before publishing its Web separately.\n' "$title" >&2
  exit 1
}
mkdir -p web
exec 9>web/.deploy.lock
flock -w 120 9

# The Web is deployed next to the Server already running; Compose must still
# resolve that Server image, so pin it to what is running now.
image="$(docker inspect --format '{{.Config.Image}}' "$container_name" 2>/dev/null || true)"
[[ "$image" == "$image_repository":* && "$image" =~ @sha256:[0-9a-f]{64}$ ]] || {
  printf 'Deploy %s Server with a pinned image before publishing its Web separately.\n' "$title" >&2
  exit 1
}

compose() {
  env DOCKER_IMAGE="$image" CONTAINER_NAME="$container_name" \
    WEB_DOCKER_IMAGE="$web_image" WEB_CONTAINER_NAME="$web_container_name" docker compose \
    --project-name "$project_name" \
    --project-directory "$remote_dir" \
    --env-file .env \
    --file docker-compose.yml \
    "$@"
}

compose config --quiet
configured_images="$(compose config --images | LC_ALL=C sort)"
[[ "$configured_images" == "$(printf '%s\n' "$image" "$web_image" | LC_ALL=C sort)" ]] || {
  printf 'Compose did not resolve exactly the running %s Server and the requested Web image\n' "$title" >&2
  exit 1
}
previous_web_image="$(docker inspect --format '{{.Config.Image}}' "$web_container_name" 2>/dev/null || true)"

rollback() {
  local exit_code=$?
  trap - ERR
  printf '%s Web deployment failed; attempting to restore the previous Web container\n' "$title" >&2
  if [[ "$previous_web_image" == "$web_image_repository":* \
    && "$previous_web_image" =~ @sha256:[0-9a-f]{64}$ \
    && "$previous_web_image" != "$web_image" ]]; then
    web_image=$previous_web_image
    compose up -d --no-deps --wait --wait-timeout 120 "$web_service_name" || true
  fi
  exit "$exit_code"
}
trap rollback ERR

DOCKER_CONFIG="$HOME/.docker-deploy/${REGISTRY_CONFIG_NAME:?}" \
  compose pull "$web_service_name"
compose up -d --no-deps --wait --wait-timeout 120 "$web_service_name"

published_port="$(docker port "$web_container_name" "$web_port/tcp" 2>/dev/null | sed -n '1s/.*://p' || true)"
[[ -n "$published_port" ]] \
  && curl --fail --silent --show-error --connect-timeout 2 --max-time 5 \
    "http://127.0.0.1:$published_port$web_health_path" >/dev/null || {
  docker logs --tail 120 "$web_container_name" >&2 || true
  false
}
running_web_image="$(docker inspect --format '{{.Config.Image}}' "$web_container_name")"
[[ "$running_web_image" == "$web_image" ]] || {
  printf 'Running Web container does not use the requested immutable %s Web image\n' "$title" >&2
  false
}

public_ready=false
for attempt in $(seq 1 30); do
  if curl --fail --silent --show-error --connect-timeout 3 --max-time 10 \
    "$public_url$web_health_path" >/dev/null; then
    public_ready=true
    break
  fi
  if [[ "$attempt" == 30 ]]; then
    printf 'Public endpoint did not become ready: %s\n' "$public_url" >&2
    docker logs --tail 120 "$web_container_name" >&2 || true
    false
  fi
  sleep 2
done
[[ "$public_ready" == true ]]
trap - ERR
printf '%s Web updated to %s; Server container was not changed.\n' "$title" "$web_image"
REMOTE_DEPLOY
